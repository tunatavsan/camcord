import AVFoundation
import AppKit
@preconcurrency import ScreenCaptureKit
import os

/// `@MainActor` UX glue for recording: target picking (reusing the screenshot
/// selection overlay), mic permission, start/stop/pause flows, the elapsed timer,
/// and pushing status-item UI state. Owns the `RecordingEngine`.
@MainActor
final class RecordingController: NSObject {
    enum UIState: Equatable {
        case idle
        case recording
        case paused
    }

    @MainActor struct PreparedStartOperations {
        var screenCaptureAuthorized: () -> Bool = { CGPreflightScreenCaptureAccess() }
        var countdown: (CGRect, Int) async -> Bool = { frame, seconds in
            await CountdownOverlay.run(onScreenFrame: frame, seconds: seconds)
        }
    }
    private let defaults: UserDefaults
    private let preparedStartOperations: PreparedStartOperations
    private let stageRegistry = StudioStageRegistry()
    private let legacyStageOwner = UUID()
    private var studioLayersReady = true // The initial layer snapshot is actually empty.
    private(set) var studioLayerSnapshot = StudioLayerSnapshot.empty
    private var preparedStartGeneration: UUID?
    private var preparedOperationGeneration: UUID?
    private let coordinator: CaptureCoordinator
    private let engine: RecordingEngine
    var finalRecordingHealth: RecordingFinalHealth? { engine.finalHealth }
    private let indicator = CaptureAreaIndicator()
    private let windowPicker = WindowPickerPanel()
    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "recording-controller")

    /// Wired by AppDelegate to the status item; pushed on every state/elapsed change.
    var onUIChange: ((UIState, String?) -> Void)?
    var onHealthChange: ((RecordingHealth?) -> Void)?
    private var healthTimer: Timer?
    private var healthGeneration = UUID()
    private var isSamplingHealth = false
    private var didWarnAudio = false
    private var didWarnDroppedSamples = false
    private var audioMixFailed = false
    private var recordingCameraEnabled = false
    private var microphoneHealthGraceUntilUptime: TimeInterval = 0

    /// Wired by AppDelegate to the status item's failure flash (same as the
    /// coordinator's) — pairs every failure beep with a visual cue.
    var onFailure: (() -> Void)?

    /// True from Stop pressed until the file is finalized (panel shows "finishing").
    var onFinishing: ((Bool) -> Void)?
    /// Fired with the finished recording's URL (drives the panel's "done" card).
    var onRecordingFinished: ((URL) -> Void)?
    /// Wired by AppDelegate to the HUD toast — transient confirmations (recording copied)
    /// and important notices (auto-stop on low disk / max duration).
    var onToast: ((ToastRequest) -> Void)?

    private(set) var recordingFrameSize: CGSize = .zero

    func setStageSink(_ sink: (@Sendable (PixelBufferBox) -> Void)?) {
        if let sink { subscribeStage(owner: legacyStageOwner, handler: sink) }
        else { unsubscribeStage(owner: legacyStageOwner) }
    }
    func subscribeStage(owner: UUID, maximumFramesPerSecond: Double? = 10,
                        handler: @escaping @Sendable (PixelBufferBox) -> Void) {
        stageRegistry.subscribe(owner: owner, maximumFramesPerSecond: maximumFramesPerSecond, handler: handler)
        engine.setStageSink(stageRegistry.snapshot())
    }
    func unsubscribeStage(owner: UUID) {
        stageRegistry.unsubscribe(owner: owner)
        engine.setStageSink(stageRegistry.snapshot())
    }
    func updateStudioLayers(_ snapshot: StudioLayerSnapshot) {
        studioLayerSnapshot = snapshot
        engine.updateStudioLayers(studioLayerSnapshot)
    }
    func updateStudioLayerReadiness(_ ready: Bool) { studioLayersReady = ready }
    func stopRecording() async { await stop() }


    private(set) var uiState: UIState = .idle

    /// Guards the selection/starting window so a second hotkey press can't start a
    /// parallel flow (the overlay's own isPresenting guard covers the overlay part).
    private var armed: RecordingEngine.Target?
    private var armedPoll: Timer?
    private var armedMissingBounds = 0
    private var armedEscapeMonitor: Any?
    private var armedEscapeLocalMonitor: Any?
    var isArmed: Bool { armed != nil }

    /// The armed window and the size its recording will composite into — what the panel's
    /// stage needs to show the target and its camera rectangle before a frame exists.
    var armedWindow: (window: SCWindow, frameSize: CGSize)? {
        guard case .window(let window) = armed else { return nil }
        return (window, window.frame.size)
    }
    var onArmedChange: ((Bool) -> Void)?
    var onStartingChange: ((Bool) -> Void)?
    private var isStarting = false { didSet { onStartingChange?(isStarting) } }
    /// True ONLY while `engine.start()` is bringing the stream/writer up — the narrow
    /// window where quitting would strand a half-open writer. (Distinct from `isStarting`,
    /// which also spans the selection overlay, where nothing is open yet.)
    private var isEngineStarting = false
    private var isTerminating = false
    /// The preparation cue overlaps stream setup while the writer remains gated. Termination cancels it so no paused stream is stranded.
    private var startCueTask: Task<Void, Never>?
    /// Resume remains logically paused until this cue finishes. The token prevents a
    /// cancelled old task from resuming a stopped or replacement recording.

    private var accumulatedElapsed: TimeInterval = 0
    private var segmentStart: Date?
    private var elapsedTimer: Timer?

    /// The DND "off" Shortcut to run when this recording ends (captured at start so a
    /// settings change mid-recording can't leave Focus stuck on). Nil = nothing to undo.
    private var activeDNDOffShortcut: String?

    /// Auto-stop guards captured at start (0 maxSeconds = no duration cap).
    private struct ActiveLimits {
        let maxSeconds: TimeInterval
        let diskGuard: Bool
        let volumeURL: URL
        let lowDiskThresholdBytes: Int64
    }
    private var activeLimits: ActiveLimits?
    /// Whether the live recording was started with the camera: only then can the hub take it
    /// out of the file and put it back, live.
    private var recordsCamera = false
    /// Latches once a limit fires so the 1 Hz timer can't spawn a second auto-stop.
    private var didHitLimit = false

    /// The in-flight stop/finalize. `uiState` flips to `.idle` the moment the user
    /// stops (instant UI feedback), but the file's moov atom is only written when
    /// this task completes — anything that treats `.idle` as "nothing in flight"
    /// (starting a new recording, quitting the app) must also consult this.
    private var stopTask: Task<Void, Never>?

    /// True while a stopped recording is still finalizing its file on disk — the moov
    /// atom write (stopTask) OR the background audio mix (which runs after feedback, so
    /// termination must still wait it out).
    var isFinalizing: Bool { stopTask != nil || engine.isFinalizing }

    /// Anything in flight that app termination must not kill mid-way: an interactive
    /// start (stream/writer coming up), a live session, or a finalize still writing.
    var isBusy: Bool { isArmed || isStarting || uiState != .idle || isFinalizing }

    /// Mirrors `lastPauseToggle`: with the status menu open, the menu key-equivalent
    /// AND the buffered Carbon hotkey can both deliver one ⌘⇧9 press, which would
    /// stop the recording and then immediately pop the start overlay.
    private var lastRecordToggle: ContinuousClock.Instant?

    init(coordinator: CaptureCoordinator, defaults: UserDefaults = .standard,
         preparedStartOperations: PreparedStartOperations = .init(), engine injectedEngine: RecordingEngine? = nil) {
        self.defaults = defaults
        self.preparedStartOperations = preparedStartOperations
        self.coordinator = coordinator
        self.engine = injectedEngine ?? RecordingEngine()
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(recordingSettingsChanged), name: RecordingSettings.didChangeNotification, object: nil)
        engine.onCameraIssue = { [weak self] message in
            self?.onToast?(ToastRequest(text: message, systemSymbol: "video.slash", tint: .systemOrange, important: true))
        }
        indicator.onTrackedBoundsChange = { rect in
            CameraOverlayController.shared.updateRecordingBounds(cgRect: rect)
        }
        CameraOverlayController.shared.onPlacementChange = { [weak self] options in
            self?.engine.updateCameraOptions(options)
        }
        indicator.onToggleCamera = { [weak self] in self?.toggleCameraInRecording() }
        engine.onAudioMixFailure = { [weak self] _ in self?.audioMixFailed = true }
        engine.onUnexpectedStop = { [weak self] salvagedURL, error in
            self?.handleUnexpectedStop(salvagedURL: salvagedURL, error: error)
        }
        engine.onRecovered = { [weak self] in
            // The screen reconfigured (fullscreen app switch etc.) and the stream was
            // rebuilt seamlessly — reassure without alarming.
            self?.onToast?(ToastRequest(text: "Kayıt sürüyor", systemSymbol: "record.circle", tint: .systemGreen, important: false))
        }
    }

    // MARK: - Flows

    /// Hotkey/menu entry point: starts an interactive recording when idle, stops the
    /// active one otherwise.
    func toggleRecording() async {
        let now = ContinuousClock.now
        if let lastRecordToggle, now - lastRecordToggle < .milliseconds(200) {
            return
        }
        lastRecordToggle = now

        switch uiState {
        case .recording, .paused:
            await stop()
        case .idle where armed != nil:
            guard requireStudioLayersReady() else { return }
            await startArmed()
        case .idle:
            guard requireStudioLayersReady() else { return }
            await beginInteractive()
        }
    }

    /// Starts Studio's explicit source through the same permission/recovery/cue path.
    /// Studio countdown is independent of the legacy boolean countdown setting.
    func startPreparedTarget(target: RecordingEngine.Target, countdownSeconds: Int) async -> Bool {
        var screenFrame = CGRect.zero
        if countdownSeconds > 0 {
            let cgRect: CGRect
            switch target {
            case .window(let window): cgRect = window.frame
            case .display(let display, _, _): cgRect = display.frame
            case .region(let clamp, _, _): cgRect = clamp.clampedRegion
            }
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let appKitRect = Geometry.cgToAppKit(cgRect, primaryScreenHeight: primaryHeight)
            screenFrame = NSScreen.screens.first(where: { $0.frame.intersects(appKitRect) })?.frame ?? appKitRect
        }
        return await performPreparedStart(countdownSeconds: countdownSeconds, screenFrame: screenFrame) {
            let token = self.preparedStartGeneration
            do {
                // Countdown can outlive a window/display. Resolve its ID against fresh content.
                let content = try await self.coordinator.contentCache.content(forceRefresh: true)
                guard self.preparedStartGeneration == token, self.canContinuePreparedStart else { return false }
                let choice: StudioSourceChoice
                switch target {
                case .window(let window):
                    choice = .init(id: .window(window.windowID), title: "", frame: window.frame, pixelSize: window.frame.size)
                case .display(let display, _, _):
                    choice = .init(id: .display(display.displayID), title: "", frame: display.frame, pixelSize: display.frame.size)
                case .region(let clamp, let display, _):
                    choice = .init(id: .region(display.displayID), title: "", frame: clamp.clampedRegion, pixelSize: clamp.clampedRegion.size)
                }
                let fresh = try StudioSourceResolver.resolve(choice, in: content, settings: RecordingSettings.load(from: self.defaults))
                await self.begin(target: fresh, preparedGeneration: token)
                return self.uiState != .idle
            } catch {
                guard self.preparedStartGeneration == token, !Task.isCancelled else { return false }
                self.fail("Studio recording: selected source unavailable: \(error)")
                return false
            }
        }
    }

    /// This is the production prepared-start transaction. Tests control only its
    /// final operation, so they exercise the actual starting lock and await guards.
    func performPreparedStart(countdownSeconds: Int, screenFrame: CGRect,
                              operation: @MainActor () async -> Bool) async -> Bool {
        guard Self.acceptsPreparedStart(state: uiState, armed: isArmed, starting: isStarting,
                                       finalizing: isFinalizing, terminating: isTerminating,
                                       captureTransition: coordinator.isCaptureTransitionActive,
                                       countdownSeconds: countdownSeconds), !Task.isCancelled,
              requireStudioLayersReady() else { return false }
        let token = UUID()
        preparedStartGeneration = token
        isStarting = true
        defer {
            if preparedOperationGeneration == token { preparedOperationGeneration = nil }
            releasePreparedStart(token)
        }
        return await withTaskCancellationHandler {
            guard preparedStartOperations.screenCaptureAuthorized() else {
                fail("Studio recording: Screen Recording permission missing")
                return false
            }
            if countdownSeconds > 0 {
                guard await preparedStartOperations.countdown(screenFrame, countdownSeconds) else { return false }
            }
            guard preparedStartGeneration == token, canContinuePreparedStart else { return false }
            preparedOperationGeneration = token
            let started = await operation()
            guard preparedStartGeneration == token, !Task.isCancelled, !isTerminating else { return false }
            return started
        } onCancel: {
            Task { @MainActor [weak self] in self?.releasePreparedStart(token) }
        }
    }

    private var canContinuePreparedStart: Bool {
        !Task.isCancelled && !isTerminating && isStarting && uiState == .idle && !isFinalizing
            && !coordinator.isCaptureTransitionActive && requireStudioLayersReady()
    }

    private func releasePreparedStart(_ token: UUID) {
        // Once source resolution/permissions/hardware handoff has entered its body,
        // keep the shared starting lock until that body's cleanup drains.
        guard preparedStartGeneration == token, preparedOperationGeneration != token else { return }
        preparedStartGeneration = nil
        isStarting = false
    }

    private func requireStudioLayersReady() -> Bool {
        guard studioLayersReady else {
            onToast?(ToastRequest(text: String(localized: "Studio layers are not ready. Wait for rendering or fix the layer error.",
                                              comment: "Recording blocked by the current Studio layer revision"),
                                 systemSymbol: "exclamationmark.triangle", tint: .systemOrange, important: true))
            return false
        }
        return true
    }

    static func acceptsPreparedStart(state: UIState, armed: Bool, starting: Bool, finalizing: Bool,
                                     terminating: Bool, captureTransition: Bool, countdownSeconds: Int) -> Bool {
        state == .idle && !armed && !starting && !finalizing && !terminating && !captureTransition
            && StudioSession.countdownChoices.contains(countdownSeconds)
    }

    /// Opens the window picker and records the chosen window. Unlike the region overlay's
    /// hover-snap, an explicit grid can pick a full-screen app (a game) that leaves no
    /// desktop to drag a region on. The `.window` target follows that window across Spaces
    /// and keeps recording it when it's occluded or sent to the back.
    func recordWindow() async {
        guard !isTerminating, uiState == .idle, !isStarting, !isFinalizing, armed == nil,
              requireStudioLayersReady() else { return }
        isStarting = true
        defer { isStarting = false }

        guard CGPreflightScreenCaptureAccess() else {
            fail("recordWindow: Screen Recording permission missing")
            return
        }
        let content: SCShareableContent
        do {
            // Force-refresh so the grid reflects the CURRENT windows, not a 5s-old snapshot.
            content = try await coordinator.contentCache.content(forceRefresh: true)
        } catch {
            fail("recordWindow: shareable content fetch failed: \(error)")
            return
        }
        guard let choice = await windowPicker.pick(content: content) else { return }   // dismissed
        switch choice {
        case .window(let window):
            // Every window pick arms: the red frame shows what will be recorded and the owner
            // places the camera before pressing Başlat. The fullscreen→display conversion the
            // window path needs happens inside startArmed(), so a game window arms too.
            arm(target: .window(window))
        case .display(let display):
            // The picker's "<App> — tam ekran" card: the game's own window never reached the
            // grid, so there is no window frame to arm a red placement rectangle against —
            // record the display it covers straight away, at the game scale.
            let settings = RecordingSettings.load(from: defaults)
            let ownApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            await begin(target: .display(
                display,
                scale: settings.captureScale(displayScale: scale(for: display), gameLike: true),
                excluding: ownApp
            ))
        }
    }

    private func arm(target: RecordingEngine.Target) {
        guard armed == nil, !isTerminating, case .window(let window) = target else { return }
        armed = target
        armedMissingBounds = 0
        let settings = RecordingSettings.load(from: defaults)
        // Arming CONFINES the camera preview to the window that will be recorded -- it never
        // opens one. begin() composites against this very rect, so a placement the owner
        // makes with the preview open lands in the file, and one made with it closed does
        // too. Opening the preview is the owner's move alone (panel chip / status menu).
        // Only when the camera is actually recorded: begin() releases the confinement when
        // it is not, and confining here anyway would visibly snap an open preview into the
        // window at arm and back out at Başlat.
        if settings.camera.enabled {
            CameraOverlayController.shared.prepareRecording(
                cgRect: CaptureAreaIndicator.windowBounds(window.windowID) ?? window.frame,
                options: settings.camera
            )
        }
        // The frame is the placement frame, not the window glow, so it is always drawn.
        pushCameraState()
        indicator.showRecordingWindow(window.windowID, initialCGRect: window.frame, showsBorder: true,
                                      mode: .armed, color: .systemRed,
                                      onCancel: { [weak self] in self?.cancelArmed() }) { [weak self] in
            Task { await self?.startArmed() }
        }
        armedPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .window(let window) = self.armed else { return }
                self.armedMissingBounds = CaptureAreaIndicator.windowBounds(window.windowID) == nil ? self.armedMissingBounds + 1 : 0
                if self.armedMissingBounds >= 2 { self.cancelArmed() }
            }
        }
        armedEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelArmed() }
        }
        // The global monitor never sees events routed to our own key window, and the panel
        // is deliberately held open while armed — so Esc needs the local path too.
        armedEscapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, Self.armedEscapeCancels(event.window) else { return event }
            self?.cancelArmed()
            return nil
        }
        onArmedChange?(true)
    }

    func startArmed() async {
        guard let requestedTarget = armed, !isTerminating, !isStarting, requireStudioLayersReady() else { return }
        isStarting = true
        defer { isStarting = false }
        // The armed hub becomes the recording one in place instead of leaving and coming back.
        clearArmedControls(handingOff: true)
        armed = nil
        onArmedChange?(false)
        // A display-sized pick (a fullscreen game) records the DISPLAY instead: window-surface
        // capture freezes once a fullscreen app stops presenting after losing focus, while
        // display capture keeps compositing regardless — and it sidesteps the double-scale
        // window-size quirk those apps trigger.
        var target = requestedTarget
        if case .window(let window) = target,
           let content = try? await coordinator.contentCache.content(),
           let display = fullscreenDisplay(for: window, in: content) {
            let ownApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            target = .display(display, scale: scale(for: display), excluding: ownApp)
        }
        await begin(target: target, convertsFullscreen: false)
        indicator.endHandoff()
        if uiState == .idle { CameraOverlayController.shared.recordingEnded() }
    }

    func cancelArmed() {
        guard armed != nil else { return }
        clearArmedControls()
        armed = nil
        // Drops the confinement rect the placement frame was using. The preview itself,
        // open or closed, stays exactly as the owner left it.
        CameraOverlayController.shared.recordingEnded()
        onArmedChange?(false)
    }

    /// Esc while armed cancels the arming, but the local monitor must not eat every Esc
    /// in the app: only Camcord's own floating capture surfaces (the panel or popover
    /// holding Başlat, the indicator's panels) hand it over. A titled window, a sheet or
    /// a save panel keeps its own Esc; with no key window at all the Esc is ours.
    static func armedEscapeCancels(_ window: NSWindow?) -> Bool {
        guard let window else { return true }
        guard let panel = window as? NSPanel, !panel.isSheet, !(panel is NSSavePanel) else { return false }
        return true
    }

    private func clearArmedControls(handingOff: Bool = false) {
        armedPoll?.invalidate()
        armedPoll = nil
        if let armedEscapeMonitor { NSEvent.removeMonitor(armedEscapeMonitor) }
        armedEscapeMonitor = nil
        if let armedEscapeLocalMonitor { NSEvent.removeMonitor(armedEscapeLocalMonitor) }
        armedEscapeLocalMonitor = nil
        if handingOff { indicator.beginHandoff(elapsed: Self.formatElapsed(0)) } else { indicator.hide() }
    }

    /// The display whose frame the window covers (±2pt), either at point size or at the
    /// double-scaled size fullscreen-exclusive apps report. Nil for normal windows.
    private func fullscreenDisplay(for window: SCWindow, in content: SCShareableContent) -> SCDisplay? {
        content.displays.first { display in
            let d = display.frame
            let w = window.frame
            guard abs(w.minX - d.minX) <= 2, abs(w.minY - d.minY) <= 2 else { return false }
            let pointMatch = abs(w.width - d.width) <= 2 && abs(w.height - d.height) <= 2
            let s = scale(for: display)
            let scaledMatch = abs(w.width - d.width * s) <= 2 && abs(w.height - d.height * s) <= 2
            return pointMatch || scaledMatch
        }
    }

    /// Records the entire display under the mouse pointer (menu action). `gameLike` marks
    /// the Phase G.6 hotkey path taken while a fullscreen game owns the screen: no
    /// countdown, no stop pill over the game, and the "Oyunda 1080p kaydet" scale. The
    /// same hotkey stops the run (`toggleRecording()` handles that side).
    func recordFullScreen(gameLike: Bool = false) async {
        guard !isTerminating, uiState == .idle, !isStarting, !isFinalizing, armed == nil,
              requireStudioLayersReady() else { return }
        isStarting = true
        defer { isStarting = false }

        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main,
            let displayID = screen.cgDirectDisplayID
        else {
            fail("recordFullScreen: no screen under the pointer")
            return
        }
        do {
            let content = try await coordinator.contentCache.content()
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                fail("recordFullScreen: no SCDisplay match for display \(displayID)")
                return
            }
            let settings = RecordingSettings.load(from: defaults)
            // A short countdown keeps the panel-close animation and the parked pointer
            // out of the first frames, and gives the user a beat to set the stage. In a
            // game it would only delay a trigger the owner pressed mid-play.
            if !gameLike, settings.countdownEnabled {
                guard await CountdownOverlay.run(onScreenFrame: screen.frame) else { return }
            }
            let ownApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            await begin(target: .display(
                display,
                scale: settings.captureScale(displayScale: screen.backingScaleFactor, gameLike: gameLike),
                excluding: ownApp
            ))
            // G.6: nothing of ours belongs over a game. begin() orders the stop pill up
            // with no await after it, so dismissing it here removes it before it draws —
            // the start/stop sounds and the same hotkey are the whole interface there.
            if gameLike { indicator.hide() }
        } catch {
            fail("recordFullScreen: shareable content fetch failed: \(error)")
        }
    }

    /// Terminate-path stop: unlike `toggleRecording()`, this can never START a
    /// recording, so a state flip between the caller's check and this call can't
    /// pop the selection overlay while the app is trying to quit. If a stop is
    /// already finalizing, it waits for that instead of tearing down twice.
    func stopForTermination() async {
        isTerminating = true
        cancelArmed()
        startCueTask?.cancel()
        engine.cancelPendingStart()
        await performTerminationStop()
        // The audio mix runs in the background after a normal stop; on the quit path we
        // must wait it out so a Cmd-Q right after stopping still leaves the single-track
        // (mic-audible) file, not the intermediate two-track one. Bounded by the 20s
        // AppDelegate failsafe.
        await engine.waitForPendingMixes()
    }

    private func performTerminationStop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        // A stream may be mid-`engine.start()` — killing the process now would leave a
        // half-open file. The engine start is cancelled and bounded to five seconds;
        // wait for its cleanup (the 20s AppDelegate failsafe backstops a hung writer), then stop whatever it
        // became. We deliberately do NOT wait on the plain selection-overlay phase — no
        // stream exists there, so quitting during it is safe and shouldn't be delayed.
        while isEngineStarting {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if let stopTask {
            await stopTask.value
            return
        }
        guard uiState != .idle else { return }
        await stop()
    }

    /// Guards the pause toggle against double-fire: while the status menu is open,
    /// its key-equivalent AND the Carbon hotkey can both deliver the same keystroke,
    /// which would pause-then-resume in one press.
    private var lastPauseToggle: ContinuousClock.Instant?

    /// Soft pause/resume. Beeps when idle.
    func pauseResume() {
        let now = ContinuousClock.now
        if let lastPauseToggle, now - lastPauseToggle < .milliseconds(200) {
            return
        }
        lastPauseToggle = now
        switch uiState {
        case .idle:
            FeedbackSound.error.play(in: defaults)
        case .recording:
            engine.pause()
            accumulatedElapsed += segmentStart.map { Date().timeIntervalSince($0) } ?? 0
            segmentStart = nil
            stopElapsedTimer()
            uiState = .paused
            pushUI()
            FeedbackSound.recordPause.play(in: defaults)
        case .paused:
            // Resuming is as immediate as pausing; its cue follows on the next turn, never waited on.
            guard !isTerminating, engine.isRecording else { return }
            resume()
            let defaults = defaults
            Task { @MainActor in FeedbackSound.recordResume.play(in: defaults) }
        }
    }

    private func resume() {
        engine.resume()
        microphoneHealthGraceUntilUptime = ProcessInfo.processInfo.systemUptime + 2
        segmentStart = Date()
        startElapsedTimer()
        uiState = .recording
        pushUI()
    }

    // MARK: - Start

    private func beginInteractive() async {
        guard !isTerminating, uiState == .idle, !isStarting, !isFinalizing, armed == nil,
              requireStudioLayersReady() else { return }
        isStarting = true
        defer { isStarting = false }

        // Without the Screen Recording grant the overlay's window-snap can never
        // resolve and the stream start is doomed anyway -- route straight to the
        // recovery path instead of presenting a dead-end overlay.
        guard CGPreflightScreenCaptureAccess() else {
            fail("beginInteractive: Screen Recording permission missing")
            return
        }

        guard let selection = await coordinator.selectCaptureTarget() else { return }
        guard requireStudioLayersReady() else { return }
        // No compositor-flush wait here (unlike screenshots): SCStream.startCapture's own
        // warm-up before its first COMPLETE frame far outlasts the overlay's orderOut
        // flush, so the selection chrome is long gone by the time anything is recorded —
        // the sleep was pure dead time on the start path.

        switch selection {
        case .window(let window):
            arm(target: .window(window))
        case .region(let cgRect):
            do {
                let content = try await coordinator.contentCache.content()
                let frames = content.displays.map { display in
                    RegionClamp.DisplayFrame(frame: display.frame, scale: scale(for: display))
                }
                guard
                    let clamp = RegionClamp.clamp(region: cgRect, displays: frames),
                    clamp.pixelWidth >= 2, clamp.pixelHeight >= 2
                else {
                    fail("Region recording: selection does not intersect any display (or is too small)")
                    return
                }
                if clamp.clampedRegion != cgRect {
                    logger.notice("Region spanned displays; clamped to display \(clamp.displayIndex)")
                }
                let ownApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                await begin(target: .region(clamp, content.displays[clamp.displayIndex], excluding: ownApp))
            } catch {
                fail("Region recording: shareable content fetch failed: \(error)")
            }
        }
    }

    private func begin(target requestedTarget: RecordingEngine.Target, convertsFullscreen: Bool = true,
                       preparedGeneration: UUID? = nil) async {
        guard !isTerminating, requireStudioLayersReady(), preparedGenerationIsCurrent(preparedGeneration) else { return }
        // Check the permission that actually gates the recording BEFORE possibly
        // popping a microphone TCC prompt for a session that can't start.
        guard CGPreflightScreenCaptureAccess() else {
            fail("Recording start failed: Screen Recording permission missing")
            return
        }

        var settings = RecordingSettings.load(from: defaults)
        if settings.microphone {
            let granted = await ensureMicrophoneAccess()
            if !granted {
                // Denied mic must not kill the recording -- proceed without it.
                logger.warning("Microphone permission denied; recording without the mic track")
                settings.microphone = false
                onToast?(ToastRequest(text: "Mikrofon izni yok — sesin kaydedilmeyecek", systemSymbol: "mic.slash", tint: .systemOrange, important: true))
            }
        }
        guard !isTerminating, requireStudioLayersReady(), preparedGenerationIsCurrent(preparedGeneration) else { return }
        if settings.camera.enabled {
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
            default: granted = false
            }
            if !granted {
                settings.camera.enabled = false
                onToast?(ToastRequest(text: "Kamera izni yok — ekran kaydı kamerasız başlayacak", systemSymbol: "video.slash", tint: .systemOrange, important: true))
            }
        }
        guard !isTerminating, requireStudioLayersReady(), preparedGenerationIsCurrent(preparedGeneration) else { return }

        // Every window entry point (including the recording hotkey's click-to-pick)
        // uses the same fullscreen game policy as the explicit window picker.
        var target = requestedTarget
        if convertsFullscreen, case .window(let window) = target,
           let content = try? await coordinator.contentCache.content(),
           let display = fullscreenDisplay(for: window, in: content) {
            let ownApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            target = .display(display, scale: scale(for: display), excluding: ownApp)
        }
        guard !isTerminating, requireStudioLayersReady(), preparedGenerationIsCurrent(preparedGeneration) else { return }

        await MicrophoneMonitor.shared.prepareForRecording()
        guard !isTerminating, requireStudioLayersReady(), preparedGenerationIsCurrent(preparedGeneration) else {
            MicrophoneMonitor.shared.recordingEnded()
            return
        }
        let cameraRect: CGRect
        switch target {
        case .window(let window): cameraRect = CaptureAreaIndicator.windowBounds(window.windowID) ?? window.frame
        case .display(let display, _, _): cameraRect = display.frame
        case .region(let clamp, _, _): cameraRect = clamp.clampedRegion
        }
        recordingFrameSize = cameraRect.size
        recordingCameraEnabled = settings.camera.enabled
        var preparedCamera: CameraCapture?
        if settings.camera.enabled {
            CameraOverlayController.shared.prepareRecording(cgRect: cameraRect, options: settings.camera)
            preparedCamera = await CameraPreviewMonitor.shared.prepareForRecording(options: settings.camera)
        } else {
            // Nothing is composited, so no target confines the preview. Without this the
            // teardown below (gated on recordingCameraEnabled) never runs and an armed
            // window's rect would keep confining the free preview after the recording.
            CameraOverlayController.shared.recordingEnded()
        }
        var didStart = false
        defer {
            if !didStart {
                if let preparedCamera { Task { await preparedCamera.stop() } }
                MicrophoneMonitor.shared.recordingEnded()
                if recordingCameraEnabled {
                    CameraPreviewMonitor.shared.recordingEnded()
                    CameraOverlayController.shared.recordingEnded()
                    recordingCameraEnabled = false
                }
            }
        }
        guard !isTerminating, requireStudioLayersReady(), preparedGenerationIsCurrent(preparedGeneration) else { return }
        do {
            let directory = try settings.outputDirectory()
            let url = settings.uniqueOutputURL(in: directory, date: Date())
            isEngineStarting = true
            defer { isEngineStarting = false }
            // The existing cue and stream setup overlap. The writer stays paused
            // until both finish, so the cue cannot enter either recorded audio track.
            let cueTask = Task { @MainActor [defaults] in await FeedbackSound.recordStart.playAndWait(in: defaults) }
            startCueTask = cueTask
            defer { cueTask.cancel(); startCueTask = nil }
            guard requireStudioLayersReady(), preparedGenerationIsCurrent(preparedGeneration) else { return }
            try await engine.start(
                target: target,
                settings: settings,
                outputURL: url,
                initiallyPaused: true,
                preparedCamera: preparedCamera
            )
            guard !Task.isCancelled, !isTerminating else {
                if engine.isRecording {
                    _ = try? await engine.stop()
                    await engine.waitForPendingMixes()
                }
                return
            }
            await cueTask.value
            startCueTask = nil
            guard !Task.isCancelled, !isTerminating, engine.isRecording else {
                if engine.isRecording {
                    _ = try? await engine.stop()
                    await engine.waitForPendingMixes()
                }
                return
            }
            engine.resume()
            didStart = true

            accumulatedElapsed = 0
            didWarnAudio = false
            didWarnDroppedSamples = false
            audioMixFailed = false
            microphoneHealthGraceUntilUptime = 0
            segmentStart = Date()
            // Auto-stop guards + best-effort Do Not Disturb, captured for this recording.
            let codec = settings.resolvedCodec
            let limitBytes: Int64 = codec.isProRes ? 3000 * 1024 * 1024 : 500 * 1024 * 1024
            recordsCamera = settings.camera.enabled
            activeLimits = ActiveLimits(
                maxSeconds: settings.maxDurationMinutes > 0 ? Double(settings.maxDurationMinutes) * 60 : 0,
                diskGuard: settings.stopWhenDiskLow,
                volumeURL: directory,
                lowDiskThresholdBytes: limitBytes
            )
            didHitLimit = false
            if settings.dndEnabled {
                DoNotDisturb.run(shortcutNamed: settings.dndShortcutOn)
                activeDNDOffShortcut = settings.dndShortcutOff
            } else {
                activeDNDOffShortcut = nil
            }
            startElapsedTimer()
            uiState = .recording
            pushUI()
            // The stop/elapsed control stays available even when the menu bar is
            // crowded or the optional window border is disabled.
            switch target {
            case .window(let window):
                indicator.showRecordingWindow(
                    window.windowID, initialCGRect: window.frame, showsBorder: settings.windowGlowEnabled,
                    onPauseResume: { [weak self] in self?.pauseResume() },
                    onTogglePreview: { CameraOverlayController.shared.togglePreview() }
                ) { [weak self] in
                    Task { await self?.toggleRecording() }
                }
            case .display(let display, _, _):
                indicator.showHubOnly(
                    cgRect: display.frame, color: .systemRed,
                    onStop: { [weak self] in Task { await self?.toggleRecording() } },
                    onPauseResume: { [weak self] in self?.pauseResume() },
                    onTogglePreview: { CameraOverlayController.shared.togglePreview() }
                )
            case .region(let clamp, _, _):
                indicator.show(
                    cgRect: clamp.clampedRegion, color: .systemRed,
                    onStop: { [weak self] in Task { await self?.toggleRecording() } },
                    onPauseResume: { [weak self] in self?.pauseResume() },
                    onTogglePreview: { CameraOverlayController.shared.togglePreview() }
                )
            }
            indicator.updateHub(elapsed: Self.formatElapsed(0))
            pushCameraState()
            onToast?(ToastRequest(text: "Kayıt başladı", systemSymbol: "record.circle.fill", tint: .systemRed, important: true))
        } catch RecordingError.incompleteRecording(let url, _) {
            reportPreservedPartial(url)
        } catch is CancellationError {
            // The application is leaving; cancellation is not a failed user recording.
        } catch {
            fail("Recording start failed: \(error)")
        }
    }

    private func preparedGenerationIsCurrent(_ token: UUID?) -> Bool {
        guard let token else { return true }
        return preparedStartGeneration == token && !Task.isCancelled && !coordinator.isCaptureTransitionActive
    }

    // MARK: - Auto-stop guards (disk / duration)

    /// Called each 1 Hz elapsed tick while recording: stops (keeping the file) before the
    /// writer would fail on a full disk, and enforces the optional max-duration cap.
    private func checkLimits() {
        guard let limits = activeLimits, !didHitLimit, uiState == .recording else { return }
        if limits.maxSeconds > 0, currentElapsed >= limits.maxSeconds {
            didHitLimit = true
            logger.notice("Max duration reached; auto-stopping and keeping the file")
            Task { await self.autoStop(message: "Süre sınırına ulaşıldı — kayıt kaydedildi", symbol: "clock.badge.checkmark") }
            return
        }
        if limits.diskGuard, let free = Self.freeBytes(on: limits.volumeURL), free < limits.lowDiskThresholdBytes {
            didHitLimit = true
            logger.notice("Low disk (\(free) bytes free); auto-stopping and keeping the file")
            Task { await self.autoStop(message: "Disk doldu — kayıt kaydedildi", symbol: "externaldrive.badge.exclamationmark") }
        }
    }

    /// A graceful, non-failure stop triggered by a guard: finalizes normally (the file is
    /// kept) and shows an important toast explaining why.
    private func autoStop(message: String, symbol: String) async {
        guard uiState != .idle else { return }
        onToast?(ToastRequest(text: message, systemSymbol: symbol, tint: .systemOrange, important: true))
        await stop()
    }

    private static func freeBytes(on url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Stop

    private func stop() async {
        // A second stop while the first is finalizing just waits for it.
        if let stopTask {
            await stopTask.value
            return
        }
        // The session may have already concluded (e.g. handleUnexpectedStop fired
        // between the caller's check and here) — don't re-run engine.stop() on a dead
        // engine and report a false failure.
        guard uiState != .idle else { return }

        stopElapsedTimer()
        segmentStart = nil
        uiState = .idle
        activeLimits = nil
        endDoNotDisturb()
        indicator.hide()
        // Show "finishing" immediately so the panel never flashes the capture grid
        // between Stop and the file being ready.
        onFinishing?(true)
        pushUI()

        // The finalize runs inside a tracked task so `isFinalizing` stays true (and
        // new starts / app termination stay blocked) until the moov atom is on disk.
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                MicrophoneMonitor.shared.recordingEnded()
                if recordingCameraEnabled {
                    CameraPreviewMonitor.shared.recordingEnded()
                    CameraOverlayController.shared.recordingEnded()
                    recordingCameraEnabled = false
                }
            }
            do {
                let url = try await engine.stop()
                // Stop has already hidden the controls and freed the capture stream.
                // Keep final output actions unavailable until the atomic audio swap
                // completes; opening/renaming the intermediate file races that swap.
                await engine.waitForPendingMixes()
                // Recordings are NOT copied to the clipboard (only screenshots are) — they're
                // saved to disk and surfaced in the panel's "done" card.
                FeedbackSound.recordStop.play(in: defaults)
                showFinishedToast()
                onRecordingFinished?(url)
                logger.notice("Recording finished: \(url.lastPathComponent, privacy: .public)")
            } catch RecordingError.notRecording {
                // The engine was already torn down by an unexpected-stop / writer-runtime-
                // failure path, which owns the single failure report (onUnexpectedStop).
                // Don't double-report — just clear the "finishing" state.
                onFinishing?(false)
            } catch RecordingError.incompleteRecording(let url, _) {
                onFinishing?(false)
                reportPreservedPartial(url)
            } catch {
                onFinishing?(false)
                fail("Recording stop/finalize failed: \(error)")
            }
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    func handleUnexpectedStop(salvagedURL: URL?, error: Error) {
        startCueTask?.cancel()
        startCueTask = nil
        MicrophoneMonitor.shared.recordingEnded()
        if recordingCameraEnabled {
            CameraPreviewMonitor.shared.recordingEnded()
            CameraOverlayController.shared.recordingEnded()
            recordingCameraEnabled = false
        }
        stopElapsedTimer()
        segmentStart = nil
        accumulatedElapsed = 0
        uiState = .idle
        activeLimits = nil
        endDoNotDisturb()
        indicator.hide()
        pushUI()
        onFinishing?(false)
        if let salvagedURL {
            reportPreservedPartial(salvagedURL)
            logger.notice("Salvaged partial recording: \(salvagedURL.lastPathComponent, privacy: .public)")
            return
        }
        if case RecordingError.incompleteRecording(let url, _) = error {
            reportPreservedPartial(url)
        } else {
            fail("Recording stopped unexpectedly: \(error)")
        }
    }

    private func reportPreservedPartial(_ url: URL) {
        logger.error("Incomplete recording retained for recovery: \(url.path, privacy: .public)")
        onRecordingFinished?(url)
        onToast?(ToastRequest(text: "Kayıt kesildi · kaydedilen kısım korundu", systemSymbol: "externaldrive.badge.exclamationmark", tint: .systemOrange, important: true))
    }

    // MARK: - Do Not Disturb

    /// Runs the captured DND "off" Shortcut (once) when a recording ends. Idempotent.
    private func endDoNotDisturb() {
        guard let off = activeDNDOffShortcut else { return }
        activeDNDOffShortcut = nil
        DoNotDisturb.run(shortcutNamed: off)
    }

    // MARK: - Microphone permission

    private func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // MARK: - Elapsed timer

    private func startElapsedTimer() {
        stopElapsedTimer()
        startHealthTimer()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.pushUI()
                self.checkLimits()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        healthTimer?.invalidate()
        healthTimer = nil
        healthGeneration = UUID()
        onHealthChange?(nil)
    }

    @objc nonisolated private func recordingSettingsChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let settings = RecordingSettings.load(from: self.defaults)
            self.engine.updateAudioGains(settings)
            self.engine.updateCameraOptions(settings.camera)
            self.pushCameraState()
        }
    }

    /// The hub's camera control. Off takes the camera out of the file (its frames are no longer
    /// composited); on puts it back — possible only when the recording started with it. Before
    /// a recording it simply chooses whether the next one has the camera.
    func toggleCameraInRecording() {
        if uiState != .idle, !recordsCamera {
            onToast?(ToastRequest(text: "Bu kayıt kamerasız başladı — kamera eklenemez", systemSymbol: "video.slash",
                                  tint: .systemOrange, important: true))
            return
        }
        var settings = RecordingSettings.load(from: defaults)
        settings.camera.enabled.toggle()
        settings.save(to: defaults)
        engine.updateCameraOptions(settings.camera)
        pushCameraState()
    }

    private func pushCameraState() {
        let settings = RecordingSettings.load(from: defaults)
        indicator.updateHubCamera(on: settings.camera.enabled && (uiState == .idle || recordsCamera),
                                  available: uiState == .idle || recordsCamera)
    }

    private func startHealthTimer() {
        let generation = healthGeneration
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isSamplingHealth else { return }
                self.isSamplingHealth = true
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.isSamplingHealth = false }
                    let health = await self.engine.healthSnapshot()
                    guard self.healthGeneration == generation, self.uiState == .recording else { return }
                    self.onHealthChange?(health)
                    self.indicator.updateHubMicLevel(health?.microphone.levels?.rmsDBFS)
                    if let health { self.checkAudioHealth(health) }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func checkAudioHealth(_ health: RecordingHealth) {
        guard currentElapsed > 5 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let missingMicrophone = Self.isMicrophoneMissing(
            health.microphone,
            at: now,
            graceUntil: microphoneHealthGraceUntilUptime
        )
        let processingFailed = health.microphone.processingFailed || health.systemAudio.processingFailed
        if !didWarnAudio, missingMicrophone || processingFailed {
            didWarnAudio = true
            onToast?(ToastRequest(
                text: missingMicrophone ? "Mikrofondan ses gelmiyor — ses girişini kontrol et" : "Ses kaydında sorun var — ses ayarlarını kontrol et",
                systemSymbol: "mic.badge.xmark", tint: .systemOrange, important: true
            ))
        }
        let audio = [health.microphone.samples, health.systemAudio.samples]
        if !didWarnDroppedSamples, audio.contains(where: { $0.delivered > 100 && Double($0.dropped) / Double($0.delivered) > 0.02 }) {
            didWarnDroppedSamples = true
            onToast?(ToastRequest(text: "Ses kesintileri algılandı — kayıt devam ediyor", systemSymbol: "waveform.badge.exclamationmark", tint: .systemOrange, important: true))
        }
    }

    private func showFinishedToast() {
        if audioMixFailed {
            onToast?(ToastRequest(text: "Kayıt kaydedildi; sesler ayrı kanallarda korundu", systemSymbol: "waveform.badge.exclamationmark", tint: .systemOrange, important: true))
        } else {
            onToast?(ToastRequest(text: "Kayıt kaydedildi", systemSymbol: "film.circle.fill"))
        }
    }

    private var currentElapsed: TimeInterval {
        accumulatedElapsed + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func pushUI() {
        let elapsedText: String? = uiState == .idle ? nil : Self.formatElapsed(currentElapsed)
        onUIChange?(uiState, elapsedText)
        indicator.updateHub(elapsed: elapsedText, paused: uiState == .paused)
    }

    static func formatElapsed(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func isMicrophoneMissing(
        _ microphone: AudioSourceHealth,
        at uptime: TimeInterval,
        graceUntil: TimeInterval
    ) -> Bool {
        microphone.enabled
            && uptime >= graceUntil
            && !microphone.isReceiving(at: uptime)
    }

    private func fail(_ message: String) {
        logger.error("\(message, privacy: .public)")
        // The diagnostic string is for the log; the toast stays user-facing Turkish.
        onToast?(ToastRequest(text: "Kayıt başarısız oldu", systemSymbol: "exclamationmark.triangle", tint: .systemRed, important: true))
        FeedbackSound.error.play(in: defaults)
        onFailure?()
        PermissionRecovery.noteCaptureFailure()
    }

    private func scale(for display: SCDisplay) -> CGFloat {
        NSScreen.screens.first { $0.cgDirectDisplayID == display.displayID }?.backingScaleFactor ?? 2
    }
}
