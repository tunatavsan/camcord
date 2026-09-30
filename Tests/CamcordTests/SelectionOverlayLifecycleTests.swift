import AppKit
@preconcurrency import ScreenCaptureKit
import Testing

@testable import Camcord

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
