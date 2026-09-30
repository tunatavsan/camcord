import CoreGraphics
import Foundation
import Testing
import os

@testable import Camcord

@MainActor
@Suite("Scrolling session failure paths")
struct ScrollingSessionTests {
    enum Failure: Error { case query, capture }
    @MainActor private final class Script {
        var results: [Result<CGImage, Failure>] = []
        var calls = 0
        var updates = 0
        var completedCaptures = 0
        var completedPreparations = 0
        var pauseCapture = false
        var captureContinuation: CheckedContinuation<Void, Never>?
        var hidden = 0
        var done: (() -> Void)?
        var cancel: (() -> Void)?
        var queryFails = false
        var queryContinuation: CheckedContinuation<Void, Never>?
        var pauseQuery = false
        var hooks: ScrollingCaptureSession.Hooks {
            .init(prepare: { [self] in
                if pauseQuery { await withCheckedContinuation { queryContinuation = $0 } }
                if queryFails { throw Failure.query }
            }, capture: { [self] _ in
                calls += 1
                if pauseCapture { await withCheckedContinuation { captureContinuation = $0 } }
                guard !results.isEmpty else { throw Failure.capture }
                return try results.removeFirst().get()
            }, show: { [self] in done = $0; cancel = $1 }, hide: { [self] in hidden += 1 }, update: { [self] _, _ in updates += 1 },
               preparationCompleted: { [self] in completedPreparations += 1 },
               captureCompleted: { [self] in completedCaptures += 1 })
        }
    }

    /// Only the fake synchronous worker hook blocks. The main actor controls release,
    /// and a monotonic timeout prevents a failed fixture from stranding a pool thread.
    private final class WorkerGate: Sendable {
        let state = OSAllocatedUnfairLock(initialState: (started: 0, ended: 0, onMain: false, timedOut: false))
        let permit = DispatchSemaphore(value: 0)
        func work() {
            let onMain = Thread.isMainThread
            state.withLock { $0.started += 1; $0.onMain = $0.onMain || onMain }
            // A deliberately main-actor mutant must fail without blocking the UI thread.
            let released = onMain || permit.wait(timeout: .now() + .seconds(20)) == .success
            state.withLock { $0.ended += 1; $0.timedOut = $0.timedOut || !released }
        }
        func release() { permit.signal() }
    }

    private func image(offset: Int, height: Int = 120) -> CGImage {
        let width = 40
        let bytes = (0..<(width * height)).map { index -> UInt8 in
            var z = UInt64((index / width + offset) * 40_503 + (index % width) * 92_821) &+ 0x9E3779B97F4A7C15
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return UInt8(truncatingIfNeeded: z ^ (z >> 31)) % 220
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    @Test("three runtime capture errors preserve all useful captured pixels and teardown once")
    func runtimeFailurePreservesPartial() async throws {
        let script = Script()
        script.results = [.success(image(offset: 0)), .success(image(offset: 30)), .success(image(offset: 60)),
                          .failure(.capture), .failure(.capture), .failure(.capture)]
        let session = ScrollingCaptureSession(region: CGRect(x: 0, y: 0, width: 40, height: 120), hooks: script.hooks)
        let run = Task { await session.run() }
        await waitUntil { script.calls == 1 && session.readyForCaptureForTesting }
        await session.captureNextFrameForTesting(predictedPoints: 30)
        await session.captureNextFrameForTesting(predictedPoints: 30)
        for _ in 0..<3 { await session.captureNextFrameForTesting() }
        let outcome = await run.value
        guard case .completed(let partial, let notice) = outcome else {
            Issue.record("Captured pages must survive a runtime failure: \(outcome)")
            return
        }
        #expect(partial.width == 40)
        #expect(partial.height == 180)
        #expect(notice == .captureFailed)
        #expect(script.hidden == 1)
    }

    @Test("user cancellation discards pixels silently while repeated failures without pixels report failure",
          arguments: [false, true])
    func cancellationAndEmptyFailure(failing: Bool) async {
        let script = Script()
        script.results = failing ? Array(repeating: .failure(.capture), count: 3) : [.success(image(offset: 0))]
        let session = ScrollingCaptureSession(region: CGRect(x: 0, y: 0, width: 40, height: 120), hooks: script.hooks)
        let run = Task { await session.run() }
        await waitUntil { script.calls == 1 && session.readyForCaptureForTesting }
        if failing {
            await session.captureNextFrameForTesting()
            await session.captureNextFrameForTesting()
        } else {
            script.cancel?()
        }
        switch await run.value {
        case .cancelled: #expect(!failing)
        case .failed(let notice): #expect(failing && notice == .captureFailed)
        case .completed: Issue.record("Cancel/empty failure must not return an image")
        }
        #expect(script.hidden == 1)
    }

    @Test("failed exclusion enumeration never captures a possibly contaminated baseline")
    func exclusionFailureStopsPreparation() async {
        let script = Script()
        script.queryFails = true
        script.results = [.success(image(offset: 0))]
        let session = ScrollingCaptureSession(region: CGRect(x: 0, y: 0, width: 40, height: 120), hooks: script.hooks)
        let run = Task { await session.run() }
        await waitUntil { script.hidden == 1 || script.calls > 0 }
        #expect(script.calls == 0)
        if script.hidden == 0 { script.cancel?() }
        guard case .failed(.preparationFailed) = await run.value else {
            Issue.record("An exclusion-query failure needs explicit failure feedback")
            return
        }
        #expect(script.hidden == 1)
    }

    @Test("immediate Cancel resolves once while exclusion preparation is suspended")
    func cancelDuringPreparation() async {
        let script = Script()
        script.pauseQuery = true
        script.results = [.success(image(offset: 0))]
        let session = ScrollingCaptureSession(region: CGRect(x: 0, y: 0, width: 40, height: 120), hooks: script.hooks)
        let run = Task { await session.run() }
        await waitUntil { script.queryContinuation != nil }
        script.cancel?()
        guard case .cancelled = await run.value else { Issue.record("Cancel must resolve immediately"); return }
        script.queryContinuation?.resume()
        script.queryContinuation = nil
        await waitUntil { script.completedPreparations == 1 }
        #expect(script.calls == 0)
        #expect(script.hidden == 1)
    }
    @Test("the pixel budget retains the baseline prefix and reports a useful limit notice")
    func baselinePixelLimit() async {
        let script = Script()
        script.results = [.success(image(offset: 0))]
        let session = ScrollingCaptureSession(region: CGRect(x: 0, y: 0, width: 40, height: 120),
                                              hooks: script.hooks, maxTotalPixels: 40 * 75 + 39)
        let outcome = await session.run()
        guard case .completed(let partial, .outputLimit) = outcome else {
            Issue.record("A capped baseline must remain useful: \(outcome)"); return
        }
        #expect(partial.width == 40 && partial.height == 75)
        #expect(script.calls == 1 && script.hidden == 1)
    }

    @Test("slow matching leaves the main actor responsive and Cancel suppresses its late snapshot",
          arguments: [false, true])
    func cancelDuringWorker(finishing: Bool) async {
        let work = WorkerGate()
        defer { work.release() }
        let script = Script()
        script.results = [.success(image(offset: 0)), .success(image(offset: 30))]
        let session = ScrollingCaptureSession(region: CGRect(x: 0, y: 0, width: 40, height: 120),
                                              hooks: script.hooks, workHook: { work.work() })
        let run = Task { await session.run() }
        await waitUntil { work.state.withLock { $0.started >= 1 } }
        if finishing {
            work.release()
            await waitUntil { session.readyForCaptureForTesting && script.completedCaptures == 1 }
            script.done?()
        }
        let expectedWork = finishing ? 2 : 1
        await waitUntil { work.state.withLock { $0.started >= expectedWork } }
        // The worker cannot finish until this main-actor test explicitly releases it.
        #expect(work.state.withLock { $0.ended < expectedWork && !$0.onMain && !$0.timedOut })
        let updatesBeforeCancel = script.updates
        script.cancel?()
        guard case .cancelled = await run.value else { Issue.record("Cancel must resolve during worker work"); return }
        work.release()
        await waitUntil { script.completedCaptures == expectedWork }
        #expect(work.state.withLock { $0.ended == expectedWork && !$0.timedOut })
        #expect(script.updates == updatesBeforeCancel)
        #expect(script.hidden == 1)
    }

    @Test("a suspended capture cannot advance a replacement auto-scroll segment")
    func staleAutoSegmentDoesNotAdvance() async {
        let script = Script()
        script.results = [.success(image(offset: 0)), .success(image(offset: 30))]
        let session = ScrollingCaptureSession(region: CGRect(x: 0, y: 0, width: 40, height: 120), hooks: script.hooks)
        let run = Task { await session.run() }
        await waitUntil { script.calls == 1 && session.readyForCaptureForTesting }
        session.resetAutoSegmentForTesting()
        script.pauseCapture = true
        let capture = Task { await session.captureNextFrameForTesting(predictedPoints: 30) }
        await waitUntil { script.captureContinuation != nil }
        session.resetAutoSegmentForTesting()
        script.captureContinuation?.resume()
        script.captureContinuation = nil
        await capture.value
        #expect(session.autoProgressForTesting == AutoScrollProgress())
        script.cancel?()
        _ = await run.value
    }

    @Test("synchronous presenter cancellation resolves before preparation begins")
    func cancelOnPresentation() async {
        var prepares = 0
        var captures = 0
        var hides = 0
        let hooks = ScrollingCaptureSession.Hooks(prepare: { prepares += 1 }, capture: { _ in
            captures += 1
            return image(offset: 0)
        }, show: { _, cancel in cancel() }, hide: { hides += 1 })
        let outcome = await ScrollingCaptureSession(region: CGRect(x: 0, y: 0, width: 40, height: 120), hooks: hooks).run()
        guard case .cancelled = outcome else { Issue.record("Immediate Cancel must resolve"); return }
        #expect(prepares == 0 && captures == 0 && hides == 1)
    }

}
