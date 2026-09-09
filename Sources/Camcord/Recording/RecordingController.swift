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

    private let coordinator: CaptureCoordinator
    private let engine = RecordingEngine()
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

    private(set) var uiState: UIState = .idle

    /// Guards the selection/starting window so a second hotkey press can't start a
    /// parallel flow (the overlay's own isPresenting guard covers the overlay part).
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
    private var pendingResumeCue: (id: UUID, task: Task<Void, Never>)?

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
    var isBusy: Bool { isStarting || uiState != .idle || isFinalizing }

    /// Mirrors `lastPauseToggle`: with the status menu open, the menu key-equivalent
    /// AND the buffered Carbon hotkey can both deliver one ⌘⇧9 press, which would
    /// stop the recording and then immediately pop the start overlay.
    private var lastRecordToggle: ContinuousClock.Instant?

    init(coordinator: CaptureCoordinator) {
        self.coordinator = coordinator
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
        case .idle:
            await beginInteractive()
        }
    }

    /// Opens the window picker and records the chosen window. Unlike the region overlay's
    /// hover-snap, an explicit grid can pick a full-screen app (a game) that leaves no
    /// desktop to drag a region on. The `.window` target follows that window across Spaces
    /// and keeps recording it when it's occluded or sent to the back.
    func recordWindow() async {
        guard !isTerminating, uiState == .idle, !isStarting, !isFinalizing else { return }
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
        guard let window = await windowPicker.pick(content: content) else { return }   // dismissed
        // A display-sized pick (a fullscreen game) records the DISPLAY instead: window-surface
        // capture freezes once a fullscreen app stops presenting after losing focus, while
        // display capture keeps compositing regardless — and it sidesteps the double-scale
        // window-size quirk those apps trigger.
        if let display = fullscreenDisplay(for: window, in: content) {
            let ownApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            await begin(target: .display(display, scale: scale(for: display), excluding: ownApp))
            return
        }
        await begin(target: .window(window))
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

    /// Records the entire display under the mouse pointer (menu action).
    func recordFullScreen() async {
        guard !isTerminating, uiState == .idle, !isStarting, !isFinalizing else { return }
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
            // A short countdown keeps the panel-close animation and the parked pointer
            // out of the first frames, and gives the user a beat to set the stage.
            if RecordingSettings.load(from: .standard).countdownEnabled {
                guard await CountdownOverlay.run(onScreenFrame: screen.frame) else { return }
            }
            let ownApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            await begin(target: .display(display, scale: screen.backingScaleFactor, excluding: ownApp))
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
        startCueTask?.cancel()
        cancelPendingResumeCue()
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
            FeedbackSound.error.play()
        case .recording:
            engine.pause()
            accumulatedElapsed += segmentStart.map { Date().timeIntervalSince($0) } ?? 0
            segmentStart = nil
            stopElapsedTimer()
            uiState = .paused
            pushUI()
            FeedbackSound.recordPause.play()
        case .paused:
            guard pendingResumeCue == nil else { return }
            let id = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.finishResume(after: id)
            }
            pendingResumeCue = (id, task)
        }
    }

    private func finishResume(after id: UUID) async {
        await FeedbackSound.recordResume.playAndWait()
        guard pendingResumeCue?.id == id else { return }
        pendingResumeCue = nil
        guard !Task.isCancelled, !isTerminating, uiState == .paused, engine.isRecording else { return }
        engine.resume()
        segmentStart = Date()
        startElapsedTimer()
        uiState = .recording
        pushUI()
    }

    private func cancelPendingResumeCue() {
        pendingResumeCue?.task.cancel()
        pendingResumeCue = nil
    }

    // MARK: - Start

    private func beginInteractive() async {
        guard !isTerminating, uiState == .idle, !isStarting, !isFinalizing else { return }
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
        // No compositor-flush wait here (unlike screenshots): SCStream.startCapture's own
        // warm-up before its first COMPLETE frame far outlasts the overlay's orderOut
        // flush, so the selection chrome is long gone by the time anything is recorded —
        // the sleep was pure dead time on the start path.

        switch selection {
        case .window(let window):
            await begin(target: .window(window))
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

    private func begin(target requestedTarget: RecordingEngine.Target) async {
        guard !isTerminating else { return }
        // Check the permission that actually gates the recording BEFORE possibly
        // popping a microphone TCC prompt for a session that can't start.
        guard CGPreflightScreenCaptureAccess() else {
            fail("Recording start failed: Screen Recording permission missing")
            return
        }

        var settings = RecordingSettings.load(from: .standard)
        if settings.microphone {
            let granted = await ensureMicrophoneAccess()
            if !granted {
                // Denied mic must not kill the recording -- proceed without it.
                logger.warning("Microphone permission denied; recording without the mic track")
                settings.microphone = false
                onToast?(ToastRequest(text: "Mikrofon izni yok — sesin kaydedilmeyecek", systemSymbol: "mic.slash", tint: .systemOrange, important: true))
            }
        }
        guard !isTerminating else { return }
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
        guard !isTerminating else { return }

        // Every window entry point (including the recording hotkey's click-to-pick)
        // uses the same fullscreen game policy as the explicit window picker.
        var target = requestedTarget
        if case .window(let window) = target,
           let content = try? await coordinator.contentCache.content(),
           let display = fullscreenDisplay(for: window, in: content) {
            let ownApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            target = .display(display, scale: scale(for: display), excluding: ownApp)
        }
        guard !isTerminating else { return }

        await MicrophoneMonitor.shared.prepareForRecording()
        let cameraRect: CGRect
        switch target {
        case .window(let window): cameraRect = CaptureAreaIndicator.windowBounds(window.windowID) ?? window.frame
        case .display(let display, _, _): cameraRect = display.frame
        case .region(let clamp, _, _): cameraRect = clamp.clampedRegion
        }
        CameraOverlayController.shared.prepareRecording(cgRect: cameraRect, options: settings.camera)
        let preparedCamera = await CameraPreviewMonitor.shared.prepareForRecording(options: settings.camera)
        var didStart = false
        defer {
            if !didStart {
                if let preparedCamera { Task { await preparedCamera.stop() } }
                MicrophoneMonitor.shared.recordingEnded()
                CameraOverlayController.shared.hide()
                CameraPreviewMonitor.shared.recordingEnded()
            }
        }
        guard !isTerminating else { return }
        do {
            let directory = try settings.outputDirectory()
            let url = settings.uniqueOutputURL(in: directory, date: Date())
            isEngineStarting = true
            defer { isEngineStarting = false }
            // The existing cue and stream setup overlap. The writer stays paused
            // until both finish, so the cue cannot enter either recorded audio track.
            let cueTask = Task { @MainActor in await FeedbackSound.recordStart.playAndWait() }
            startCueTask = cueTask
            defer { cueTask.cancel(); startCueTask = nil }
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
            segmentStart = Date()
            // Auto-stop guards + best-effort Do Not Disturb, captured for this recording.
            let codec = settings.resolvedCodec
            let limitBytes: Int64 = codec.isProRes ? 3000 * 1024 * 1024 : 500 * 1024 * 1024
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
                    window.windowID, initialCGRect: window.frame, showsBorder: settings.windowGlowEnabled
                ) { [weak self] in
                    Task { await self?.toggleRecording() }
                }
            case .display(let display, _, _):
                indicator.showStopPillOnly(cgRect: display.frame, color: .systemRed) { [weak self] in
                    Task { await self?.toggleRecording() }
                }
            case .region(let clamp, _, _):
                indicator.show(cgRect: clamp.clampedRegion, color: .systemRed, label: nil) { [weak self] in
                    Task { await self?.toggleRecording() }
                }
            }
            indicator.updateStopPillElapsed(Self.formatElapsed(0))
            onToast?(ToastRequest(text: "Kayıt başladı", systemSymbol: "record.circle.fill", tint: .systemRed, important: true))
        } catch RecordingError.incompleteRecording(let url, _) {
            reportPreservedPartial(url)
        } catch is CancellationError {
            // The application is leaving; cancellation is not a failed user recording.
        } catch {
            fail("Recording start failed: \(error)")
        }
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
        cancelPendingResumeCue()
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
                CameraOverlayController.shared.hide()
                CameraPreviewMonitor.shared.recordingEnded()
            }
            do {
                let url = try await engine.stop()
                // Stop has already hidden the controls and freed the capture stream.
                // Keep final output actions unavailable until the atomic audio swap
                // completes; opening/renaming the intermediate file races that swap.
                await engine.waitForPendingMixes()
                // Recordings are NOT copied to the clipboard (only screenshots are) — they're
                // saved to disk and surfaced in the panel's "done" card.
                FeedbackSound.recordStop.play()
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

    private func handleUnexpectedStop(salvagedURL: URL?, error: Error) {
        startCueTask?.cancel()
        startCueTask = nil
        cancelPendingResumeCue()
        MicrophoneMonitor.shared.recordingEnded()
        CameraOverlayController.shared.hide()
        CameraPreviewMonitor.shared.recordingEnded()
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
            // The engine salvaged the partial file -- surface it in the panel (no clipboard;
            // recordings are never copied) instead of leaving it silently on disk.
            onRecordingFinished?(salvagedURL)
            if audioMixFailed { showFinishedToast() }
            logger.notice("Salvaged partial recording: \(salvagedURL.lastPathComponent, privacy: .public)")
        }
        if case RecordingError.incompleteRecording(let url, _) = error {
            reportPreservedPartial(url)
        } else {
            fail("Recording stopped unexpectedly: \(error)")
        }
    }

    private func reportPreservedPartial(_ url: URL) {
        logger.error("Incomplete recording retained for recovery: \(url.path, privacy: .public)")
        onToast?(ToastRequest(text: "Kayıt kesildi — kısmi dosya kayıt klasöründe korundu", systemSymbol: "externaldrive.badge.exclamationmark", tint: .systemOrange, important: true))
        FeedbackSound.error.play()
        onFailure?()
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
            let settings = RecordingSettings.load(from: .standard)
            self?.engine.updateAudioGains(settings)
            self?.engine.updateCameraOptions(settings.camera)
        }
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
        let missingMicrophone = health.microphone.enabled && !health.microphone.isReceiving(at: now)
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
        indicator.updateStopPillElapsed(elapsedText)
    }

    static func formatElapsed(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func fail(_ message: String) {
        logger.error("\(message, privacy: .public)")
        // The diagnostic string is for the log; the toast stays user-facing Turkish.
        onToast?(ToastRequest(text: "Kayıt başarısız oldu", systemSymbol: "exclamationmark.triangle", tint: .systemRed, important: true))
        FeedbackSound.error.play()
        onFailure?()
        PermissionRecovery.noteCaptureFailure()
    }

    private func scale(for display: SCDisplay) -> CGFloat {
        NSScreen.screens.first { $0.cgDirectDisplayID == display.displayID }?.backingScaleFactor ?? 2
    }
}
