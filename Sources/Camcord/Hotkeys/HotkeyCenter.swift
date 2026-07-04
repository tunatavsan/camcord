import AppKit
import KeyboardShortcuts

/// Tier 1 of the hotkey engine: global keyboard shortcuts via `KeyboardShortcuts`
/// (Carbon `RegisterEventHotKey` under the hood). Zero TCC permissions required.
///
/// NONE of these ship with a default shortcut — the owner assigns every one from
/// Settings. The primary surfaces are the mouse (side buttons) and the menu-bar
/// panel; keyboard is an opt-in convenience. Recording is started only from the
/// panel, so it has no Name here — only pause/resume is keyboard-drivable.
extension KeyboardShortcuts.Name {
    static let captureRegion = Self("captureRegion")
    static let captureActiveWindow = Self("captureActiveWindow")
    static let captureFullScreen = Self("captureFullScreen")
    static let captureTextRegion = Self("captureTextRegion")
    static let pauseRecording = Self("pauseRecording")
}

@MainActor
final class HotkeyCenter {
    private let coordinator: CaptureCoordinator
    private let recordingController: RecordingController

    init(coordinator: CaptureCoordinator, recordingController: RecordingController) {
        self.coordinator = coordinator
        self.recordingController = recordingController

        KeyboardShortcuts.onKeyDown(for: .captureRegion) { [coordinator] in
            Task { await coordinator.captureRegionInteractive() }
        }
        KeyboardShortcuts.onKeyDown(for: .captureActiveWindow) { [coordinator] in
            Task { await coordinator.captureActiveWindow() }
        }
        KeyboardShortcuts.onKeyDown(for: .captureFullScreen) { [coordinator] in
            Task { await coordinator.captureFullScreen() }
        }
        KeyboardShortcuts.onKeyDown(for: .captureTextRegion) { [coordinator] in
            Task { await coordinator.captureTextRegionInteractive() }
        }
        KeyboardShortcuts.onKeyDown(for: .pauseRecording) { [recordingController] in
            recordingController.pauseResume()
        }
    }
}
