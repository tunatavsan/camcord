import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
    }
}
