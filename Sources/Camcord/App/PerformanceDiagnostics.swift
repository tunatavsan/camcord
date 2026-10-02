import AppKit
import CoreFoundation
import QuartzCore
import os
import SwiftUI
import Synchronization

/// This state machine closes only a matching, observed AppKit display pass.
/// It deliberately makes no assertion about Core Animation commit or presentation.
struct ActivationDisplayTracker {
    enum Outcome: String { case superseded, cancelled, displayPassReturned = "AppKit-display-pass-returned" }
    enum Event: Equatable {
        case began(UInt64)
        case ended(UInt64, Outcome)
    }
    private var sequence: UInt64 = 0
    private(set) var generation: UInt64?

    mutating func begin(eligible: Bool) -> [Event] {
        var events = cancel(outcome: eligible ? .superseded : .cancelled)
        guard eligible else { return events }
        sequence &+= 1
        generation = sequence
        events.append(.began(sequence))
        return events
    }

    mutating func cancel(outcome: Outcome = .cancelled) -> [Event] {
        guard let generation else { return [] }
        self.generation = nil
        return [.ended(generation, outcome)]
    }

    mutating func displayReturned(generation: UInt64?, eligible: Bool) -> [Event] {
        guard eligible, let generation, self.generation == generation else { return [] }
        self.generation = nil
        return [.ended(generation, .displayPassReturned)]
    }
}

/// Numeric, bounded snapshot. Invalid scales are counted rather than logged as NaN/Inf.
struct LayerScaleSummary {
    static let maximumLayers = 512
    private(set) var count = 0
    private(set) var invalidScales = 0
    private(set) var minimumScale: Double = 0
    private(set) var maximumScale: Double = 0
    private(set) var rasterizedLayers = 0
    private(set) var minimumRasterizationScale: Double = 0
    private(set) var maximumRasterizationScale: Double = 0
    private(set) var truncated = false

    @MainActor static func capture(root: CALayer?) -> Self {
        var result = Self()
        guard let root else { return result }
        var pending = [root]
        var seen = Set<ObjectIdentifier>()
        while let layer = pending.popLast() {
            guard seen.insert(ObjectIdentifier(layer)).inserted else { continue }
            guard result.count < maximumLayers else { result.truncated = true; break }
            result.count += 1
            let scale = Double(layer.contentsScale)
            if scale.isFinite && scale > 0 {
                result.minimumScale = result.minimumScale == 0 ? scale : min(result.minimumScale, scale)
                result.maximumScale = max(result.maximumScale, scale)
            } else { result.invalidScales += 1 }
            if layer.shouldRasterize {
                result.rasterizedLayers += 1
                let rasterScale = Double(layer.rasterizationScale)
                if rasterScale.isFinite && rasterScale > 0 {
                    result.minimumRasterizationScale = result.minimumRasterizationScale == 0
                        ? rasterScale : min(result.minimumRasterizationScale, rasterScale)
                    result.maximumRasterizationScale = max(result.maximumRasterizationScale, rasterScale)
                } else { result.invalidScales += 1 }
            }
            if let children = layer.sublayers {
                let capacity = maximumLayers - result.count - pending.count
                if children.count > max(0, capacity) { result.truncated = true }
                pending.append(contentsOf: children.prefix(max(0, capacity)))
            }
        }
        return result
    }
}

/// Owned by the app delegate, with only the controller's explicitly registered window eligible.
/// Natural display callbacks can be absent for a retained SwiftUI layer tree; no timeout,
/// layout callback, forced redraw or window-update notification substitutes for a display.
@MainActor
final class ActivationPerformanceDiagnostics {
    static let shared = ActivationPerformanceDiagnostics()
    private let log = OSLog(subsystem: "dev.tavsan.camcord", category: .pointsOfInterest)
    private weak var window: NSWindow?
    private var tracker = ActivationDisplayTracker()
    private struct Interval { let id: OSSignpostID; let started: UInt64 }
    private var intervals: [UInt64: Interval] = [:]

    func register(window: NSWindow?) {
        guard self.window !== window else { return }
        emit(tracker.cancel())
        self.window = window
        #if DEBUG
        NavigationDisplayLinkDiagnostics.shared.register(window: window)
        #endif
    }

    func didBecomeActive() {
        observeCost(phase: "activation") {
            emit(tracker.begin(eligible: window?.isVisible == true && window?.isMiniaturized == false))
            #if DEBUG
            if ProcessInfo.processInfo.environment["CAMCORD_DEBUG_DISPLAYLINK"] == "1" {
                NavigationDisplayLinkDiagnostics.shared.request(label: "activation.debug")
            }
            #endif
        }
    }

    func didResignActive() {
        observeCost(phase: "resign") { emit(tracker.cancel()) }
        #if DEBUG
        NavigationDisplayLinkDiagnostics.shared.cancel(outcome: "resigned")
        #endif
    }

    func willClose(window: NSWindow) {
        guard self.window === window else { return }
        emit(tracker.cancel())
        #if DEBUG
        NavigationDisplayLinkDiagnostics.shared.cancel(outcome: "closed")
        #endif
    }

    func displayGeneration(window: NSWindow, needsDisplay: Bool) -> UInt64? {
        guard self.window === window, window.isVisible, !window.isMiniaturized, needsDisplay else { return nil }
        return tracker.generation
    }

    func displayReturned(window: NSWindow, generation: UInt64?) {
        guard let generation else { return }
        observeCost(phase: "display") {
            let events = tracker.displayReturned(generation: generation,
                eligible: self.window === window && window.isVisible && !window.isMiniaturized)
            emit(events)
            if !events.isEmpty { recordRetina(window: window) }
        }
    }

    private func emit(_ events: [ActivationDisplayTracker.Event]) {
        for event in events {
            switch event {
            case .began(let generation):
                let id = OSSignpostID(log: log)
                intervals[generation] = Interval(id: id, started: DispatchTime.now().uptimeNanoseconds)
                os_signpost(.begin, log: log, name: "ActivationToAppKitDisplay", signpostID: id,
                            "generation=%llu", generation)
            case .ended(let generation, let outcome):
                guard let interval = intervals.removeValue(forKey: generation) else { continue }
                let elapsed = DispatchTime.now().uptimeNanoseconds - interval.started
                os_signpost(.end, log: log, name: "ActivationToAppKitDisplay", signpostID: interval.id,
                            "generation=%llu outcome=%{public}@", generation, outcome.rawValue)
                DiagnosticsLog.append("performance activation generation=\(generation) elapsed_ms=\(Double(elapsed) / 1_000_000) outcome=\(outcome.rawValue)")
            }
        }
    }

    private func observeCost(phase: String, _ operation: () -> Void) {
        let id = OSSignpostID(log: log)
        let started = DispatchTime.now().uptimeNanoseconds
        os_signpost(.begin, log: log, name: "ActivationObserverCost", signpostID: id, "%{public}@", phase)
        operation()
        os_signpost(.end, log: log, name: "ActivationObserverCost", signpostID: id, "%{public}@", phase)
        DiagnosticsLog.append("performance activation-observer phase=\(phase) elapsed_ms=\(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)")
    }

    private func recordRetina(window: NSWindow) {
        let backing = window.contentView.map { $0.convertToBacking($0.bounds).size } ?? .zero
        let layers = LayerScaleSummary.capture(root: window.contentView?.layer)
        let finite: (CGFloat) -> Double = { $0.isFinite ? Double($0) : 0 }
        os_signpost(.event, log: log, name: "ActivationRetinaSnapshot",
                    "backing_scale=%{public}f width_px=%{public}f height_px=%{public}f layers=%d invalid=%d min_scale=%{public}f max_scale=%{public}f rasterized=%d min_raster_scale=%{public}f max_raster_scale=%{public}f truncated=%d",
                    finite(window.backingScaleFactor), finite(backing.width), finite(backing.height),
                    layers.count, layers.invalidScales, layers.minimumScale, layers.maximumScale,
                    layers.rasterizedLayers, layers.minimumRasterizationScale, layers.maximumRasterizationScale,
                    layers.truncated ? 1 : 0)
        DiagnosticsLog.append("performance activation-retina backing_scale=\(finite(window.backingScaleFactor)) width_px=\(finite(backing.width)) height_px=\(finite(backing.height)) layers=\(layers.count) invalid=\(layers.invalidScales) min_scale=\(layers.minimumScale) max_scale=\(layers.maximumScale) rasterized=\(layers.rasterizedLayers) min_raster_scale=\(layers.minimumRasterizationScale) max_raster_scale=\(layers.maximumRasterizationScale) truncated=\(layers.truncated ? 1 : 0)")
    }
}

/// Wraps only naturally invoked AppKit drawing passes. The end is CPU-side display-return,
/// not a rendered whole frame or a compositor/GPU presentation timestamp.
@MainActor
final class DiagnosticMainWindow: NSWindow {
    private var displayDepth = 0

    override func display() { observeDisplay { super.display() } }
    override func displayIfNeeded() { observeDisplay { super.displayIfNeeded() } }
    override func close() {
        ActivationPerformanceDiagnostics.shared.willClose(window: self)
        super.close()
    }

    private func observeDisplay(_ operation: () -> Void) {
        let generation = displayDepth == 0
            ? ActivationPerformanceDiagnostics.shared.displayGeneration(window: self, needsDisplay: viewsNeedDisplay) : nil
        displayDepth += 1
        operation()
        displayDepth -= 1
        if displayDepth == 0 {
            ActivationPerformanceDiagnostics.shared.displayReturned(window: self, generation: generation)
        }
    }
}

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
        #if DEBUG
        let callbackStartedAt = CACurrentMediaTime()
        #endif
        // A superseded request gets an explicit outcome, never a false layout completion.
        for old in pending.keys.filter({ target.isModule || !$0.isModule }) {
            end(old, outcome: "superseded")
        }
        sequence &+= 1
        let interval = Pending(generation: sequence, signpost: OSSignpostID(log: log))
        pending[target] = interval
        os_signpost(.begin, log: log, name: target.name, signpostID: interval.signpost,
                    "%{public}@ generation=%llu", target.label, sequence)
        #if DEBUG
        NavigationDisplayLinkDiagnostics.shared.requestNavigation(target, startedAt: callbackStartedAt)
        #endif
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
        #if DEBUG
        if outcome == "superseded" {
            NavigationDisplayLinkDiagnostics.shared.cancel(label: target.label, outcome: "superseded")
        }
        #endif
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
/// Arrival cadence of display-link callbacks, not frames rendered or presented by the app.
/// The clock is supplied by the caller so interval/deadline math needs no real-time tests.
struct DisplayCallbackMeasurement {
    static let maximumIntervals = 256
    let startedAt: Double
    let deadline: Double
    private(set) var firstCallbackAt: Double?
    private var previousCallbackAt: Double?
    private(set) var callbackCount = 0
    private(set) var invalidCallbacks = 0
    private(set) var intervals: [Double] = []
    private(set) var maximumInterval = 0.0
    private(set) var truncated = false

    init?(startedAt: Double, duration: Double = 0.65) {
        guard startedAt.isFinite, startedAt >= 0, duration.isFinite,
              (0.3...1.0).contains(duration), (startedAt + duration).isFinite else { return nil }
        self.startedAt = startedAt
        deadline = startedAt + duration
    }

    func expired(at now: Double) -> Bool { now.isFinite && now >= deadline }

    mutating func callback(at now: Double) {
        guard now.isFinite, now >= startedAt, now < deadline,
              previousCallbackAt.map({ now > $0 }) ?? true else { invalidCallbacks += 1; return }
        if firstCallbackAt == nil { firstCallbackAt = now }
        if let previousCallbackAt {
            let interval = now - previousCallbackAt
            maximumInterval = max(maximumInterval, interval)
            if intervals.count < Self.maximumIntervals { intervals.append(interval) }
            else { truncated = true }
        }
        previousCallbackAt = now
        callbackCount += 1
    }

    var firstCallbackMilliseconds: Double? { firstCallbackAt.map { ($0 - startedAt) * 1_000 } }
    var medianIntervalMilliseconds: Double? {
        guard !intervals.isEmpty else { return nil }
        let sorted = intervals.sorted(), middle = sorted.count / 2
        return (sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]) * 1_000
    }
}

/// One short sampling window per navigation request. An existing mounted layout does not
/// stop the sampling window; the deadline merely bounds observation, never marks a draw.
@MainActor
final class NavigationDisplayLinkDiagnostics {
    static let shared = NavigationDisplayLinkDiagnostics()
    private struct Session {
        let generation: UInt64
        var measurement: DisplayCallbackMeasurement
        let deadlineTask: Task<Void, Never>
        var callbackCostNanoseconds: UInt64 = 0
    }
    private weak var window: NSWindow?
    private var displayLink: CADisplayLink?
    private var proxy: NavigationDisplayLinkProxy?
    private var sessions: [String: Session] = [:]
    private var sequence: UInt64 = 0
    private var preferredMinimum: Float = 0
    private var preferredMaximum: Float = 0

    func register(window: NSWindow?) {
        guard self.window !== window else { return }
        cancel(outcome: "window-replaced")
        self.window = window
    }

    func requestNavigation(_ target: NavigationPerformanceDiagnostics.Target, startedAt: Double) {
        // A completed layout can still have a live observation window. A new transition
        // supersedes it, so its aggregate cannot include the next transition's callbacks.
        for old in sessions.keys.filter({ target.isModule
            ? $0.hasPrefix("module.") || $0.hasPrefix("settings.")
            : $0.hasPrefix("settings.") }) {
            cancel(label: old, outcome: "superseded")
        }
        request(label: target.label, startedAt: startedAt)
    }

    func request(label: String, startedAt: Double? = nil) {
        cancel(label: label, outcome: "superseded")
        guard eligible, let view = window?.contentView,
              let measurement = DisplayCallbackMeasurement(startedAt: startedAt ?? CACurrentMediaTime()) else { return }
        // Labels originate only from fixed module/page enums or the explicit debug flag.
        guard sessions.count < 16 else { return }
        sequence &+= 1
        let generation = sequence
        let deadlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard let self, self.sessions[label]?.generation == generation else { return }
            self.cancel(label: label, outcome: "deadline")
        }
        sessions[label] = Session(generation: generation, measurement: measurement, deadlineTask: deadlineTask)
        if displayLink == nil {
            let proxy = NavigationDisplayLinkProxy(owner: self)
            self.proxy = proxy
            let link = view.displayLink(target: proxy, selector: #selector(NavigationDisplayLinkProxy.tick(_:)))
            let fps = Float(min(120, max(1, window?.screen?.maximumFramesPerSecond ?? 60)))
            preferredMinimum = min(80, fps)
            preferredMaximum = fps
            link.preferredFrameRateRange = CAFrameRateRange(minimum: preferredMinimum, maximum: fps, preferred: fps)
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    func cancel(outcome: String) {
        for label in Array(sessions.keys) { cancel(label: label, outcome: outcome) }
        stopIfIdle()
    }

    func cancel(label: String, outcome: String) {
        guard let session = sessions.removeValue(forKey: label) else { return }
        session.deadlineTask.cancel()
        let value = session.measurement
        DiagnosticsLog.append("performance displaylink-callbacks target=\(label) generation=\(session.generation) outcome=\(outcome) callbacks=\(value.callbackCount) intervals=\(value.intervals.count) first_callback_ms=\(value.firstCallbackMilliseconds ?? -1) p50_ms=\(value.medianIntervalMilliseconds ?? -1) max_ms=\(value.maximumInterval * 1_000) invalid=\(value.invalidCallbacks) truncated=\(value.truncated ? 1 : 0) preferred_min=\(preferredMinimum) preferred_max=\(preferredMaximum) callback_sample_math_ms=\(Double(session.callbackCostNanoseconds) / 1_000_000)")
        stopIfIdle()
    }

    private var eligible: Bool {
        guard let window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible) else { return false }
        return NSApp?.isActive == true
    }

    func tick() {
        guard eligible else { cancel(outcome: "inactive"); return }
        // CACurrentMediaTime measures callback ARRIVAL; the display-link timestamp can
        // describe a scheduled frame even when this callback reaches the main actor late.
        let now = CACurrentMediaTime()
        for label in Array(sessions.keys) {
            if sessions[label]?.measurement.expired(at: now) == true {
                cancel(label: label, outcome: "deadline"); continue
            }
            let started = DispatchTime.now().uptimeNanoseconds
            sessions[label]?.measurement.callback(at: now)
            sessions[label]?.callbackCostNanoseconds += DispatchTime.now().uptimeNanoseconds - started
        }
        stopIfIdle()
    }

    private func stopIfIdle() {
        guard sessions.isEmpty else { return }
        displayLink?.invalidate()
        displayLink = nil
        proxy = nil
    }
}

@MainActor
private final class NavigationDisplayLinkProxy: NSObject {
    weak var owner: NavigationDisplayLinkDiagnostics?
    init(owner: NavigationDisplayLinkDiagnostics) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.tick() }
}

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
