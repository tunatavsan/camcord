import AppKit
import CoreGraphics
import KeyboardShortcuts
import ServiceManagement
import os

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let coordinator: CaptureCoordinator
    private let eventTapEngine: EventTapEngine
    private let settingsWindowController: SettingsWindowController

    private let captureRegionItem = NSMenuItem(title: "Capture Region", action: nil, keyEquivalent: "")
    private let captureActiveWindowItem = NSMenuItem(title: "Capture Active Window", action: nil, keyEquivalent: "")
    private let captureFullScreenItem = NSMenuItem(title: "Capture Full Screen", action: nil, keyEquivalent: "")
    private let repeatLastRegionItem = NSMenuItem(title: "Repeat Last Region", action: nil, keyEquivalent: "")
    private let screenRecordingStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let requestScreenRecordingItem = NSMenuItem(title: "Request Screen Recording…", action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    private let tapStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ",")

    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "app")

    init(coordinator: CaptureCoordinator, eventTapEngine: EventTapEngine, settingsWindowController: SettingsWindowController) {
        self.coordinator = coordinator
        self.eventTapEngine = eventTapEngine
        self.settingsWindowController = settingsWindowController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Camcord")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        menu.delegate = self

        captureRegionItem.target = self
        captureRegionItem.action = #selector(captureRegion)
        captureRegionItem.setShortcut(for: .captureRegion)
        menu.addItem(captureRegionItem)

        captureActiveWindowItem.target = self
        captureActiveWindowItem.action = #selector(captureActiveWindow)
        captureActiveWindowItem.setShortcut(for: .captureActiveWindow)
        menu.addItem(captureActiveWindowItem)

        captureFullScreenItem.target = self
        captureFullScreenItem.action = #selector(captureFullScreen)
        captureFullScreenItem.setShortcut(for: .captureFullScreen)
        menu.addItem(captureFullScreenItem)

        repeatLastRegionItem.target = self
        repeatLastRegionItem.action = #selector(repeatLastRegion)
        repeatLastRegionItem.setShortcut(for: .repeatLastRegion)
        menu.addItem(repeatLastRegionItem)

        menu.addItem(.separator())

        screenRecordingStatusItem.isEnabled = false
        menu.addItem(screenRecordingStatusItem)

        requestScreenRecordingItem.target = self
        requestScreenRecordingItem.action = #selector(requestScreenRecording)
        menu.addItem(requestScreenRecordingItem)

        launchAtLoginItem.target = self
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        menu.addItem(launchAtLoginItem)

        tapStatusItem.target = self
        tapStatusItem.action = #selector(tapStatusClicked)
        tapStatusItem.isHidden = true
        menu.addItem(tapStatusItem)

        menu.addItem(.separator())

        settingsItem.target = self
        settingsItem.action = #selector(openSettings)
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit Camcord", action: #selector(quit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        refreshScreenRecordingState()
        refreshLaunchAtLoginState()
        refreshTapStatus()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refreshScreenRecordingState()
        refreshLaunchAtLoginState()
        refreshTapStatus()
    }

    // MARK: - Dynamic state

    private func refreshScreenRecordingState() {
        let granted = CGPreflightScreenCaptureAccess()
        screenRecordingStatusItem.title = granted ? "Screen Recording: Granted" : "Screen Recording: Not granted"
        requestScreenRecordingItem.isHidden = granted
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// Tier-2 (mouse button / double-tap) status line: hidden unless at least one
    /// Tier-2 binding is enabled but it isn't actually working yet (missing
    /// Accessibility permission, or the tap failed to come up).
    private func refreshTapStatus() {
        guard TapBindings.load(from: .standard).anyEnabled else {
            tapStatusItem.isHidden = true
            return
        }
        if !AccessibilityPermission.isTrusted() {
            tapStatusItem.title = "Accessibility izni gerekli — Aç"
            tapStatusItem.isHidden = false
        } else if !eventTapEngine.isTapHealthy {
            tapStatusItem.title = "Fare/hareket bağlantısı devre dışı"
            tapStatusItem.isHidden = false
        } else {
            tapStatusItem.isHidden = true
        }
    }

    // MARK: - Capture actions

    @objc private func captureRegion() {
        Task {
            // The menu is still open/closing when this fires; give it time to close
            // before showing the overlay panels, or the menu's own chrome briefly
            // overlaps them. M2's global hotkey path won't need this (no menu involved).
            try? await Task.sleep(for: .milliseconds(200))
            await coordinator.captureRegionInteractive()
        }
    }

    @objc private func captureActiveWindow() {
        Task {
            await coordinator.captureActiveWindow()
        }
    }

    @objc private func captureFullScreen() {
        Task {
            await coordinator.captureFullScreen()
        }
    }

    @objc private func repeatLastRegion() {
        Task {
            await coordinator.captureLastRegion()
        }
    }

    // MARK: - Actions

    @objc private func requestScreenRecording() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            do {
                try service.unregister()
            } catch {
                logger.error("Failed to unregister login item: \(error.localizedDescription, privacy: .public)")
            }
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
        default:
            do {
                try service.register()
            } catch {
                logger.error("Failed to register login item: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func tapStatusClicked() {
        guard !AccessibilityPermission.isTrusted() else { return }
        AccessibilityPermission.requestAccess()
    }

    @objc private func openSettings() {
        settingsWindowController.show()
    }
}
