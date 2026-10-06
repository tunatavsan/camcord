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
    /// Opens Settings: the main window on its Settings module.
    var onOpenSettings: (() -> Void)?

    private let captureRegionItem = NSMenuItem(title: String(localized: "Capture Region", comment: "Status menu item"), action: nil, keyEquivalent: "")
    private let captureActiveWindowItem = NSMenuItem(title: String(localized: "Capture Active Window", comment: "Status menu item"), action: nil, keyEquivalent: "")
    private let captureFullScreenItem = NSMenuItem(title: String(localized: "Capture Full Screen", comment: "Status menu item"), action: nil, keyEquivalent: "")
    private let captureTextItem = NSMenuItem(title: String(localized: "Capture Text (OCR)", comment: "Status menu item"), action: nil, keyEquivalent: "")
    private let captureScrollingItem = NSMenuItem(title: String(localized: "Scroll Capture…", comment: "Status menu item"), action: nil, keyEquivalent: "")
    private let captureTextFromFileItem = NSMenuItem(title: String(localized: "Extract Text from Image…", comment: "Status menu item"), action: nil, keyEquivalent: "")
    private let recordToggleItem = NSMenuItem(title: String(localized: "Start Recording…", comment: "Status menu item"), action: nil, keyEquivalent: "")
    private let recordFullScreenItem = NSMenuItem(title: String(localized: "Record Full Screen", comment: "Status menu item"), action: nil, keyEquivalent: "")
    private let cameraPreviewItem = NSMenuItem(title: String(localized: "Camera Preview", comment: "Status menu item"), action: nil, keyEquivalent: "")
    private let showPanelItem = NSMenuItem(title: String(localized: "Open Recording Panel", comment: "Status menu item"), action: nil, keyEquivalent: "")
    private let pauseResumeItem = NSMenuItem(title: String(localized: "Pause Recording", comment: "Status menu item"), action: nil, keyEquivalent: "")
    private let screenRecordingStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let requestScreenRecordingItem = NSMenuItem(title: String(localized: "Request Screen Recording Permission…", comment: "Status menu item"), action: nil, keyEquivalent: "")
    private let micStatusItem = NSMenuItem(title: String(localized: "No microphone permission — Open", comment: "Status menu item"), action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: String(localized: "Open at Login", comment: "Status menu item"), action: nil, keyEquivalent: "")
    private let tapStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: String(localized: "Settings…", comment: "Menu item: opens Settings"), action: nil, keyEquivalent: ",")

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
        // user can bind pause/resume from Settings.
        recordToggleItem.target = self
        recordToggleItem.action = #selector(toggleRecording)
        recordToggleItem.setShortcut(for: .toggleRecording)
        menu.addItem(recordToggleItem)

        recordFullScreenItem.target = self
        recordFullScreenItem.action = #selector(recordFullScreen)
        if NSScreen.screens.count > 1 {
            recordFullScreenItem.toolTip = String(localized: "Records the screen the pointer is on", comment: "Tooltip on Record Full Screen")
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
        // Hidden: replaces Settings while ⌥ is held (the Design Lab's native glass specimens).
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
        screenRecordingStatusItem.title = granted
            ? String(localized: "Screen Recording: Allowed", comment: "Status menu: permission state")
            : String(localized: "Screen Recording: Not Allowed", comment: "Status menu: permission state")
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
            tapStatusItem.title = String(localized: "Accessibility permission needed — Open", comment: "Status menu: mouse shortcuts need a permission")
            tapStatusItem.isHidden = false
        } else if !eventTapEngine.isTapHealthy {
            tapStatusItem.title = String(localized: "Mouse/gesture shortcuts disabled", comment: "Status menu: the mouse shortcut hook is down")
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
            showRecordLight(.preparing)
            statusItem.button?.toolTip = String(localized: "Preparing recording…")
        } else if !preparing {
            let state = lastUIState ?? .idle
            lastUIState = nil
            setRecordingUI(state, elapsed: lastElapsed)
            statusItem.button?.toolTip = "Camcord"
        }
    }

    /// Renders the recording state on the status item. The icon and the item's width never
    /// change, so nothing in the menu bar shifts when a recording starts: a small record light
    /// sits on the lens and pulses while recording, hollow and still while paused. The time
    /// lives on the hub and in the panel.
    func setRecordingUI(_ state: RecordingController.UIState, elapsed: String?) {
        guard let button = statusItem.button else { return }

        // Optimize: skip rendering and menu updates if nothing changed.
        guard state != lastUIState || elapsed != lastElapsed else { return }

        let stateChanged = (state != lastUIState)
        lastUIState = state
        lastElapsed = elapsed
        button.image = CamcordBrandAssets.templateImage
        button.contentTintColor = nil
        switch state {
        case .idle:
            showRecordLight(nil)
            button.setAccessibilityValue(nil)
        case .recording:
            if stateChanged { showRecordLight(.recording) }
            button.setAccessibilityValue(String(localized: "Recording") + " " + (elapsed ?? ""))
        case .paused:
            if stateChanged { showRecordLight(.paused) }
            button.setAccessibilityValue(String(localized: "Paused") + " " + (elapsed ?? ""))
        }

        if stateChanged {
            refreshRecordingItems()
        }
    }

    private enum RecordLight { case preparing, recording, paused }
    private var recordLight: (dot: CALayer, ring: CALayer)?

    /// The light on the lens, drawn by the render server: it pops in, and the ring keeps
    /// leaving the dot while a recording runs.
    private func showRecordLight(_ light: RecordLight?) {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        guard let light else {
            if let recordLight {
                CATransaction.begin(); CATransaction.setAnimationDuration(0.15)
                recordLight.dot.opacity = 0; recordLight.ring.opacity = 0
                CATransaction.commit()
                recordLight.ring.removeAllAnimations()
            }
            return
        }
        let layers = recordLight ?? {
            let dot = CALayer(), ring = CALayer()
            for layer in [ring, dot] { layer.bounds = CGRect(x: 0, y: 0, width: 7, height: 7); layer.cornerRadius = 3.5; layer.opacity = 0 }
            button.layer?.addSublayer(ring)
            button.layer?.addSublayer(dot)
            recordLight = (dot, ring)
            return (dot, ring)
        }()
        // On the lens's upper-right shoulder, inside the item so its width never changes.
        let bounds = button.bounds
        let top = button.isFlipped ? bounds.minY + 5 : bounds.maxY - 5
        let center = CGPoint(x: bounds.midX + 6.5, y: top)
        let red = Theme.Palette.record.ns.cgColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layers.dot.position = center; layers.ring.position = center
        switch light {
        case .preparing:
            layers.dot.backgroundColor = NSColor.systemGray.cgColor; layers.dot.borderWidth = 0
        case .recording:
            layers.dot.backgroundColor = red; layers.dot.borderWidth = 0
        case .paused:
            layers.dot.backgroundColor = NSColor.clear.cgColor; layers.dot.borderColor = red; layers.dot.borderWidth = 1.5
        }
        layers.ring.backgroundColor = red
        layers.ring.removeAllAnimations()
        layers.ring.opacity = 0
        let fromOpacity = layers.dot.presentation()?.opacity ?? layers.dot.opacity
        layers.dot.opacity = 1
        CATransaction.commit()
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if fromOpacity < 0.5, !reduce {
            let pop = CASpringAnimation.card(keyPath: "transform.scale", from: 0.2, to: 1, response: 0.34, dampingRatio: 0.6)
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.12
            layers.dot.add(pop, forKey: "light-pop"); layers.dot.add(fade, forKey: "light-fade")
        }
        guard light == .recording, !reduce else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 1; grow.toValue = 2.3
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.5; fade.toValue = 0
        let pulse = CAAnimationGroup()
        pulse.animations = [grow, fade]
        pulse.duration = 1.4
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulse.repeatCount = .infinity
        layers.ring.add(pulse, forKey: "light-pulse")
    }

    private func refreshRecordingItems() {
        switch recordingController.uiState {
        case .idle:
            recordToggleItem.title = String(localized: "Start Recording…", comment: "Status menu item")
            recordFullScreenItem.isHidden = false
            pauseResumeItem.isHidden = true
        case .recording:
            recordToggleItem.title = String(localized: "Stop Recording", comment: "Status menu item")
            recordFullScreenItem.isHidden = true
            pauseResumeItem.isHidden = false
            pauseResumeItem.title = String(localized: "Pause Recording", comment: "Status menu item")
        case .paused:
            recordToggleItem.title = String(localized: "Stop Recording", comment: "Status menu item")
            recordFullScreenItem.isHidden = true
            pauseResumeItem.isHidden = false
            pauseResumeItem.title = String(localized: "Resume Recording", comment: "Status menu item")
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
            // overlaps them. The global hotkey path doesn't need this (no menu involved).
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
        panel.prompt = String(localized: "Extract Text", comment: "Open panel button: OCR the chosen image")
        panel.message = String(localized: "Choose an image to extract text from", comment: "Open panel message: OCR an image file")
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
