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
}

@MainActor
final class HotkeyCenter {
    private let coordinator: CaptureCoordinator
    private let recordingController: RecordingController

    init(coordinator: CaptureCoordinator, recordingController: RecordingController) {
        self.coordinator = coordinator
        self.recordingController = recordingController

        Self.onKeyDown(.captureRegion, "captureRegion") { [coordinator] in await coordinator.captureRegionInteractive() }
        Self.onKeyDown(.captureActiveWindow, "captureActiveWindow") { [coordinator] in await coordinator.captureActiveWindow() }
        Self.onKeyDown(.captureFullScreen, "captureFullScreen") { [coordinator] in await coordinator.captureFullScreen() }
        Self.onKeyDown(.captureTextRegion, "captureTextRegion") { [coordinator] in await coordinator.captureTextRegionInteractive() }
        Self.onKeyDown(.captureScrolling, "captureScrolling") { [coordinator] in await coordinator.captureScrollingInteractive() }
        Self.onKeyDown(.toggleRecording, "toggleRecording") { [recordingController] in await recordingController.toggleRecording() }
        Self.onKeyDown(.pauseRecording, "pauseRecording") { [recordingController] in recordingController.pauseResume() }
    }

    /// Every binding logs itself before it runs: in a fullscreen game the first question
    /// is whether the trigger reached us at all (Phase G.1).
    private static func onKeyDown(
        _ name: KeyboardShortcuts.Name,
        _ label: String,
        _ action: @escaping @MainActor () async -> Void
    ) {
        KeyboardShortcuts.onKeyDown(for: name) {
            Task { @MainActor in
                TriggerLog.fired("hotkey.\(label)")
                await action()
            }
        }
    }
}
