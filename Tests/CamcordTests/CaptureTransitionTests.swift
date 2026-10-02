import AppKit
import Foundation
import Testing
@testable import Camcord

@MainActor @Suite("Observable capture transitions")
struct CaptureTransitionTests {
    private func regionOperations(snapshot: FrozenDesktopSnapshot, context: FullscreenContext) -> CaptureCoordinator.Operations {
        var operations = CaptureCoordinator.Operations()
        operations.feedback = false
        operations.screenCaptureAuthorized = { true }
        operations.screenshotSettings = { ScreenshotSettings(saveToDisk: false) }
        operations.regionCursorPoint = { CGPoint(x: 10, y: 10) }
        operations.regionFullscreenContext = { context }
        operations.regionSnapshotLog = { _ in }
        operations.regionFallbackLog = { _ in }
        operations.captureFrozenDesktop = { _, _ in snapshot }
        return operations
    }

    private func regionSnapshot() throws -> FrozenDesktopSnapshot {
        let pixels = try #require(CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        return .init(displays: [.init(id: 17, cgFrame: CGRect(x: 0, y: 0, width: 100, height: 80), image: pixels)],
                     windows: [])
    }

    @Test("a presented region publishes only the user's crop even after an early invisible probe",
          arguments: [0, 140])
    func delayedRegionPresentation(milliseconds: Int) async throws {
        let fixture = SelectionPresentationFixture(), overlay = fixture.overlay()
        let context = FullscreenContext(displayID: 17, frontmostBundleID: "com.example.desktop", coversDisplay: false,
                                        windowLayer: 0, displayCaptured: false)
        var operations = regionOperations(snapshot: try regionSnapshot(), context: context)
        var copied: [CGSize] = [], failures = 0
        operations.copyPNG = { _, size, _, shouldPublish, _ in
            guard shouldPublish() else { return false }; copied.append(size); return true
        }
        let coordinator = CaptureCoordinator(operations: operations, selectionOverlay: overlay)
        coordinator.onFailure = { failures += 1 }
        let capture = Task { await coordinator.captureRegionInteractive() }
        await fixture.waitForDeadline()
        if milliseconds > 0 {
            fixture.advance(by: .milliseconds(50))
            await fixture.enqueueObservation(visible: false)
            #expect(copied.isEmpty && failures == 0 && overlay.isPresentingForTesting)
            fixture.advance(by: .milliseconds(milliseconds - 50))
        }
        await fixture.enqueueObservation(visible: true)
        let height = try #require(NSScreen.screens.first?.frame.height)
        overlay.selectionViewMouseDown(at: CGPoint(x: 10, y: height - 10), isRight: false)
        overlay.selectionViewMouseDragged(to: CGPoint(x: 50, y: height - 40), isRight: false)
        overlay.selectionViewMouseUp(at: CGPoint(x: 50, y: height - 40), isRight: false)
        await capture.value
        fixture.advance(by: .seconds(1))
        #expect(copied == [CGSize(width: 40, height: 30)])
        #expect(failures == 0 && !coordinator.captureTransition.isActive)
    }

    @Test("presentation timeout fails ordinary region requests and preserves explicit game or cover fallback",
          arguments: [0, 1, 2])
    func regionPresentationTimeout(contextKind: Int) async throws {
        let fixture = SelectionPresentationFixture(), overlay = fixture.overlay()
        let context = FullscreenContext(displayID: 17, frontmostBundleID: contextKind == 2 ? nil : "com.example.app",
                                        coversDisplay: contextKind != 0, windowLayer: 0, displayCaptured: false)
        var operations = regionOperations(snapshot: try regionSnapshot(), context: context)
        var copied: [CGSize] = [], failures = 0, notices = 0
        operations.copyPNG = { _, size, _, shouldPublish, _ in
            guard shouldPublish() else { return false }; copied.append(size); return true
        }
        let coordinator = CaptureCoordinator(operations: operations, selectionOverlay: overlay)
        coordinator.onFailure = { failures += 1 }
        coordinator.onToast = { _ in notices += 1 }
        let capture = Task { await coordinator.captureRegionInteractive() }
        await fixture.waitForDeadline()
        fixture.advance(by: .milliseconds(50))
        await fixture.enqueueObservation(visible: false)
        #expect(copied.isEmpty && failures == 0 && overlay.isPresentingForTesting)
        fixture.advance(by: .milliseconds(450))
        await capture.value
        #expect(copied == (contextKind == 0 ? [] : [CGSize(width: 100, height: 80)]))
        #expect(failures == (contextKind == 0 ? 1 : 0))
        #expect(notices == (contextKind == 0 ? 1 : 0))
        #expect(!coordinator.captureTransition.isActive && !overlay.isPresentingForTesting)
    }

    @Test("exclusive capture exposes stable observable activity through an awaited operation")
    func delayedExclusiveCapture() async throws {
        var pending: CheckedContinuation<(image: CGImage, pointSize: CGSize), Error>?
        var selectedDisplays = 0
        var operations = CaptureCoordinator.Operations()
        operations.feedback = false
        operations.screenshotSettings = { ScreenshotSettings() }
        operations.screenCaptureAuthorized = { true }
        operations.fullScreen = { try await withCheckedThrowingContinuation { pending = $0 } }
        operations.fullScreenDisplayID = { selectedDisplays += 1; return 17 }
        operations.copyPNG = { _, _, _, _, _ in false }
        let coordinator = CaptureCoordinator(operations: operations)
        let identity = coordinator.captureTransition
        let task = Task { await coordinator.captureFullScreen() }
        try await wait { pending != nil }
        #expect(identity === coordinator.captureTransition)
        #expect(identity.isActive && coordinator.isCaptureTransitionActive)
        await coordinator.captureFullScreen()
        #expect(selectedDisplays == 1)
        pending?.resume(throwing: CancellationError())
        await task.value
        #expect(!identity.isActive)
    }

    @Test("cancelled noncooperative hold stays active until its snapshot await drains")
    func cancelledPendingHold() async throws {
        var pending: CheckedContinuation<FrozenDesktopSnapshot, Error>?
        var operations = CaptureCoordinator.Operations()
        operations.feedback = false
        operations.screenshotSettings = { ScreenshotSettings() }
        operations.screenCaptureAuthorized = { true }
        operations.captureFrozenDesktop = { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
        let coordinator = CaptureCoordinator(operations: operations)
        let screen = try #require(NSScreen.screens.first)
        #expect(coordinator.beginHoldRegionSelection(atCGPoint: CGPoint(x: screen.frame.midX, y: screen.frame.midY),
                                                      mode: .screenshot))
        try await wait { pending != nil }
        coordinator.cancelHoldRegionSelection()
        #expect(coordinator.captureTransition.isActive)
        pending?.resume(returning: FrozenDesktopSnapshot(displays: [], windows: []))
        try await wait { !coordinator.captureTransition.isActive }
        #expect(!coordinator.isCaptureTransitionActive)
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
}
