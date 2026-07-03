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

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        recordingController.onUIChange = { [weak statusItemController] state, elapsed in
            statusItemController?.setRecordingUI(state, elapsed: elapsed)
        }

        registerLoginItemOnFirstRun()
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

    /// Don't tear the process down mid-recording: stop (and finalize the file) first,
    /// then terminate. Screenshots are one-shot and need no such guard.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recordingController, recordingController.uiState != .idle else {
            return .terminateNow
        }
        Task {
            await recordingController.toggleRecording()  // stops + finalizes
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
