import AppKit
import KeyboardShortcuts

/// Tier 1 of the hotkey engine: global keyboard shortcuts via `KeyboardShortcuts`
/// (Carbon `RegisterEventHotKey` under the hood). Zero TCC permissions required.
///
/// NONE of these ship with a default shortcut — the owner assigns every one from
/// Settings. The primary surfaces are the mouse (side buttons) and the menu-bar
/// panel; keyboard is an opt-in convenience.
extension KeyboardShortcuts.Name {
    static let captureRegion = Self("captureRegion")
    static let captureActiveWindow = Self("captureActiveWindow")
    static let captureFullScreen = Self("captureFullScreen")
    static let captureTextRegion = Self("captureTextRegion")
    static let captureScrolling = Self("captureScrolling")
    /// Starts an interactive recording when idle (region drag, window click, or
    /// right-click = whole screen), and finishes the active one otherwise.
    static let toggleRecording = Self("toggleRecording")
    static let pauseRecording = Self("pauseRecording")
    /// Opens or closes the floating camera preview. Independent of whether the camera is
    /// composited into the file — that is `toggleCameraRecording`.
    static let toggleCameraPreview = Self("toggleCameraPreview")
    static let toggleCameraRecording = Self("toggleCameraRecording")
}

@MainActor
final class HotkeyCenter {
    private let coordinator: CaptureCoordinator
    private let recordingController: RecordingController

    init(coordinator: CaptureCoordinator, recordingController: RecordingController) {
        self.coordinator = coordinator
        self.recordingController = recordingController

        Self.onKeyDown(.captureRegion, "captureRegion") { [coordinator] _ in await coordinator.captureRegionInteractive() }
        Self.onKeyDown(.captureActiveWindow, "captureActiveWindow") { [coordinator] _ in await coordinator.captureActiveWindow() }
        Self.onKeyDown(.captureFullScreen, "captureFullScreen") { [coordinator] _ in await coordinator.captureFullScreen() }
        Self.onKeyDown(.captureTextRegion, "captureTextRegion") { [coordinator] _ in await coordinator.captureTextRegionInteractive() }
        Self.onKeyDown(.captureScrolling, "captureScrolling") { [coordinator] _ in await coordinator.captureScrollingInteractive() }
        Self.onKeyDown(.toggleRecording, "toggleRecording") { [recordingController] context in
            switch Self.recordAction(isBusy: recordingController.isBusy, isGameLike: context.isGameLike) {
            case .gameDisplay: await recordingController.recordFullScreen(gameLike: true)
            case .toggle: await recordingController.toggleRecording()
            }
        }
        Self.onKeyDown(.pauseRecording, "pauseRecording") { [recordingController] _ in recordingController.pauseResume() }
        Self.onKeyDown(.toggleCameraPreview, "toggleCameraPreview") { _ in
            CameraOverlayController.shared.togglePreview()
        }
        // The panel/menu chips write the same state, so nothing else has to be told.
        Self.onKeyDown(.toggleCameraRecording, "toggleCameraRecording") { [weak self] _ in
            guard let self else { return }
            self.onToast?(Self.toggleCameraRecording())
        }
    }

    /// The panel may well be closed when this fires, so the shortcuts say what they did.
    var onToast: ((ToastRequest) -> Void)?

    /// Flips "Kamerayı kaydet" through the same field the panel toggle writes. The
    /// compositor reads the flag live, so this needs no idle gate.
    @discardableResult
    static func toggleCameraRecording() -> ToastRequest {
        var settings = RecordingSettings.load(from: .standard)
        settings.camera.enabled.toggle()
        settings.save(to: .standard)
        return ToastRequest(
            text: settings.camera.enabled ? "Kamera kayda gömülecek" : "Kamera kayda gömülmeyecek",
            systemSymbol: settings.camera.enabled ? "video.fill" : "video.slash.fill",
            tint: .systemBlue,
            important: true
        )
    }

    /// What the record hotkey does (Phase G.6 lite). A game confines the cursor and sits
    /// over every panel we can draw, so an idle trigger there records the covered display
    /// outright instead of opening a picker; anything else — including stopping the run
    /// this started — is the ordinary toggle. The mouse/menu/panel paths are unchanged.
    enum RecordHotkeyAction: Equatable {
        case gameDisplay
        case toggle
    }

    static func recordAction(isBusy: Bool, isGameLike: Bool) -> RecordHotkeyAction {
        isGameLike && !isBusy ? .gameDisplay : .toggle
    }

    /// Every binding logs itself before it runs: in a fullscreen game the first question
    /// is whether the trigger reached us at all (Phase G.1). The measured context is
    /// handed to the action so routing on it costs no second window-list sweep.
    private static func onKeyDown(
        _ name: KeyboardShortcuts.Name,
        _ label: String,
        _ action: @escaping @MainActor (FullscreenContext) async -> Void
    ) {
        KeyboardShortcuts.onKeyDown(for: name) {
            Task { @MainActor in
                await action(TriggerLog.fired("hotkey.\(label)"))
            }
        }
    }
}
