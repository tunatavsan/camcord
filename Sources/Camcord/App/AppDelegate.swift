import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let didAttemptLoginItemKey = "didAttemptLoginItemRegistration"
    private var appServices: AppServices?
    private var captureCoordinator: CaptureCoordinator?
    private var recordingController: RecordingController?
    private var hotkeyCenter: HotkeyCenter?
    private var eventTapEngine: EventTapEngine?
    private var statusItemController: StatusItemController?
    private var panelController: PanelController?
    private var recordingStateModel: RecordingStateModel?
    private var hudToast: HUDToast?
    private var screenshotPreviewCard: ScreenshotPreviewCard?
    private var screenshotDeliveryFanout: ScreenshotDeliveryFanout?
    private var servicesProvider: ServicesProvider?
    private var dockController: DockController?
    private var mainWindowController: MainWindowController?
    private let designLab = DesignLabWindowController()
    private var liveCheck: LiveCheck?
    private var firstRun: FirstRunWindowController?

    func applicationDidBecomeActive(_ notification: Notification) {
        ActivationPerformanceDiagnostics.shared.didBecomeActive()
    }

    func applicationDidResignActive(_ notification: Notification) {
        ActivationPerformanceDiagnostics.shared.didResignActive()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        MainRunLoopHangMonitor.shared.start()
        #endif
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


        // The main window and the Dock icon. `.always` gets its icon now; the others wait
        // for the window.
        let dockController = DockController()
        self.dockController = dockController
        dockController.apply()
        installMainMenu()

        let statusItemController = StatusItemController(
            coordinator: coordinator,
            recordingController: recordingController,
            eventTapEngine: eventTapEngine
        )
        self.statusItemController = statusItemController

        let recordingStateModel = RecordingStateModel()
        self.recordingStateModel = recordingStateModel
        let services = AppServices(
            coordinator: coordinator,
            recordingController: recordingController,
            eventTapEngine: eventTapEngine,
            recordingState: recordingStateModel
        )
        self.appServices = services
        let mainWindowController = MainWindowController(dock: dockController, services: services)
        services.mainWindow = mainWindowController
        self.mainWindowController = mainWindowController

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
        recordingController.onRecordingFinished = { [weak self, weak services] url in
            services?.library.scheduleRefresh()
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

        // Screenshots land as a framed preview at the bottom-right (their own "copied"
        // confirmation), instead of the center toast — clickable to preview, draggable to lift.
        let screenshotPreviewCard = ScreenshotPreviewCard(keepsInLibrary: { [weak services] in
            services.map { LibrarySettings.load(from: $0.defaults).keepCopied } ?? true
        })
        self.screenshotPreviewCard = screenshotPreviewCard
        screenshotPreviewCard.onKeep = { [weak services] capture in services?.library.keep(capture) }
        screenshotPreviewCard.claimClipboardPublication = { [weak coordinator] in
            coordinator?.claimClipboardPublication() ?? { false }
        }
        screenshotPreviewCard.onEdit = { [weak self, weak services] capture in
            guard let self, let services else { return }
            _ = services.editor.open(capture)
            self.panelController?.close()
            // The shared main host presents the actual pending-unsaved confirmation.
            self.mainWindowController?.show(module: .edit)
        }
        let deliveryFanout = ScreenshotDeliveryFanout(
            ingest: { [weak services] event in services?.library.ingest(event) },
            ready: { [weak screenshotPreviewCard] capture in screenshotPreviewCard?.show(capture: capture) },
            saved: { [weak screenshotPreviewCard] id, url in screenshotPreviewCard?.saved(id: id, to: url) },
            saveFailed: { [weak screenshotPreviewCard] capture in
                screenshotPreviewCard?.saveFailed(id: capture.id)
                // CaptureCoordinator already emits the actual important failure toast.
            }
        )
        self.screenshotDeliveryFanout = deliveryFanout
        coordinator.onScreenshotDelivery = { [weak deliveryFanout] event in deliveryFanout?.receive(event) }

        // macOS Services: "Camcord ile Metni Çıkar" on any image selection.
        let servicesProvider = ServicesProvider(coordinator: coordinator)
        self.servicesProvider = servicesProvider
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()

        let panelActions = makePanelActions(coordinator: coordinator, recordingController: recordingController)
        let panelController = PanelController(model: recordingStateModel, actions: panelActions,
                                              library: services.library, defaults: services.defaults)
        self.panelController = panelController

        statusItemController.onOpenMainWindow = { [weak self] in self?.showMainWindow() }
        statusItemController.onOpenSettings = { [weak self] in self?.showSettingsModule() }
        statusItemController.onOpenDesignLab = { [weak self] in self?.designLab.show() }
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
        liveCheck = LiveCheck(defaults: .standard) { [weak self] command in self?.performLiveCheck(command) }

        // The first run: Screen Recording is the one gate; the primary action is a region capture.
        let firstRun = FirstRunWindowController { [weak coordinator] in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))   // the window leaves the screen first
                await coordinator?.captureRegionInteractive()
            }
        }
        self.firstRun = firstRun
        firstRun.showIfNeeded(activate: NSApp.isActive)
    }

    /// Focus-safe surfaces for the run's screenshots (LiveCheck); never activates the app.
    private func performLiveCheck(_ command: LiveCheck.Command) {
        switch command {
        case .window(let module):
            panelController?.close()
            mainWindowController?.show(module: module, activate: false)
        case .appearance(let name):
            NSApp.appearance = name.flatMap(NSAppearance.init(named:))
        case .contrast(let high):
            ThemeColor.highContrastOverride = high
            // Re-resolve every dynamic colour: an appearance round trip redraws all windows.
            let appearance = NSApp.appearance
            NSApp.appearance = NSAppearance(named: .aqua)
            NSApp.appearance = appearance
        case .lab(let page):
            designLab.show(page: page, activate: false)
        case .firstRun(let simulatedGrant):
            firstRun?.permission.simulated = simulatedGrant
            firstRun?.show(activate: false)
        case .close:
            mainWindowController?.close()
            designLab.close()
            firstRun?.permission.simulated = nil
            firstRun?.close()
        }
    }

    /// The Dock icon, Finder and Spotlight open the main window — Camcord's home, and the way
    /// back when macOS has crowded the status item out of the menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// Finder's explicit Open action hosts the pending-open decision in the same main window.
    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let url = urls.first, let appServices else { return }
        showMainWindow(activate: sender.isActive)
        Task { @MainActor in
            if case .failed(let message) = await appServices.editor.requestOpen(url: url) {
                appServices.library.issue = message
            }
        }
    }

    private func showMainWindow(activate: Bool = true) {
        panelController?.close()
        mainWindowController?.show(activate: activate)
    }

    @objc private func openMainWindow(_ sender: Any?) {
        showMainWindow()
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Camcord")
        let open = applicationMenu.addItem(withTitle: String(localized: "Open Camcord", comment: "Opens the main window"),
                                           action: #selector(openMainWindow(_:)), keyEquivalent: "0")
        open.target = self
        let controls = applicationMenu.addItem(withTitle: "Kontrol Paneli", action: #selector(showControlPanel(_:)), keyEquivalent: "")
        controls.target = self
        let settings = applicationMenu.addItem(withTitle: "Ayarlar…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Camcord’dan Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        menu.addItem(AppMenus.editingMenuItem())
        menu.addItem(AppMenus.viewMenuItem(target: self, action: #selector(showModule(_:))))
        let windowMenu = AppMenus.windowMenuItem()
        menu.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        NSApp.mainMenu = menu
    }

    /// View › Library / Studio / Edit / Settings (⌘1…⌘4).
    @objc private func showModule(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = ModuleID(rawValue: raw) else { return }
        panelController?.close()
        mainWindowController?.show(module: id)
    }

    /// ⌘, opens the main window on Settings (K7).
    @objc private func showSettings(_ sender: Any?) {
        showSettingsModule()
    }

    private func showSettingsModule() {
        panelController?.close()
        mainWindowController?.show(module: .settings)
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

        actions.captureText = {
            afterClosingPanel { await coordinator.captureTextRegionInteractive() }
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
        actions.armedStageFrame = { [weak recordingController] in
            guard let target = recordingController?.armedWindow,
                  let image = try? await ScreenshotService.captureWindowThumbnail(target.window, maxWidth: 480)
            else { return nil }
            return ArmedStageFrame(image: image, frameSize: target.frameSize)
        }
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
        actions.previewCapture = { [weak self] item in
            guard let self else { return }
            self.panelController?.close()
            Task { @MainActor [weak self] in
                guard let capture = await ScreenshotPreviewSource.capture(for: item) else {
                    self?.performLibraryAction(item.url, open: true); return
                }
                let visible = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame ?? .zero
                self?.screenshotPreviewCard?.openPreview(capture, on: visible)
            }
        }
        actions.reportError = { [weak self] message in
            self?.hudToast?.show(text: message, systemSymbol: "exclamationmark.triangle", tint: .systemOrange, respectsSetting: false)
        }
        actions.openLibrary = { [weak self] in
            self?.panelController?.close()
            self?.mainWindowController?.show(module: .library)
        }
        actions.openEditor = { [weak self] in
            self?.panelController?.close()
            self?.mainWindowController?.show(module: .edit)
        }
        actions.openStudio = { [weak self] in
            self?.panelController?.close()
            self?.mainWindowController?.show(module: .studio)
        }
        actions.quit = { NSApp.terminate(nil) }
        actions.openMainWindow = { [weak self] in self?.showMainWindow() }
        actions.openSettings = { [weak self] in
            self?.showSettingsModule()
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
