import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let didAttemptLoginItemKey = "didAttemptLoginItemRegistration"
    private var captureCoordinator: CaptureCoordinator?
    private var recordingController: RecordingController?
    private var hotkeyCenter: HotkeyCenter?
    private var eventTapEngine: EventTapEngine?
    private var settingsWindowController: SettingsWindowController?
    private var statusItemController: StatusItemController?
    private var panelController: PanelController?
    private var recordingStateModel: RecordingStateModel?
    private var hudToast: HUDToast?
    private var screenshotPreviewCard: ScreenshotPreviewCard?
    private var servicesProvider: ServicesProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Warm the feedback-sound cache so the first cue has zero setup latency.
        FeedbackSound.preloadAll()

        let coordinator = CaptureCoordinator()
        captureCoordinator = coordinator
        coordinator.prewarm()

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
        installMainMenu()

        let statusItemController = StatusItemController(
            coordinator: coordinator,
            recordingController: recordingController,
            eventTapEngine: eventTapEngine,
            settingsWindowController: settingsWindowController
        )
        self.statusItemController = statusItemController

        let recordingStateModel = RecordingStateModel()
        self.recordingStateModel = recordingStateModel

        recordingController.onUIChange = { [weak self, weak statusItemController, weak recordingStateModel] state, elapsed in
            statusItemController?.setRecordingUI(state, elapsed: elapsed)
            if recordingStateModel?.state == .idle, state == .recording {
                self?.panelController?.releaseRecordingHold()
            }
            recordingStateModel?.state = state
            recordingStateModel?.elapsed = elapsed
            // A new/live recording clears any lingering "done" card.
            if state != .idle {
                recordingStateModel?.finishedURL = nil
                recordingStateModel?.isFinishing = false
            }
        }
        recordingController.onStartingChange = { [weak self, weak recordingStateModel, weak statusItemController] starting in
            recordingStateModel?.isStarting = starting
            if starting {
                recordingStateModel?.finishedURL = nil
                self?.panelController?.keepOpenForRecording()
            } else if recordingStateModel?.state == .idle, recordingStateModel?.isArmed != true {
                self?.panelController?.releaseRecordingHold()
            }
            statusItemController?.setPreparing(starting)
        }
        recordingController.onArmedChange = { [weak self, weak recordingStateModel] armed in
            recordingStateModel?.isArmed = armed
            if armed {
                recordingStateModel?.finishedURL = nil
                self?.panelController?.keepOpenForRecording()
            } else if recordingStateModel?.isStarting != true, recordingStateModel?.state == .idle {
                self?.panelController?.releaseRecordingHold()
            }
        }
        recordingController.onHealthChange = { [weak recordingStateModel] health in
            recordingStateModel?.health = health
        }
        recordingController.onFinishing = { [weak recordingStateModel] finishing in
            recordingStateModel?.isFinishing = finishing
        }
        recordingController.onRecordingFinished = { [weak self] url in
            self?.recordingStateModel?.isFinishing = false
            self?.recordingStateModel?.finishedURL = url
            // Surface the "done" card even when the recording was stopped via a keyboard/
            // mouse shortcut (panel closed) — pop the panel open (without the grid-reset)
            // so the reveal/open actions are right there.
            if let button = self?.statusItemController?.anchorButton {
                self?.panelController?.present(relativeTo: button)
            }
        }

        // Every failure beep gets a visual companion on the status glyph.
        let flashFailure: () -> Void = { [weak statusItemController] in
            statusItemController?.flashFailure()
        }
        coordinator.onFailure = flashFailure
        recordingController.onFailure = flashFailure
        // ...and every successful capture gets a brief green confirmation flash.
        coordinator.onSuccess = { [weak statusItemController] in
            statusItemController?.flashSuccess()
        }

        // A transient HUD toast confirming what landed on the clipboard (opt-out for
        // routine copies; important auto-stop notices bypass the setting).
        let hudToast = HUDToast()
        self.hudToast = hudToast
        let showToast: (ToastRequest) -> Void = { [weak hudToast] request in
            hudToast?.show(
                text: request.text,
                thumbnail: request.thumbnail,
                systemSymbol: request.systemSymbol,
                tint: request.tint,
                respectsSetting: !request.important
            )
        }
        coordinator.onToast = showToast
        recordingController.onToast = showToast
        hotkeyCenter.onToast = showToast

        // Screenshots land as a framed preview at the bottom-left (their own "copied"
        // confirmation), instead of the center toast — clickable to edit, draggable to lift.
        let screenshotPreviewCard = ScreenshotPreviewCard()
        self.screenshotPreviewCard = screenshotPreviewCard
        coordinator.onScreenshotPreview = { [weak screenshotPreviewCard] image, url in
            screenshotPreviewCard?.show(image: image, fileURL: url)
        }

        coordinator.onScreenshotSaved = { [weak screenshotPreviewCard] image, url in
            screenshotPreviewCard?.saved(image: image, to: url)
        }

        // macOS Services: "Camcord ile Metni Çıkar" on any image selection.
        let servicesProvider = ServicesProvider(coordinator: coordinator)
        self.servicesProvider = servicesProvider
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()

        let panelActions = makePanelActions(coordinator: coordinator, recordingController: recordingController)
        let panelController = PanelController(model: recordingStateModel, actions: panelActions)
        self.panelController = panelController

        statusItemController.onShowPanel = { [weak panelController, weak statusItemController] in
            guard let button = statusItemController?.anchorButton else { return }
            panelController?.present(relativeTo: button)
        }
        statusItemController.onPrimaryClick = { [weak panelController, weak statusItemController] in
            // The status item always opens the same control surface. Recording exposes
            // its mixer and explicit pause/stop controls without an accidental stop.
            guard let button = statusItemController?.anchorButton else { return }
            panelController?.toggle(relativeTo: button)
        }

        registerLoginItemOnFirstRun()
    }

    /// Finder/Spotlight opens the actual capture controls, including when macOS has
    /// crowded the status item out of the menu bar. Settings remains a separate action.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.presentDetached()
        return true
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Camcord")
        let controls = applicationMenu.addItem(withTitle: "Kontrol Paneli", action: #selector(showControlPanel(_:)), keyEquivalent: "")
        controls.target = self
        let settings = applicationMenu.addItem(withTitle: "Ayarlar…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Camcord’dan Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        menu.addItem(AppMenus.editingMenuItem())
        NSApp.mainMenu = menu
    }

    @objc private func showSettings(_ sender: Any?) {
        settingsWindowController?.show()
    }

    @objc private func showControlPanel(_ sender: Any?) {
        panelController?.presentDetached()
    }

    /// Panel actions: overlay-opening flows close the panel first and give the
    /// popover a beat to dismiss (same choreography as the context menu's 200ms).
    private func makePanelActions(
        coordinator: CaptureCoordinator,
        recordingController: RecordingController
    ) -> PanelActions {
        var actions = PanelActions()

        let afterClosingPanel: (@escaping @MainActor () async -> Void) -> Void = { [weak self] work in
            self?.panelController?.close()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                await work()
            }
        }

        actions.captureRegion = {
            afterClosingPanel { await coordinator.captureRegionInteractive() }
        }
        actions.captureWindow = {
            afterClosingPanel { await coordinator.captureActiveWindow() }
        }
        actions.captureScreen = {
            afterClosingPanel { await coordinator.captureFullScreen() }
        }
        actions.captureScroll = {
            afterClosingPanel { await coordinator.captureScrollingInteractive() }
        }
        actions.toggleRecording = { [weak self, weak recordingController] in
            self?.panelController?.keepOpenForRecording()
            Task { await recordingController?.toggleRecording() }
        }
        // The picker is a window of its own and would otherwise open on top of the still-
        // open panel, hiding half the grid. Close first, like every overlay-opening
        // capture action; the arming that follows a pick has its own on-screen Başlat.
        actions.recordWindow = { [weak recordingController] in
            afterClosingPanel { await recordingController?.recordWindow() }
        }
        actions.recordFullScreen = { [weak self, weak recordingController] in
            self?.panelController?.keepOpenForRecording()
            Task { await recordingController?.recordFullScreen() }
        }
        actions.cancelArmed = { [weak recordingController] in recordingController?.cancelArmed() }
        actions.setStageSink = { [weak recordingController] sink in recordingController?.setStageSink(sink) }
        actions.recordingFrameSize = { [weak recordingController] in recordingController?.recordingFrameSize ?? .zero }
        actions.pauseResume = { [weak recordingController] in
            recordingController?.pauseResume()
        }
        actions.revealRecording = { [weak self] url in
            self?.performLibraryAction(url, open: false)
        }
        actions.revealScreenshot = { [weak self] url in
            self?.performLibraryAction(url, open: false)
        }
        actions.openRecording = { [weak self] url in
            self?.performLibraryAction(url, open: true)
        }
        actions.reportError = { [weak self] message in
            self?.hudToast?.show(text: message, systemSymbol: "exclamationmark.triangle", tint: .systemOrange, respectsSetting: false)
        }
        actions.openSettings = { [weak self] in
            self?.panelController?.close()
            self?.settingsWindowController?.show()
        }
        return actions
    }

    /// A deleted/moved capture should leave a useful error rather than dismissing
    /// the recovery card first. File-system access and application launch are async.
    private func performLibraryAction(_ url: URL, open: Bool) {
        Task { @MainActor [weak self] in
            let reachable = await Task.detached(priority: .userInitiated) {
                (try? url.checkResourceIsReachable()) == true
            }.value
            guard let self else { return }
            guard reachable else {
                self.hudToast?.show(
                    text: "Dosya bulunamadı · taşınmış veya silinmiş olabilir",
                    systemSymbol: "exclamationmark.triangle", tint: .systemOrange, respectsSetting: false
                )
                return
            }
            // Empty-library destinations are directory URLs: open their contents,
            // matching the panel's “Klasörü aç” action. Saved files are selected.
            if open || url.hasDirectoryPath {
                do {
                    _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
                } catch {
                    self.hudToast?.show(
                        text: "Dosya veya klasör açılamadı · Finder’dan tekrar deneyebilirsin",
                        systemSymbol: "exclamationmark.triangle", tint: .systemOrange, respectsSetting: false
                    )
                    return
                }
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            self.panelController?.close()
        }
    }

    /// The whole point of the app is being resident from login -- register the login
    /// item automatically on first run (once; the menu toggle stays in control after).
    private func registerLoginItemOnFirstRun() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didAttemptLoginItemKey) else { return }
        defaults.set(true, forKey: Self.didAttemptLoginItemKey)
        guard SMAppService.mainApp.status == .notRegistered else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            // .requiresApproval and transient failures both surface in the menu's
            // Launch at Login state; nothing to do here.
        }
    }

    private var isTerminating = false
    private var didReplyToTermination = false

    /// Don't tear the process down mid-recording: stop (and finalize the file) first,
    /// then terminate. Screenshots are one-shot and need no such guard.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Re-entrancy: a second Cmd-Q while the first is finalizing must not
        // terminateNow and kill the process before the moov atom is written.
        if isTerminating {
            return .terminateLater
        }
        // `.idle` alone is not "nothing in flight": a recording may be mid-start
        // (isStarting) or its file still finalizing after stop (isFinalizing) — `isBusy`
        // covers all three so quitting never kills a half-open or half-written file.
        guard recordingController?.isBusy == true || ClipboardWriter.isSaving else {
            return .terminateNow
        }
        isTerminating = true
        Task { @MainActor in
            await recordingController?.stopForTermination()
            await ClipboardWriter.waitForPendingSaves()
            self.replyToTerminationOnce(sender)
        }
        // Failsafe: if the finalize wedges (hung replayd/disk), still answer Cmd-Q
        // eventually — a personal menu-bar app must never need a Force Quit.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            self.replyToTerminationOnce(sender)
        }
        return .terminateLater
    }

    private func replyToTerminationOnce(_ sender: NSApplication) {
        guard !didReplyToTermination else { return }
        didReplyToTermination = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}
