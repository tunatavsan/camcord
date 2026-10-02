import AppKit
@preconcurrency import ScreenCaptureKit
import Testing

@testable import Camcord

/// Drives the production observation/timeout path without ordering a native window.
@MainActor final class SelectionPresentationFixture {
    var now = ContinuousClock.now
    var visible = false
    var changed: (@MainActor () -> Void)?
    private var deadline: ContinuousClock.Instant?
    private var timeout: CheckedContinuation<Void, Error>?
    private var deadlineStarted: CheckedContinuation<Void, Never>?

    var probe: SelectionOverlayController.PresentationProbe {
        .init(read: { (self.visible ? 1 : 0, 1, self.visible) }, observe: { changed in
            self.changed = changed
            return { self.changed = nil }
        })
    }

    var timing: SelectionOverlayController.PresentationTiming {
        .init(now: { self.now }, waitUntil: { deadline in
            try await withCheckedThrowingContinuation {
                self.deadline = deadline
                self.timeout = $0
                self.deadlineStarted?.resume()
                self.deadlineStarted = nil
            }
        })
    }

    func waitForDeadline() async {
        if deadline != nil { return }
        await withCheckedContinuation { deadlineStarted = $0 }
    }

    func advance(by duration: Duration) {
        now += duration
        if let deadline, now >= deadline {
            self.deadline = nil
            timeout?.resume()
            timeout = nil
        }
    }

    func enqueueObservation(visible: Bool) async {
        self.visible = visible
        let callback = changed
        await Task { @MainActor in callback?() }.value
    }

    func overlay() -> SelectionOverlayController {
        .init(shareableContentCache: ShareableContentCache(), presentation: {},
              presentationProbe: probe, presentationTiming: timing)
    }
}

@MainActor
@Suite("Selection lookup lifetime", .serialized)
struct SelectionOverlayLifecycleTests {
    @MainActor final class DeferredWindow {
        var continuation: CheckedContinuation<SCWindow?, Never>?
        func resolve() async -> SCWindow? {
            await withCheckedContinuation { continuation = $0 }
        }
        func complete() { continuation?.resume(returning: nil); continuation = nil }
    }

    private func flush() async { for _ in 0..<30 { await Task.yield() } }

    @Test("an early covered observation waits for actual delayed presentation")
    func delayedPresentation() async {
        let fixture = SelectionPresentationFixture(), overlay = fixture.overlay()
        let selection = Task { await overlay.selectRegion() }
        await fixture.waitForDeadline()
        fixture.advance(by: .milliseconds(50))
        await fixture.enqueueObservation(visible: false)
        #expect(overlay.isPresentingForTesting)
        #expect(!overlay.consumeBlindPresentation())
        fixture.advance(by: .milliseconds(90))
        await fixture.enqueueObservation(visible: true)
        #expect(overlay.isPresentingForTesting)
        #expect(fixture.changed == nil)
        fixture.advance(by: .seconds(1)) // Drain the cancelled fake-clock wait.
        await flush()
        #expect(overlay.isPresentingForTesting)
        #expect(!overlay.consumeBlindPresentation())
        overlay.selectionViewCancel()
        #expect(await selection.value == nil)
    }

    @Test("a cancelled presentation observation cannot end a replacement session")
    func stalePresentationObservation() async {
        let fixture = SelectionPresentationFixture(), overlay = fixture.overlay()
        let first = Task { await overlay.selectRegion() }
        await fixture.waitForDeadline()
        let oldCallback = fixture.changed
        overlay.selectionViewCancel()
        _ = await first.value
        fixture.advance(by: .seconds(1))
        await flush()
        let replacement = Task { await overlay.selectRegion() }
        await fixture.waitForDeadline()
        oldCallback?()
        #expect(overlay.isPresentingForTesting)
        overlay.selectionViewCancel()
        _ = await replacement.value
        fixture.advance(by: .seconds(1))
        await flush()
        #expect(!overlay.consumeBlindPresentation())
    }

    @Test("an old clicked or frozen lookup cannot cancel a replacement selection",
          arguments: [false, true])
    func staleSession(frozen: Bool) async throws {
        let deferred = DeferredWindow()
        let overlay = SelectionOverlayController(shareableContentCache: ShareableContentCache(),
                                                 presentation: {}, clickedResolver: { _ in await deferred.resolve() },
                                                 frozenResolver: { _ in await deferred.resolve() })
        let snapshot = FrozenDesktopSnapshot(displays: [], windows: [
            .init(id: 9, frame: CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000))
        ])
        let first = Task { @MainActor in
            if frozen { _ = await overlay.selectFrozen(snapshot: snapshot) }
            else { _ = await overlay.selectRegion() }
        }
        await flush()
        #expect(overlay.isPresentingForTesting)
        overlay.selectionViewMouseDown(at: .zero, isRight: false)
        overlay.selectionViewMouseUp(at: .zero, isRight: false)
        await flush()
        #expect(deferred.continuation != nil)
        overlay.selectionViewCancel()
        await first.value
        let replacement = Task { @MainActor in _ = await overlay.selectRegion() }
        await flush()
        deferred.complete()
        await flush()
        #expect(overlay.isPresentingForTesting)
        overlay.selectionViewCancel()
        await replacement.value
    }

    @Test("an old lookup cannot end a newer gesture in the same selection",
          arguments: [false, true])
    func staleGesture(frozen: Bool) async {
        let deferred = DeferredWindow()
        let overlay = SelectionOverlayController(shareableContentCache: ShareableContentCache(),
                                                 presentation: {}, clickedResolver: { _ in await deferred.resolve() },
                                                 frozenResolver: { _ in await deferred.resolve() })
        let snapshot = FrozenDesktopSnapshot(displays: [], windows: [
            .init(id: 9, frame: CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000))
        ])
        let selection = Task { @MainActor in
            if frozen { _ = await overlay.selectFrozen(snapshot: snapshot) }
            else { _ = await overlay.selectRegion() }
        }
        await flush()
        overlay.selectionViewMouseDown(at: .zero, isRight: false)
        overlay.selectionViewMouseUp(at: .zero, isRight: false)
        await flush()
        #expect(deferred.continuation != nil)
        overlay.selectionViewMouseDown(at: CGPoint(x: 20, y: 20), isRight: false)
        overlay.selectionViewMouseDragged(to: CGPoint(x: 60, y: 60), isRight: false)
        deferred.complete()
        await flush()
        #expect(overlay.isPresentingForTesting)
        overlay.selectionViewCancel()
        await selection.value
    }
}
