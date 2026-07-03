import AppKit
import KeyboardShortcuts
import os

extension KeyboardShortcuts.Name {
    static let captureRegion = Self("captureRegion", initial: .init(.two, modifiers: [.command, .shift]))
    static let captureActiveWindow = Self("captureActiveWindow", initial: .init(.one, modifiers: [.command, .shift]))
    static let captureFullScreen = Self("captureFullScreen", initial: .init(.six, modifiers: [.command, .shift]))
    static let repeatLastRegion = Self("repeatLastRegion", initial: .init(.r, modifiers: [.command, .shift]))
    static let toggleRecording = Self("toggleRecording", initial: .init(.nine, modifiers: [.command, .shift]))
    static let pauseRecording = Self("pauseRecording", initial: .init(.zero, modifiers: [.command, .shift]))
}

/// Tier 1 of the hotkey engine: global keyboard shortcuts via `KeyboardShortcuts`
/// (Carbon `RegisterEventHotKey` under the hood). Zero TCC permissions required.
/// The four capture shortcuts call straight into `CaptureCoordinator`; the two
/// recording shortcuts call a stub until M3 lands the recording engine.
@MainActor
final class HotkeyCenter {
    private let coordinator: CaptureCoordinator
    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "hotkey-center")

    init(coordinator: CaptureCoordinator) {
        self.coordinator = coordinator

        KeyboardShortcuts.onKeyDown(for: .captureRegion) { [coordinator] in
            Task { await coordinator.captureRegionInteractive() }
        }
        KeyboardShortcuts.onKeyDown(for: .captureActiveWindow) { [coordinator] in
            Task { await coordinator.captureActiveWindow() }
        }
        KeyboardShortcuts.onKeyDown(for: .captureFullScreen) { [coordinator] in
            Task { await coordinator.captureFullScreen() }
        }
        KeyboardShortcuts.onKeyDown(for: .repeatLastRegion) { [coordinator] in
            Task { await coordinator.captureLastRegion() }
        }
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [logger] in
            logger.notice("recording arrives in M3")
            NSSound.beep()
        }
        KeyboardShortcuts.onKeyDown(for: .pauseRecording) { [logger] in
            logger.notice("recording arrives in M3")
            NSSound.beep()
        }
    }
}
