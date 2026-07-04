import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let didAttemptLoginItemKey = "didAttemptLoginItemRegistration"
    private var captureCoordinator: CaptureCoordinator?
    private var recordingController: RecordingController?
    private var hotkeyCenter: HotkeyCenter?
    private var eventTapEngine: EventTapEngine?
    private var settingsWindowController: SettingsWindowController?
    private var statusItemController: StatusItemController?
    private var panelController: PanelController?
    private var recordingStateModel: RecordingStateModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Warm the feedback-sound cache so the first cue has zero setup latency.
        FeedbackSound.preloadAll()

        let coordinator = CaptureCoordinator()
        captureCoordinator = coordinator

        let recordingController = RecordingController(coordinator: coordinator)
        self.recordingController = recordingController

        let hotkeyCenter = HotkeyCenter(coordinator: coordinator, recordingController: recordingController)
        self.hotkeyCenter = hotkeyCenter

        let eventTapEngine = EventTapEngine(coordinator: coordinator, recordingController: recordingController)
        self.eventTapEngine = eventTapEngine
        // Apply whatever Tier-2 bindings were persisted from a previous launch; this
        // creates the tap only if bindings are enabled AND Accessibility is trusted.
        eventTapEngine.apply(TapBindings.load(from: .standard))

        let settingsWindowController = SettingsWindowController(eventTapEngine: eventTapEngine)
        self.settingsWindowController = settingsWindowController

        let statusItemController = StatusItemController(
            coordinator: coordinator,
            recordingController: recordingController,
            eventTapEngine: eventTapEngine,
            settingsWindowController: settingsWindowController
        )
        self.statusItemController = statusItemController

        let recordingStateModel = RecordingStateModel()
        self.recordingStateModel = recordingStateModel

        recordingController.onUIChange = { [weak statusItemController, weak recordingStateModel] state, elapsed in
            statusItemController?.setRecordingUI(state, elapsed: elapsed)
            recordingStateModel?.state = state
            recordingStateModel?.elapsed = elapsed
            // A new/live recording clears any lingering "done" card.
            if state != .idle {
                recordingStateModel?.finishedURL = nil
                recordingStateModel?.isFinishing = false
            }
        }
        recordingController.onFinishing = { [weak recordingStateModel] finishing in
            recordingStateModel?.isFinishing = finishing
        }
        recordingController.onRecordingFinished = { [weak recordingStateModel] url in
            recordingStateModel?.isFinishing = false
            recordingStateModel?.finishedURL = url
        }

        // Every failure beep gets a visual companion on the status glyph.
        let flashFailure: () -> Void = { [weak statusItemController] in
            statusItemController?.flashFailure()
        }
        coordinator.onFailure = flashFailure
        recordingController.onFailure = flashFailure

        let panelActions = makePanelActions(coordinator: coordinator, recordingController: recordingController)
        let panelController = PanelController(model: recordingStateModel, actions: panelActions)
        self.panelController = panelController

        statusItemController.onPrimaryClick = { [weak panelController, weak statusItemController] in
            guard let button = statusItemController?.anchorButton else { return }
            panelController?.toggle(relativeTo: button)
        }

        registerLoginItemOnFirstRun()
    }

    /// Panel actions: overlay-opening flows close the panel first and give the
    /// popover a beat to dismiss (same choreography as the context menu's 200ms).
    private func makePanelActions(
        coordinator: CaptureCoordinator,
        recordingController: RecordingController
    ) -> PanelActions {
        var actions = PanelActions()

        let afterClosingPanel: (@escaping @MainActor () async -> Void) -> Void = { [weak self] work in
            self?.panelController?.close()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                await work()
            }
        }

        actions.captureRegion = {
            afterClosingPanel { await coordinator.captureRegionInteractive() }
        }
        actions.captureWindow = {
            afterClosingPanel { await coordinator.captureActiveWindow() }
        }
        actions.captureScreen = {
            afterClosingPanel { await coordinator.captureFullScreen() }
        }
        actions.captureText = {
            afterClosingPanel { await coordinator.captureTextRegionInteractive() }
        }
        actions.toggleRecording = { [weak recordingController] in
            let isIdle = recordingController?.uiState == .idle
            if isIdle {
                // Starting opens the selection overlay -- close the panel first.
                afterClosingPanel { await recordingController?.toggleRecording() }
            } else {
                // Stopping is instant; keep the panel up so the row morphs back.
                Task { await recordingController?.toggleRecording() }
            }
        }
        actions.recordFullScreen = { [weak recordingController] in
            afterClosingPanel { await recordingController?.recordFullScreen() }
        }
        actions.pauseResume = { [weak recordingController] in
            recordingController?.pauseResume()
        }
        actions.revealRecording = { [weak self] url in
            self?.panelController?.close()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        actions.openRecording = { [weak self] url in
            self?.panelController?.close()
            NSWorkspace.shared.open(url)
        }
        actions.openSettings = { [weak self] in
            self?.panelController?.close()
            self?.settingsWindowController?.show()
        }
        return actions
    }

    /// The whole point of the app is being resident from login -- register the login
    /// item automatically on first run (once; the menu toggle stays in control after).
    private func registerLoginItemOnFirstRun() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didAttemptLoginItemKey) else { return }
        defaults.set(true, forKey: Self.didAttemptLoginItemKey)
        guard SMAppService.mainApp.status == .notRegistered else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            // .requiresApproval and transient failures both surface in the menu's
            // Launch at Login state; nothing to do here.
        }
    }

    private var isTerminating = false
    private var didReplyToTermination = false

    /// Don't tear the process down mid-recording: stop (and finalize the file) first,
    /// then terminate. Screenshots are one-shot and need no such guard.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Re-entrancy: a second Cmd-Q while the first is finalizing must not
        // terminateNow and kill the process before the moov atom is written.
        if isTerminating {
            return .terminateLater
        }
        // `.idle` alone is not "nothing in flight": stop() flips it immediately for
        // UI feedback while the finalize is still writing the file (isFinalizing).
        guard let recordingController,
            recordingController.uiState != .idle || recordingController.isFinalizing
        else {
            return .terminateNow
        }
        isTerminating = true
        Task { @MainActor in
            await recordingController.stopForTermination()
            self.replyToTerminationOnce(sender)
        }
        // Failsafe: if the finalize wedges (hung replayd/disk), still answer Cmd-Q
        // eventually — a personal menu-bar app must never need a Force Quit.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            self.replyToTerminationOnce(sender)
        }
        return .terminateLater
    }

    private func replyToTerminationOnce(_ sender: NSApplication) {
        guard !didReplyToTermination else { return }
        didReplyToTermination = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}
