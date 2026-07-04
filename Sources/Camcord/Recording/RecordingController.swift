import AVFoundation
import AppKit
@preconcurrency import ScreenCaptureKit
import os

/// `@MainActor` UX glue for recording: target picking (reusing the screenshot
/// selection overlay), mic permission, start/stop/pause flows, the elapsed timer,
/// and pushing status-item UI state. Owns the `RecordingEngine`.
@MainActor
final class RecordingController {
    enum UIState: Equatable {
        case idle
        case recording
        case paused
    }

    private let coordinator: CaptureCoordinator
    private let engine = RecordingEngine()
    private let indicator = RecordingIndicator()
    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "recording-controller")

    /// Wired by AppDelegate to the status item; pushed on every state/elapsed change.
    var onUIChange: ((UIState, String?) -> Void)?

    /// Wired by AppDelegate to the status item's failure flash (same as the
    /// coordinator's) — pairs every failure beep with a visual cue.
    var onFailure: (() -> Void)?

    /// True from Stop pressed until the file is finalized (panel shows "finishing").
    var onFinishing: ((Bool) -> Void)?
    /// Fired with the finished recording's URL (drives the panel's "done" card).
    var onRecordingFinished: ((URL) -> Void)?

    private(set) var uiState: UIState = .idle

    /// Guards the selection/starting window so a second hotkey press can't start a
    /// parallel flow (the overlay's own isPresenting guard covers the overlay part).
    private var isStarting = false

    private var accumulatedElapsed: TimeInterval = 0
    private var segmentStart: Date?
    private var elapsedTimer: Timer?

    private static let postHideDelay: Duration = .milliseconds(80)

    /// The in-flight stop/finalize. `uiState` flips to `.idle` the moment the user
    /// stops (instant UI feedback), but the file's moov atom is only written when
    /// this task completes — anything that treats `.idle` as "nothing in flight"
    /// (starting a new recording, quitting the app) must also consult this.
    private var stopTask: Task<Void, Never>?

    /// True while a stopped recording is still finalizing its file on disk.
    var isFinalizing: Bool { stopTask != nil }

    /// Mirrors `lastPauseToggle`: with the status menu open, the menu key-equivalent
    /// AND the buffered Carbon hotkey can both deliver one ⌘⇧9 press, which would
    /// stop the recording and then immediately pop the start overlay.
    private var lastRecordToggle: ContinuousClock.Instant?

    init(coordinator: CaptureCoordinator) {
        self.coordinator = coordinator
        engine.onUnexpectedStop = { [weak self] salvagedURL, error in
            self?.handleUnexpectedStop(salvagedURL: salvagedURL, error: error)
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

    /// Records the entire display under the mouse pointer (menu action).
    func recordFullScreen() async {
        guard uiState == .idle, !isStarting, stopTask == nil else { return }
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
            await begin(target: .display(display, scale: screen.backingScaleFactor))
        } catch {
            fail("recordFullScreen: shareable content fetch failed: \(error)")
        }
    }

    /// Terminate-path stop: unlike `toggleRecording()`, this can never START a
    /// recording, so a state flip between the caller's check and this call can't
    /// pop the selection overlay while the app is trying to quit. If a stop is
    /// already finalizing, it waits for that instead of tearing down twice.
    func stopForTermination() async {
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
            engine.resume()
            segmentStart = Date()
            startElapsedTimer()
            uiState = .recording
            pushUI()
            FeedbackSound.recordResume.play()
        }
    }

    // MARK: - Start

    private func beginInteractive() async {
        guard uiState == .idle, !isStarting, stopTask == nil else { return }
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
        // The overlay tore its panels down before returning; let the compositor flush
        // the hide before the stream's first frame (same rule as screenshots).
        try? await Task.sleep(for: Self.postHideDelay)

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
                await begin(target: .region(clamp, content.displays[clamp.displayIndex]))
            } catch {
                fail("Region recording: shareable content fetch failed: \(error)")
            }
        }
    }

    private func begin(target: RecordingEngine.Target) async {
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
            }
        }

        do {
            let directory = try settings.outputDirectory()
            let url = settings.uniqueOutputURL(in: directory, date: Date())
            try await engine.start(target: target, settings: settings, outputURL: url)

            accumulatedElapsed = 0
            segmentStart = Date()
            startElapsedTimer()
            uiState = .recording
            pushUI()
            FeedbackSound.recordStart.play()
            // A subtle static glow around a recorded window (never full-screen/region,
            // and never captured — it is a separate window). Clicking it stops.
            if settings.windowGlowEnabled, case .window(let window) = target {
                indicator.showWindow(window.windowID) { [weak self] in
                    Task { await self?.toggleRecording() }
                }
            }
        } catch {
            fail("Recording start failed: \(error)")
        }
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
        indicator.hide()
        // Show "finishing" immediately so the panel never flashes the capture grid
        // between Stop and the file being ready.
        onFinishing?(true)
        pushUI()

        // The finalize runs inside a tracked task so `isFinalizing` stays true (and
        // new starts / app termination stay blocked) until the moov atom is on disk.
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await engine.stop()
                copyFileURLToClipboard(url)
                FeedbackSound.recordStop.play()
                onRecordingFinished?(url)
                logger.notice("Recording finished: \(url.lastPathComponent, privacy: .public)")
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
        stopElapsedTimer()
        segmentStart = nil
        accumulatedElapsed = 0
        uiState = .idle
        indicator.hide()
        pushUI()
        if let salvagedURL {
            // The engine salvaged the partial file -- hand it to the user the same
            // way a normal stop would instead of leaving it silently on disk.
            copyFileURLToClipboard(salvagedURL)
            onRecordingFinished?(salvagedURL)
            logger.notice("Salvaged partial recording: \(salvagedURL.lastPathComponent, privacy: .public)")
        } else {
            onFinishing?(false)
        }
        fail("Recording stopped unexpectedly: \(error)")
    }

    // MARK: - Clipboard

    /// A real fileURL pasteboard item (not raw data) so the finished movie pastes and
    /// drag-drops as a file -- mirroring the screenshot-to-clipboard UX.
    private func copyFileURLToClipboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.writeObjects([url as NSURL]) {
            fail("Could not copy the recording's file URL to the clipboard")
        }
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
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.pushUI()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private var currentElapsed: TimeInterval {
        accumulatedElapsed + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func pushUI() {
        let elapsedText: String? = uiState == .idle ? nil : Self.formatElapsed(currentElapsed)
        onUIChange?(uiState, elapsedText)
    }

    static func formatElapsed(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func fail(_ message: String) {
        logger.error("\(message, privacy: .public)")
        FeedbackSound.error.play()
        onFailure?()
        PermissionRecovery.noteCaptureFailure()
    }

    private func scale(for display: SCDisplay) -> CGFloat {
        NSScreen.screens.first { $0.cgDirectDisplayID == display.displayID }?.backingScaleFactor ?? 2
    }
}
