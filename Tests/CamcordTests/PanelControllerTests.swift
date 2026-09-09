import AppKit
import Foundation
import Testing

@testable import Camcord

@MainActor
private final class DetachedPanelPresentationSpy {
    private(set) var focusRequests: [Bool] = []

    func present(_ panel: NSPanel, shouldFocus: Bool) -> Bool {
        // Exercise a real native host and its layout without putting a test window
        // on the user's desktop or changing the key application.
        panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        focusRequests.append(shouldFocus)
        return true
    }
}

@MainActor
@Suite("Panel controller", .serialized)
struct PanelControllerTests {
    @Test("detached presentation reuses one nonactivating, key-capable native panel")
    func detachedLifecycleAndFocusPolicy() throws {
        _ = NSApplication.shared
        let model = RecordingStateModel()
        let presenter = DetachedPanelPresentationSpy()
        let controller = PanelController(
            model: model,
            actions: PanelActions(),
            detachedPanelPresenter: presenter.present
        )

        controller.presentDetached()
        let firstPanel = try #require(controller.detachedPanelForTesting)
        #expect(controller.isShown)
        #expect(!firstPanel.isVisible)
        #expect(firstPanel.styleMask.contains(.nonactivatingPanel))
        #expect(firstPanel.styleMask.contains(.closable))
        #expect(firstPanel.canBecomeKey)
        #expect(firstPanel.becomesKeyOnlyIfNeeded)

        controller.presentDetached()
        #expect(controller.detachedPanelForTesting === firstPanel)
        #expect(presenter.focusRequests == [true, true])

        controller.close()
        #expect(!controller.isShown)
        #expect(!firstPanel.isVisible)

        controller.presentDetached()
        #expect(controller.detachedPanelForTesting === firstPanel)
        #expect(controller.isShown)
        #expect(!firstPanel.isVisible)
        #expect(presenter.focusRequests == [true, true, true])
        controller.close()
    }

    @Test("detached presentation preserves completion state and follows every card size")
    func statePreservationAndNativeHostSizing() throws {
        _ = NSApplication.shared
        let model = RecordingStateModel()
        let completedURL = URL(fileURLWithPath: "/tmp/camcord-panel-finished.mov")
        model.finishedURL = completedURL
        let presenter = DetachedPanelPresentationSpy()
        let controller = PanelController(
            model: model,
            actions: PanelActions(),
            detachedPanelPresenter: presenter.present
        )

        controller.presentDetached()
        let panel = try #require(controller.detachedPanelForTesting)
        #expect(model.finishedURL == completedURL)
        expectContentSize(panel, width: CapturePanelView.panelWidth, height: CapturePanelView.finishedHeight)

        model.finishedURL = nil
        model.isFinishing = true
        expectContentSize(panel, width: CapturePanelView.panelWidth, height: CapturePanelView.finishingHeight)

        model.isFinishing = false
        model.state = .recording
        expectContentSize(panel, width: CapturePanelView.panelWidth, height: CapturePanelView.activeHeight)

        model.state = .idle
        expectContentSize(panel, width: CapturePanelView.panelWidth, height: CapturePanelView.panelHeight)
        controller.close()
    }

    @Test("an unavailable status anchor falls back to the detached panel")
    func unavailableAnchorFallback() throws {
        _ = NSApplication.shared
        let model = RecordingStateModel()
        let presenter = DetachedPanelPresentationSpy()
        let controller = PanelController(
            model: model,
            actions: PanelActions(),
            detachedPanelPresenter: presenter.present
        )
        let detachedButton = NSStatusBarButton(frame: .zero)

        controller.present(relativeTo: detachedButton)

        #expect(controller.detachedPanelForTesting?.isVisible == false)
        #expect(controller.isShown)
        #expect(presenter.focusRequests == [false])
        controller.close()
    }

    @Test("releasing the recording hold restores transient dismissal and closes the panel")
    func recordingHoldReleaseRestoresTransientBehaviorAndCloses() {
        _ = NSApplication.shared
        let model = RecordingStateModel()
        let presenter = DetachedPanelPresentationSpy()
        let controller = PanelController(
            model: model,
            actions: PanelActions(),
            detachedPanelPresenter: presenter.present
        )

        controller.presentDetached()
        controller.keepOpenForRecording()
        #expect(controller.popoverBehaviorForTesting == .applicationDefined)
        #expect(controller.isShown)

        controller.releaseRecordingHold()

        #expect(controller.popoverBehaviorForTesting == .transient)
        #expect(!controller.isShown)
    }

    private func expectContentSize(_ panel: NSPanel, width: CGFloat, height: CGFloat) {
        #expect(abs(panel.contentLayoutRect.width - width) < 0.5)
        #expect(abs(panel.contentLayoutRect.height - height) < 0.5)
    }
}
