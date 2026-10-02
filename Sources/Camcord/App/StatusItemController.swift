import AVFoundation
import AppKit
import CoreGraphics
import KeyboardShortcuts
import ServiceManagement
import UniformTypeIdentifiers
import os

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let coordinator: CaptureCoordinator
    private let recordingController: RecordingController
    private let eventTapEngine: EventTapEngine
    /// Opens Settings: the main window on its Settings module (K7).
    var onOpenSettings: (() -> Void)?

    private let captureRegionItem = NSMenuItem(title: "Bölgeyi Çek", action: nil, keyEquivalent: "")
    private let captureActiveWindowItem = NSMenuItem(title: "Aktif Pencereyi Çek", action: nil, keyEquivalent: "")
    private let captureFullScreenItem = NSMenuItem(title: "Tüm Ekranı Çek", action: nil, keyEquivalent: "")
    private let captureTextItem = NSMenuItem(title: "Metni Çek (OCR)", action: nil, keyEquivalent: "")
    private let captureScrollingItem = NSMenuItem(title: "Kaydırmalı Çekim…", action: nil, keyEquivalent: "")
    private let captureTextFromFileItem = NSMenuItem(title: "Görüntüden Metni Çıkar…", action: nil, keyEquivalent: "")
    private let recordToggleItem = NSMenuItem(title: "Kayda Başla…", action: nil, keyEquivalent: "")
    private let recordFullScreenItem = NSMenuItem(title: "Tüm Ekranı Kaydet", action: nil, keyEquivalent: "")
    private let cameraPreviewItem = NSMenuItem(title: "Kamera Önizlemesi", action: nil, keyEquivalent: "")
    private let showPanelItem = NSMenuItem(title: "Kayıt Panelini Aç", action: nil, keyEquivalent: "")
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
    var onShowPanel: (() -> Void)?
    var onOpenMainWindow: (() -> Void)?
    var onOpenDesignLab: (() -> Void)?

    /// Anchor for the popover panel.
    var anchorButton: NSStatusBarButton? { statusItem.button }

    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "app")

    init(
        coordinator: CaptureCoordinator,
        recordingController: RecordingController,
        eventTapEngine: EventTapEngine,
    ) {
        self.coordinator = coordinator
        self.recordingController = recordingController
        self.eventTapEngine = eventTapEngine
        // variableLength from the start: the item sizes to its content (icon-only
        // when idle, icon+elapsed while recording). Switching lengths at runtime
        // would shift the anchor out from under an open popover.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = CamcordBrandAssets.templateImage
            button.setAccessibilityLabel("Camcord")
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

        captureScrollingItem.target = self
        captureScrollingItem.action = #selector(captureScrolling)
        captureScrollingItem.setShortcut(for: .captureScrolling)
        menu.addItem(captureScrollingItem)

        captureTextItem.target = self
        captureTextItem.action = #selector(captureTextRegion)
        captureTextItem.setShortcut(for: .captureTextRegion)
        menu.addItem(captureTextItem)

        captureTextFromFileItem.target = self
        captureTextFromFileItem.action = #selector(captureTextFromFile)
        menu.addItem(captureTextFromFileItem)

        menu.addItem(.separator())

        // Recording is started from the panel/menu only (no keyboard default); the
        // owner can bind pause/resume from Settings.
        recordToggleItem.target = self
        recordToggleItem.action = #selector(toggleRecording)
        recordToggleItem.setShortcut(for: .toggleRecording)
        menu.addItem(recordToggleItem)

        recordFullScreenItem.target = self
        recordFullScreenItem.action = #selector(recordFullScreen)
        if NSScreen.screens.count > 1 {
            recordFullScreenItem.toolTip = "İmlecin bulunduğu ekran kaydedilir"
        }
        menu.addItem(recordFullScreenItem)

        pauseResumeItem.target = self
        pauseResumeItem.action = #selector(pauseResumeRecording)
        pauseResumeItem.setShortcut(for: .pauseRecording)
        pauseResumeItem.isHidden = true
        menu.addItem(pauseResumeItem)
        showPanelItem.target = self
        showPanelItem.action = #selector(showRecordingPanel)
        menu.addItem(showPanelItem)
        cameraPreviewItem.target = self
        cameraPreviewItem.action = #selector(toggleCameraPreview)
        menu.addItem(cameraPreviewItem)

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

        let openItem = NSMenuItem(title: String(localized: "Open Camcord", comment: "Opens the main window"),
                                  action: #selector(openMainWindow), keyEquivalent: "0")
        openItem.keyEquivalentModifierMask = .command
        openItem.target = self
        menu.addItem(openItem)

        settingsItem.target = self
        settingsItem.action = #selector(openSettings)
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)
        // Hidden: replaces Settings while ⌥ is held (RUN UI-1 C2's native glass spike).
        let designLabItem = NSMenuItem(title: "Design Lab…", action: #selector(openDesignLab), keyEquivalent: ",")
        designLabItem.keyEquivalentModifierMask = [.command, .option]
        designLabItem.isAlternate = true
        designLabItem.target = self
        menu.addItem(designLabItem)

        let quitItem = NSMenuItem(title: String(localized: "Quit Camcord"), action: #selector(quit), keyEquivalent: "q")
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
        guard let button = statusItem.button else { return }
        // Pop the menu cleanly without temporarily replacing the status item's main menu
        // and relying on async dispatch timing.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY + 4), in: button)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        cameraPreviewItem.state = CameraOverlayController.shared.previewVisible ? .on : .off
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
        if recordingController.uiState == .idle {
            button.contentTintColor = Theme.Palette.record.ns
        }
        failureFlashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.restoreTintForCurrentState()
        }
    }

    /// A brief green pulse on the status glyph confirming a capture landed — the visual
    /// companion to the capture sound, for muted/noisy environments. Fired after the
    /// capture already succeeded, so it costs nothing on the hot path.
    func flashSuccess() {
        guard let button = statusItem.button else { return }
        failureFlashTask?.cancel()
        if recordingController.uiState == .idle {
            button.contentTintColor = Theme.Palette.ok.ns
        }
        failureFlashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            self?.restoreTintForCurrentState()
        }
    }

    private var failureFlashTask: Task<Void, Never>?

    private func restoreTintForCurrentState() {
        guard let button = statusItem.button else { return }
        switch recordingController.uiState {
        case .idle: button.contentTintColor = nil
        case .recording: button.contentTintColor = nil
        case .paused: button.contentTintColor = nil
        }
    }

    private var lastUIState: RecordingController.UIState?
    private var lastElapsed: String?

    func setPreparing(_ preparing: Bool) {
        if preparing, lastUIState == nil || lastUIState == .idle {
            statusItem.button?.image = Self.indicatorImage(elapsed: "…", color: Theme.Palette.ink2.ns, paused: false)
            statusItem.button?.toolTip = "Kayıt hazırlanıyor"
        } else if !preparing {
            let state = lastUIState ?? .idle
            lastUIState = nil
            setRecordingUI(state, elapsed: lastElapsed)
            statusItem.button?.toolTip = "Camcord"
        }
    }

    /// Renders the recording state on the status item: a vivid, glowing red glyph +
    /// elapsed time while recording (hollow while paused), the template lens when idle.
    /// The elapsed text is drawn as an attributed string in the state color so it is
    /// clearly legible on the menu bar instead of the default (near-invisible) label.
    func setRecordingUI(_ state: RecordingController.UIState, elapsed: String?) {
        guard let button = statusItem.button else { return }

        // Optimize: skip rendering and menu updates if nothing changed.
        guard state != lastUIState || elapsed != lastElapsed else { return }

        let stateChanged = (state != lastUIState)
        lastUIState = state
        lastElapsed = elapsed
        switch state {
        case .idle:
            button.image = CamcordBrandAssets.templateImage
            button.contentTintColor = nil
            button.attributedTitle = NSAttributedString(string: "")
        case .recording:
            button.title = ""
            button.contentTintColor = nil
            button.imagePosition = .imageOnly
            button.image = Self.indicatorImage(elapsed: elapsed ?? "—", color: Theme.Palette.record.ns, paused: false)
        case .paused:
            button.title = ""
            button.contentTintColor = nil
            button.imagePosition = .imageOnly
            button.image = Self.indicatorImage(elapsed: elapsed ?? "—", color: Theme.Palette.ink.ns, paused: true)
        }

        if stateChanged {
            refreshRecordingItems()
        }
    }

    /// A highly visible "recording pill": solid color background, white dot, white text.
    /// Rendered as a non-template image so it ignores macOS menu bar tinting and stays vivid.
    static func indicatorImage(elapsed: String, color: NSColor, paused: Bool) -> NSImage {
        let font = Theme.Menu.pillFont
        let textColor: NSColor = paused ? Theme.Palette.ink.ns : Theme.Palette.onRecord.ns
        let text = NSAttributedString(
            string: elapsed,
            attributes: [.foregroundColor: textColor, .font: font]
        )
        let textSize = text.size()

        let dot = Theme.Menu.pillDot
        let gap = Theme.Menu.pillGap
        let leading = Theme.Menu.pillLeading
        let trailing = Theme.Menu.pillTrailing
        let height = Theme.Menu.pillHeight
        let pillHeight = height
        let width = leading + dot + gap + ceil(textSize.width) + trailing

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSGraphicsContext.saveGraphicsState()

        // Draw the pill background
        (paused ? NSColor.clear : color).setFill()
        let pillRect = NSRect(x: 0, y: (height - pillHeight) / 2, width: width, height: pillHeight)
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: pillHeight / 2, yRadius: pillHeight / 2)
        pillPath.fill()
        if paused {
            textColor.withAlphaComponent(0.18).setStroke()
            let rim = NSBezierPath(roundedRect: pillRect.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: pillHeight / 2, yRadius: pillHeight / 2)
            rim.lineWidth = 0.5
            rim.stroke()
        }

        // Draw the filled recording dot or hollow paused ring
        textColor.set()
        let dotRect = NSRect(x: leading, y: (height - dot) / 2, width: dot, height: dot)
        if paused {
            let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            ring.stroke()
        } else {
            NSBezierPath(ovalIn: dotRect).fill()
        }

        NSGraphicsContext.restoreGraphicsState()

        // Draw the text
        text.draw(at: NSPoint(x: leading + dot + gap, y: (height - textSize.height) / 2))

        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = String(localized: paused ? "Paused" : "Recording") + " " + elapsed
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

    @objc private func toggleCameraPreview() {
        CameraOverlayController.shared.togglePreview()
        cameraPreviewItem.state = CameraOverlayController.shared.previewVisible ? .on : .off
    }

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

    @objc private func showRecordingPanel() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            onShowPanel?()
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

    @objc private func captureScrolling() {
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await coordinator.captureScrollingInteractive()
        }
    }

    /// OCR an image the user already has: pick a file, extract its text to the clipboard.
    @objc private func captureTextFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Metni Çıkar"
        panel.message = "Metnini çıkarmak istediğin görüntüyü seç"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.coordinator.captureTextFromImageFile(url)
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

    @objc private func openDesignLab() {
        onOpenDesignLab?()
    }

    @objc private func openMainWindow() {
        onOpenMainWindow?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }
}
