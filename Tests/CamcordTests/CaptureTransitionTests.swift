import AppKit
import Foundation
import Testing
@testable import Camcord

@MainActor @Suite("Observable capture transitions")
struct CaptureTransitionTests {
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
