import AVFoundation
import AppKit
import CoreGraphics
import KeyboardShortcuts
import ServiceManagement
import os

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let coordinator: CaptureCoordinator
    private let recordingController: RecordingController
    private let eventTapEngine: EventTapEngine
    private let settingsWindowController: SettingsWindowController

    private let captureRegionItem = NSMenuItem(title: "Bölgeyi Çek", action: nil, keyEquivalent: "")
    private let captureActiveWindowItem = NSMenuItem(title: "Aktif Pencereyi Çek", action: nil, keyEquivalent: "")
    private let captureFullScreenItem = NSMenuItem(title: "Tüm Ekranı Çek", action: nil, keyEquivalent: "")
    private let captureTextItem = NSMenuItem(title: "Metni Çek (OCR)", action: nil, keyEquivalent: "")
    private let recordToggleItem = NSMenuItem(title: "Kayda Başla…", action: nil, keyEquivalent: "")
    private let recordFullScreenItem = NSMenuItem(title: "Tüm Ekranı Kaydet", action: nil, keyEquivalent: "")
    private let pauseResumeItem = NSMenuItem(title: "Kaydı Duraklat", action: nil, keyEquivalent: "")
    private let screenRecordingStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let requestScreenRecordingItem = NSMenuItem(title: "Ekran Kaydı İzni İste…", action: nil, keyEquivalent: "")
    private let micStatusItem = NSMenuItem(title: "Mikrofon izni yok — Aç", action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Bilgisayar Açılışında Başlat", action: nil, keyEquivalent: "")
    private let tapStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "Ayarlar…", action: nil, keyEquivalent: ",")

    private let menu = NSMenu()

    /// Left-click surface (the panel); wired by AppDelegate. Right-click opens the
    /// context menu with the permission/login rows.
    var onPrimaryClick: (() -> Void)?

    /// Anchor for the popover panel.
    var anchorButton: NSStatusBarButton? { statusItem.button }

    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "app")

    init(
        coordinator: CaptureCoordinator,
        recordingController: RecordingController,
        eventTapEngine: EventTapEngine,
        settingsWindowController: SettingsWindowController
    ) {
        self.coordinator = coordinator
        self.recordingController = recordingController
        self.eventTapEngine = eventTapEngine
        self.settingsWindowController = settingsWindowController
        // variableLength from the start: the item sizes to its content (icon-only
        // when idle, icon+elapsed while recording). Switching lengths at runtime
        // would shift the anchor out from under an open popover.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Camcord")
            image?.isTemplate = true
            button.image = image
            // Left-click -> panel, right-click -> context menu. The menu is NOT
            // permanently assigned to the status item (that would hijack all clicks);
            // it's attached just-in-time in showContextMenu().
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

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

        captureTextItem.target = self
        captureTextItem.action = #selector(captureTextRegion)
        captureTextItem.setShortcut(for: .captureTextRegion)
        menu.addItem(captureTextItem)

        menu.addItem(.separator())

        // Recording is started from the panel/menu only (no keyboard default); the
        // owner can bind pause/resume from Settings.
        recordToggleItem.target = self
        recordToggleItem.action = #selector(toggleRecording)
        menu.addItem(recordToggleItem)

        recordFullScreenItem.target = self
        recordFullScreenItem.action = #selector(recordFullScreen)
        menu.addItem(recordFullScreenItem)

        pauseResumeItem.target = self
        pauseResumeItem.action = #selector(pauseResumeRecording)
        pauseResumeItem.setShortcut(for: .pauseRecording)
        pauseResumeItem.isHidden = true
        menu.addItem(pauseResumeItem)

        menu.addItem(.separator())

        // Launch-at-login FIRST in this group: the rows after it are conditionally
        // hidden permission warnings, so putting it after them would make its
        // position jump depending on which warnings are showing that day.
        launchAtLoginItem.target = self
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        menu.addItem(launchAtLoginItem)

        screenRecordingStatusItem.isEnabled = false
        menu.addItem(screenRecordingStatusItem)

        requestScreenRecordingItem.target = self
        requestScreenRecordingItem.action = #selector(requestScreenRecording)
        menu.addItem(requestScreenRecordingItem)

        micStatusItem.target = self
        micStatusItem.action = #selector(micStatusClicked)
        micStatusItem.isHidden = true
        menu.addItem(micStatusItem)

        tapStatusItem.target = self
        tapStatusItem.action = #selector(tapStatusClicked)
        tapStatusItem.isHidden = true
        menu.addItem(tapStatusItem)

        menu.addItem(.separator())

        settingsItem.target = self
        settingsItem.action = #selector(openSettings)
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Camcord'dan Çık", action: #selector(quit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)

        refreshScreenRecordingState()
        refreshLaunchAtLoginState()
        refreshTapStatus()
    }

    // MARK: - Click routing

    @objc private func statusButtonClicked() {
        let event = NSApp.currentEvent
        // Right-click OR control-click (delivered as leftMouseUp + .control) opens
        // the context menu, per macOS convention.
        let isMenuClick =
            event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isMenuClick {
            showContextMenu()
        } else {
            onPrimaryClick?()
        }
    }

    private func showContextMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach right away so the next left-click goes back to the panel.
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refreshScreenRecordingState()
        refreshMicrophoneState()
        refreshLaunchAtLoginState()
        refreshTapStatus()
        refreshRecordingItems()
    }

    // MARK: - Dynamic state

    private func refreshScreenRecordingState() {
        let granted = CGPreflightScreenCaptureAccess()
        screenRecordingStatusItem.title = granted ? "Ekran Kaydı: İzin verildi" : "Ekran Kaydı: İzin yok"
        requestScreenRecordingItem.isHidden = granted
    }

    /// Mic-denied notice: shown when recordings are configured to include the mic
    /// but the Microphone TCC grant is denied/restricted (recordings then silently
    /// proceed without the mic track -- this row is why they do).
    private func refreshMicrophoneState() {
        let wantsMic = RecordingSettings.load(from: .standard).microphone
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        micStatusItem.isHidden = !(wantsMic && (status == .denied || status == .restricted))
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginItem.state = LoginItem.isEnabled ? .on : .off
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
            tapStatusItem.title = "Erişilebilirlik izni gerekli — Aç"
            tapStatusItem.isHidden = false
        } else if !eventTapEngine.isTapHealthy {
            tapStatusItem.title = "Fare/hareket bağlantısı devre dışı"
            tapStatusItem.isHidden = false
        } else {
            tapStatusItem.isHidden = true
        }
    }

    // MARK: - Recording UI (pushed by RecordingController via AppDelegate wiring)

    /// A brief red pulse on the status glyph: the zero-latency visual companion to
    /// the failure beep (fired AFTER the failure is known, so the hot path pays
    /// nothing). Restores whatever tint the current recording state calls for.
    func flashFailure() {
        guard let button = statusItem.button else { return }
        failureFlashTask?.cancel()
        button.contentTintColor = .systemRed
        failureFlashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.restoreTintForCurrentState()
        }
    }

    private var failureFlashTask: Task<Void, Never>?

    private func restoreTintForCurrentState() {
        guard let button = statusItem.button else { return }
        switch recordingController.uiState {
        case .idle: button.contentTintColor = nil
        case .recording: button.contentTintColor = .systemRed
        case .paused: button.contentTintColor = .systemOrange
        }
    }

    /// Renders the recording state on the status item: a vivid, glowing red glyph +
    /// elapsed time while recording (orange while paused), plain camera when idle.
    /// The elapsed text is drawn as an attributed string in the state color so it is
    /// clearly legible on the menu bar instead of the default (near-invisible) label.
    func setRecordingUI(_ state: RecordingController.UIState, elapsed: String?) {
        guard let button = statusItem.button else { return }
        switch state {
        case .idle:
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Camcord")
            image?.isTemplate = true
            button.image = image
            button.contentTintColor = nil
            button.attributedTitle = NSAttributedString(string: "")
        case .recording:
            button.attributedTitle = NSAttributedString(string: "")
            button.contentTintColor = nil
            button.imagePosition = .imageOnly
            button.image = Self.indicatorImage(elapsed: elapsed ?? "", color: .systemRed, paused: false)
        case .paused:
            button.attributedTitle = NSAttributedString(string: "")
            button.contentTintColor = nil
            button.imagePosition = .imageOnly
            button.image = Self.indicatorImage(elapsed: elapsed ?? "", color: .systemOrange, paused: true)
        }
        refreshRecordingItems()
    }

    /// The recording indicator (dot + elapsed) rendered as a NON-template image in
    /// exact colors. The menu bar's vibrancy mutes template tints / attributed-title
    /// colors toward the bar color (why a plain red title read as near-black); a
    /// non-template image is drawn as-is, so a vivid glowing red survives.
    private static func indicatorImage(elapsed: String, color: NSColor, paused: Bool) -> NSImage {
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.85)
        glow.shadowBlurRadius = 3.5
        glow.shadowOffset = .zero
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let text = NSAttributedString(
            string: elapsed,
            attributes: [.foregroundColor: color, .font: font, .shadow: glow]
        )
        let textSize = text.size()
        let dot: CGFloat = 7
        let gap: CGFloat = 5
        let pad: CGFloat = 5  // room for the glow bleed
        let height = max(textSize.height, dot) + pad * 2
        let width = pad + dot + gap + ceil(textSize.width) + pad

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSGraphicsContext.saveGraphicsState()
        glow.set()
        color.setFill()
        let dotRect = NSRect(x: pad, y: (height - dot) / 2, width: dot, height: dot)
        if paused {
            // Two bars for the pause glyph.
            let barW: CGFloat = 2, barGap: CGFloat = 2
            let barsH = dot
            let y = (height - barsH) / 2
            NSBezierPath(rect: NSRect(x: pad, y: y, width: barW, height: barsH)).fill()
            NSBezierPath(rect: NSRect(x: pad + barW + barGap, y: y, width: barW, height: barsH)).fill()
        } else {
            NSBezierPath(ovalIn: dotRect).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        text.draw(at: NSPoint(x: pad + dot + gap, y: (height - textSize.height) / 2))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func refreshRecordingItems() {
        switch recordingController.uiState {
        case .idle:
            recordToggleItem.title = "Kayda Başla…"
            recordFullScreenItem.isHidden = false
            pauseResumeItem.isHidden = true
        case .recording:
            recordToggleItem.title = "Kaydı Durdur"
            recordFullScreenItem.isHidden = true
            pauseResumeItem.isHidden = false
            pauseResumeItem.title = "Kaydı Duraklat"
        case .paused:
            recordToggleItem.title = "Kaydı Durdur"
            recordFullScreenItem.isHidden = true
            pauseResumeItem.isHidden = false
            pauseResumeItem.title = "Kaydı Sürdür"
        }
    }

    // MARK: - Recording actions

    @objc private func toggleRecording() {
        Task {
            if recordingController.uiState == .idle {
                // Same menu-close wait as captureRegion: the interactive flow opens
                // the selection overlay, which must not fight the closing menu.
                try? await Task.sleep(for: .milliseconds(200))
            }
            await recordingController.toggleRecording()
        }
    }

    @objc private func recordFullScreen() {
        Task {
            await recordingController.recordFullScreen()
        }
    }

    @objc private func pauseResumeRecording() {
        recordingController.pauseResume()
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

    @objc private func captureTextRegion() {
        Task {
            // Opens the selection overlay — same menu-close wait as captureRegion.
            try? await Task.sleep(for: .milliseconds(200))
            await coordinator.captureTextRegionInteractive()
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
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func micStatusClicked() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func tapStatusClicked() {
        guard !AccessibilityPermission.isTrusted() else { return }
        AccessibilityPermission.requestAccess()
    }

    @objc private func openSettings() {
        settingsWindowController.show()
    }
}
