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

/// Every shortcut the app offers, in the order Settings lists them, with the label the owner
/// reads. One list so the recorders and the conflict check can never drift apart.
enum ShortcutCatalogue {
    static let all: [(name: KeyboardShortcuts.Name, label: String)] = [
        (.captureRegion, "Bölge çek"),
        (.captureActiveWindow, "Aktif pencere çek"),
        (.captureFullScreen, "Tüm ekranı çek"),
        (.captureTextRegion, "Metni çek (OCR)"),
        (.captureScrolling, "Kaydırmalı çekim"),
        (.toggleRecording, "Kayıt başlat / bitir"),
        (.pauseRecording, "Kaydı duraklat / sürdür"),
        (.toggleCameraPreview, "Kamera önizlemesi aç / kapat"),
        (.toggleCameraRecording, "Kamerayı kayda göm aç / kapat"),
    ]

    static func label(for name: KeyboardShortcuts.Name) -> String {
        all.first { $0.name == name }?.label ?? name.rawValue
    }

    /// The OTHER action already holding `shortcut`, if any. Pure so the rule can be tested
    /// without touching the real defaults; `assignments` is what is currently stored.
    static func conflict(
        assigning shortcut: KeyboardShortcuts.Shortcut,
        to name: KeyboardShortcuts.Name,
        in assignments: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut]
    ) -> KeyboardShortcuts.Name? {
        assignments.first { $0.key != name && $0.value == shortcut }?.key
    }

    /// What Settings currently has stored, in catalogue order.
    @MainActor
    static func assignments() -> [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] {
        var result: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [:]
        for entry in all {
            if let shortcut = KeyboardShortcuts.getShortcut(for: entry.name) { result[entry.name] = shortcut }
        }
        return result
    }
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
            self.onToast?(Self.toggleCameraRecording(isBusy: self.recordingController.isBusy))
        }
    }

    /// The panel may well be closed when this fires, so the shortcuts say what they did.
    var onToast: ((ToastRequest) -> Void)?

    /// Flips "Kamerayı kaydet" through the same field the panel toggle writes — and refuses
    /// mid-recording exactly like that toggle does. The engine binds its camera source when
    /// the recording starts: turning the flag on afterwards composites nothing, so a toast
    /// promising a camera in the file would be a lie.
    @discardableResult
    static func toggleCameraRecording(isBusy: Bool) -> ToastRequest {
        guard !isBusy else {
            return ToastRequest(
                text: "Kayıt sürerken değiştirilemez",
                systemSymbol: "exclamationmark.circle.fill",
                tint: .systemOrange,
                important: true
            )
        }
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
    /// Every name this process has bound a handler to. A shortcut the owner can record in
    /// Settings but that nothing listens for is a dead key, and nothing else would catch it.
    private(set) static var boundNames: Set<String> = []

    private static func onKeyDown(
        _ name: KeyboardShortcuts.Name,
        _ label: String,
        _ action: @escaping @MainActor (FullscreenContext) async -> Void
    ) {
        boundNames.insert(name.rawValue)
        KeyboardShortcuts.onKeyDown(for: name) {
            Task { @MainActor in
                await action(TriggerLog.fired("hotkey.\(label)"))
            }
        }
    }
}
