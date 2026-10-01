import AppKit
import CoreFoundation
import os
import SwiftUI
import Synchronization

/// Request-to-mounted-layout intervals; the visual transition has its own duration.
/// Fixed identifiers contain no document, device, window or owner data.
@MainActor
final class NavigationPerformanceDiagnostics {
    enum Target: Hashable {
        case module(ModuleID)
        case settings(SettingsGroup)

        var label: String {
            switch self {
            case .module(let id): "module.\(id.rawValue)"
            case .settings(let group): "settings.\(group.rawValue)"
            }
        }
        var name: StaticString {
            switch self {
            case .module: "ModuleOpen"
            case .settings: "SettingsPageOpen"
            }
        }
        var isModule: Bool { if case .module = self { true } else { false } }
    }
    private struct Pending {
        let generation: UInt64
        let signpost: OSSignpostID
    }
    private let log = OSLog(subsystem: "dev.tavsan.camcord", category: .pointsOfInterest)
    private var sequence: UInt64 = 0
    private var pending: [Target: Pending] = [:]

    func request(_ target: Target) {
        // A superseded request gets an explicit outcome, never a false layout completion.
        for old in pending.keys.filter({ target.isModule || !$0.isModule }) {
            end(old, outcome: "superseded")
        }
        sequence &+= 1
        let interval = Pending(generation: sequence, signpost: OSSignpostID(log: log))
        pending[target] = interval
        os_signpost(.begin, log: log, name: target.name, signpostID: interval.signpost,
                    "%{public}@ generation=%llu", target.label, sequence)
    }

    func generation(for target: Target) -> UInt64? { pending[target]?.generation }

    @discardableResult
    func complete(_ target: Target, generation: UInt64?) -> Bool {
        guard let generation, pending[target]?.generation == generation else { return false }
        end(target, outcome: "mounted-layout")
        return true
    }

    private func end(_ target: Target, outcome: String) {
        guard let interval = pending.removeValue(forKey: target) else { return }
        os_signpost(.end, log: log, name: target.name, signpostID: interval.signpost,
                    "%{public}@ outcome=%{public}@ generation=%llu", target.label, outcome, interval.generation)
    }
}

/// A selected view completes its request only after its AppKit backing view is mounted
/// and laid out. No timer/animation duration is used as a substitute for this callback.
struct PerformanceLayoutCompletionBridge: NSViewRepresentable {
    let target: NavigationPerformanceDiagnostics.Target
    let active: Bool
    let diagnostics: NavigationPerformanceDiagnostics?

    func makeNSView(context: Context) -> LayoutView { LayoutView() }
    func updateNSView(_ view: LayoutView, context: Context) {
        view.diagnostics = diagnostics
        view.target = active ? target : nil
        view.generation = active ? diagnostics?.generation(for: target) : nil
        view.settingsModuleGeneration = active && !target.isModule
            ? diagnostics?.generation(for: .module(.settings)) : nil
        view.needsLayout = true
    }

    final class LayoutView: NSView {
        weak var diagnostics: NavigationPerformanceDiagnostics?
        var target: NavigationPerformanceDiagnostics.Target?
        var generation: UInt64?
        var settingsModuleGeneration: UInt64?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            needsLayout = true
        }
        override func layout() {
            super.layout()
            guard window != nil, !bounds.isEmpty, let target else { return }
            diagnostics?.complete(target, generation: generation)
            if !target.isModule {
                diagnostics?.complete(.module(.settings), generation: settingsModuleGeneration)
            }
            generation = nil; settingsModuleGeneration = nil
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

#if DEBUG
/// Tracks continuous runloop work, excluding the interval in which the loop is asleep.
struct RunLoopStallTracker {
    struct Stall: Sendable {
        let generation: UInt64
        let elapsedNanoseconds: UInt64
        let wasReported: Bool
    }
    private var busySince: UInt64?
    private var generation: UInt64 = 0
    private var reported = false
    private let threshold: UInt64 = 50_000_000

    mutating func becameBusy(now: UInt64) {
        guard busySince == nil else { return }
        busySince = now; generation &+= 1; reported = false
    }
    mutating func poll(now: UInt64) -> Stall? {
        guard let busySince, now >= busySince, now - busySince > threshold, !reported else { return nil }
        reported = true
        return Stall(generation: generation, elapsedNanoseconds: now - busySince, wasReported: false)
    }
    mutating func becameIdle(now: UInt64) -> Stall? {
        defer { busySince = nil; reported = false }
        guard let busySince, now >= busySince, now - busySince > threshold else { return nil }
        return Stall(generation: generation, elapsedNanoseconds: now - busySince, wasReported: reported)
    }
    func stillBusy(generation: UInt64) -> Bool { busySince != nil && self.generation == generation }
}

/// Apple's sampler unwinds the target from another process. Never substitute the
/// watchdog's Thread.callStackSymbols, or a callback executed after the main thread resumes.
enum MainThreadStackSampler {
    struct Result: Sendable {
        let frames: [String]
        let startedUptimeNanoseconds: UInt64
        let elapsedNanoseconds: UInt64
        let succeeded: Bool
    }

    static func sampleOwnProcess() -> Result {
        let started = DispatchTime.now().uptimeNanoseconds
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        // Zero duration is one snapshot on macOS sample(1); no temporary report file.
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "0", "1", "-file", "/dev/stdout"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            return Result(frames: [], startedUptimeNanoseconds: started, elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - started, succeeded: false)
        }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: timeout)
        defer { timeout.cancel(); try? pipe.fileHandleForReading.close() }
        var output = Data()
        // Read continuously to avoid a full pipe blocking sample; retain at most 256 KiB.
        while let data = try? pipe.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
            if output.count < 256 * 1024 { output.append(data.prefix(256 * 1024 - output.count)) }
        }
        process.waitUntilExit()
        let frames = mainThreadFrames(from: String(decoding: output, as: UTF8.self))
        return Result(frames: frames, startedUptimeNanoseconds: started, elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
                      succeeded: process.terminationStatus == 0 && !frames.isEmpty)
    }

    static func mainThreadFrames(from report: String) -> [String] {
        var main = false, frames: [String] = []
        for line in report.split(separator: "\n") {
            if line.contains("Thread_") {
                if main { break }
                main = line.contains("com.apple.main-thread")
                continue
            }
            guard main else { continue }
            if line.contains("Binary Images:") { break }
            guard line.contains("(in "), let addressEnd = line.firstIndex(of: "]") else { continue }
            // Discard source locations and every report header; static symbols only.
            let frame = String(line[...addressEnd]).trimmingCharacters(in: .whitespaces)
            guard !frame.contains("/") else { continue }
            frames.append(String(frame.prefix(384)))
            if frames.count == 48 { break }
        }
        return frames
    }
}

/// The observer's state is protected by Mutex; the observer/timer lifetime belongs to
/// MainActor. Sampling and file writes never run on the UI thread.
final class MainRunLoopHangMonitor: Sendable {
    @MainActor static let shared = MainRunLoopHangMonitor()
    private struct State {
        var tracker = RunLoopStallTracker()
        var enabled = false
        var sampling = false
        var nextSampleAt: UInt64 = 0
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "dev.tavsan.camcord.performance-watchdog", qos: .utility)
    @MainActor private var observer: CFRunLoopObserver?
    @MainActor private var timer: DispatchSourceTimer?

    @MainActor init() { observer = nil; timer = nil }

    @MainActor func start() {
        guard observer == nil else { return }
        state.withLock {
            $0.enabled = true
            $0.tracker.becameBusy(now: DispatchTime.now().uptimeNanoseconds)
        }
        let activities: CFRunLoopActivity = [.entry, .afterWaiting, .beforeWaiting, .exit]
        observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, 0) { @Sendable [weak self] _, activity in
            self?.record(activity)
        }
        if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { @Sendable [weak self] in self?.check() }
        self.timer = timer
        timer.resume()
    }

    @MainActor func stop() {
        state.withLock { $0.enabled = false }
        timer?.cancel(); timer = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }

    private func record(_ activity: CFRunLoopActivity) {
        let now = DispatchTime.now().uptimeNanoseconds
        let recovered = state.withLock { state -> RunLoopStallTracker.Stall? in
            guard state.enabled else { return nil }
            if activity == .beforeWaiting || activity == .exit { return state.tracker.becameIdle(now: now) }
            state.tracker.becameBusy(now: now)
            return nil
        }
        if let recovered {
            if !recovered.wasReported {
                DiagnosticsLog.appendPerformanceStall(generation: recovered.generation,
                    elapsedNanoseconds: recovered.elapsedNanoseconds, outcome: "recovered-before-poll; stack-unavailable")
            } else {
                DiagnosticsLog.append("performance runloop-recovered generation=\(recovered.generation) elapsed_ms=\(Double(recovered.elapsedNanoseconds) / 1_000_000)")
            }
        }
    }

    private func check() {
        let now = DispatchTime.now().uptimeNanoseconds
        let event = state.withLock { state -> (RunLoopStallTracker.Stall, Bool)? in
            guard state.enabled, let stall = state.tracker.poll(now: now) else { return nil }
            let sample = !state.sampling && now >= state.nextSampleAt
            if sample { state.sampling = true; state.nextSampleAt = now + 30_000_000_000 }
            return (stall, sample)
        }
        guard let (stall, sample) = event else { return }
        DiagnosticsLog.appendPerformanceStall(generation: stall.generation,
            elapsedNanoseconds: stall.elapsedNanoseconds, outcome: sample ? "sampling-requested" : "stack-unavailable; sample-rate-limit")
        guard sample else { return }
        // Separate queue keeps the watchdog ticking during sample's symbolication.
        DispatchQueue.global(qos: .utility).async { [self] in
            let result = MainThreadStackSampler.sampleOwnProcess()
            let stillBusy = state.withLock { state in
                state.sampling = false
                return state.enabled && state.tracker.stillBusy(generation: stall.generation)
            }
            let outcome = !stillBusy ? "stack-unavailable; recovered-during-sampling"
                : result.succeeded ? "genuine-main-thread-sample" : "stack-unavailable; sampler-failed"
            DiagnosticsLog.append("performance sample generation=\(stall.generation) started_uptime_ns=\(result.startedUptimeNanoseconds) ended_uptime_ns=\(result.startedUptimeNanoseconds + result.elapsedNanoseconds) overhead_ms=\(Double(result.elapsedNanoseconds) / 1_000_000) outcome=\(outcome)")
            if stillBusy && result.succeeded {
                DiagnosticsLog.append("performance hung-main-thread-stack generation=\(stall.generation)\n" + result.frames.joined(separator: "\n"))
            }
        }
    }
}
#endif
