import AppKit
import Synchronization
import Testing
@testable import Camcord

@Suite("Performance diagnostics", .serialized)
struct PerformanceDiagnosticsTests {
    @Test("waiting time is excluded; a busy span is reported once above 50ms")
    func busyRunLoopSpan() {
        var tracker = RunLoopStallTracker()
        #expect(tracker.poll(now: 9_000_000_000) == nil)
        tracker.becameBusy(now: 10_000_000_000)
        #expect(tracker.poll(now: 10_050_000_000) == nil)
        let stall = tracker.poll(now: 10_050_000_001)
        #expect(stall?.generation == 1)
        #expect(tracker.poll(now: 10_080_000_000) == nil)
        #expect(tracker.becameIdle(now: 10_100_000_000)?.elapsedNanoseconds == 100_000_000)
        #expect(!tracker.stillBusy(generation: 1))
        tracker.becameBusy(now: 12_000_000_000)
        #expect(tracker.poll(now: 12_060_000_000)?.generation == 2)
    }

    @Test("a stall ending between polls is still logged; a recovered sample is never accepted")
    func recoveredBetweenPolls() {
        var tracker = RunLoopStallTracker()
        tracker.becameBusy(now: 1)
        let recovered = tracker.becameIdle(now: 70_000_001)
        #expect(recovered?.wasReported == false)
        #expect(recovered?.elapsedNanoseconds == 70_000_000)
        tracker.becameBusy(now: 90_000_000)
        #expect(!tracker.stillBusy(generation: recovered!.generation))
    }

    @Test("sample report keeps only the actual main thread and strips source paths")
    func mainThreadReport() {
        let report = """
        Process: Private Owner App
        Path: /Users/private/secret
        Call graph:
            1 Thread_12 DispatchQueue_1: com.apple.main-thread (serial)
              1 start (in dyld) + 4 [0x123]
                1 Camcord.mainThreadStackSentinel() (in Camcord) + 8 [0x456] /Users/private/file.swift:1
            1 Thread_13 DispatchQueue_2: worker (serial)
              1 watchdogFrame (in Camcord) + 4 [0x789]
        Binary Images:
        /Users/private/Camcord
        """
        let frames = MainThreadStackSampler.mainThreadFrames(from: report)
        #expect(frames.count == 2)
        #expect(frames[1].contains("mainThreadStackSentinel"))
        #expect(!frames.joined().contains("private"))
        #expect(!frames.joined().contains("watchdogFrame"))
        #expect(MainThreadStackSampler.mainThreadFrames(from: "Thread.callStackSymbols") == [])
    }

    @inline(never) private static func mainThreadStackSentinel() -> MainThreadStackSampler.Result? {
        #expect(Thread.isMainThread)
        let completed = DispatchSemaphore(value: 0)
        let sampled = Mutex<MainThreadStackSampler.Result?>(nil)
        // Launch only after this frame exists, then keep it on the actual main thread
        // until the snapshot finishes. Scheduling latency cannot outlive a fixed sleep.
        DispatchQueue.global(qos: .utility).async {
            let result = MainThreadStackSampler.sampleOwnProcess()
            sampled.withLock { $0 = result }
            completed.signal()
        }
        // Match the sampler's existing deadline; a broken sampler fails rather than
        // leaving the test process blocked indefinitely.
        guard completed.wait(timeout: .now() + .seconds(2)) == .success else { return nil }
        return sampled.withLock { $0 }
    }

    @MainActor @Test("system sampler captures a real blocked main-thread frame")
    func genuineMainThreadStack() throws {
        let result = try #require(Self.mainThreadStackSentinel(), "system sampler exceeded its two-second deadline")
        #expect(result.succeeded)
        #expect(result.frames.contains { $0.contains("mainThreadStackSentinel") })
        #expect(!result.frames.contains { $0.contains("sampleOwnProcess") })
        #expect(result.elapsedNanoseconds > 0)
    }

    @MainActor @Test("layout completion waits for a mounted backing view and closes actual Settings content")
    func mountedLayoutCompletion() {
        _ = NSApplication.shared
        let diagnostics = NavigationPerformanceDiagnostics()
        diagnostics.request(.module(.settings))
        diagnostics.request(.settings(.general))
        let view = PerformanceLayoutCompletionBridge.LayoutView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.diagnostics = diagnostics
        view.target = .settings(.general)
        view.generation = diagnostics.generation(for: .settings(.general))
        view.settingsModuleGeneration = diagnostics.generation(for: .module(.settings))
        view.layout()
        #expect(diagnostics.generation(for: .settings(.general)) != nil)
        #expect(diagnostics.generation(for: .module(.settings)) != nil)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        #expect(diagnostics.generation(for: .settings(.general)) == nil)
        #expect(diagnostics.generation(for: .module(.settings)) == nil)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @MainActor @Test("navigation completion requires corresponding layout and preserves newer requests")
    func navigationCompletion() {
        let diagnostics = NavigationPerformanceDiagnostics()
        diagnostics.request(.module(.studio))
        let previous = diagnostics.generation(for: .module(.studio))
        diagnostics.request(.module(.edit))
        #expect(!diagnostics.complete(.module(.studio), generation: previous))
        #expect(diagnostics.generation(for: .module(.edit)) != nil)
        diagnostics.request(.settings(.camera))
        let camera = diagnostics.generation(for: .settings(.camera))
        diagnostics.request(.settings(.input))
        #expect(!diagnostics.complete(.settings(.camera), generation: camera))
        #expect(diagnostics.complete(.settings(.input), generation: diagnostics.generation(for: .settings(.input))))
        #expect(!diagnostics.complete(.settings(.input), generation: nil))
        diagnostics.request(.settings(.camera))
        diagnostics.request(.module(.library))
        #expect(diagnostics.generation(for: .settings(.camera)) == nil)
    }
}
