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
    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "recording-controller")

    /// Wired by AppDelegate to the status item; pushed on every state/elapsed change.
    var onUIChange: ((UIState, String?) -> Void)?

    private(set) var uiState: UIState = .idle

    /// Guards the selection/starting window so a second hotkey press can't start a
    /// parallel flow (the overlay's own isPresenting guard covers the overlay part).
    private var isStarting = false

    private var accumulatedElapsed: TimeInterval = 0
    private var segmentStart: Date?
    private var elapsedTimer: Timer?

    private static let postHideDelay: Duration = .milliseconds(80)

    init(coordinator: CaptureCoordinator) {
        self.coordinator = coordinator
        engine.onUnexpectedStop = { [weak self] error in
            self?.handleUnexpectedStop(error)
        }
    }

    // MARK: - Flows

    /// Hotkey/menu entry point: starts an interactive recording when idle, stops the
    /// active one otherwise.
    func toggleRecording() async {
        switch uiState {
        case .recording, .paused:
            await stop()
        case .idle:
            await beginInteractive()
        }
    }

    /// Records the entire display under the mouse pointer (menu action).
    func recordFullScreen() async {
        guard uiState == .idle, !isStarting else { return }
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
    /// pop the selection overlay while the app is trying to quit.
    func stopForTermination() async {
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
            NSSound.beep()
        case .recording:
            engine.pause()
            accumulatedElapsed += segmentStart.map { Date().timeIntervalSince($0) } ?? 0
            segmentStart = nil
            stopElapsedTimer()
            uiState = .paused
            pushUI()
        case .paused:
            engine.resume()
            segmentStart = Date()
            startElapsedTimer()
            uiState = .recording
            pushUI()
        }
    }

    // MARK: - Start

    private func beginInteractive() async {
        guard uiState == .idle, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

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
            let directory = try RecordingSettings.outputDirectory()
            let url = RecordingSettings.uniqueOutputURL(in: directory, date: Date())
            try await engine.start(target: target, settings: settings, outputURL: url)

            accumulatedElapsed = 0
            segmentStart = Date()
            startElapsedTimer()
            uiState = .recording
            pushUI()
        } catch {
            fail("Recording start failed: \(error)")
        }
    }

    // MARK: - Stop

    private func stop() async {
        stopElapsedTimer()
        segmentStart = nil
        uiState = .idle

        do {
            let url = try await engine.stop()
            pushUI()
            copyFileURLToClipboard(url)
            CaptureFeedback.playCaptureSound()
            logger.notice("Recording finished: \(url.lastPathComponent, privacy: .public)")
        } catch {
            pushUI()
            fail("Recording stop/finalize failed: \(error)")
        }
    }

    private func handleUnexpectedStop(_ error: Error) {
        stopElapsedTimer()
        segmentStart = nil
        accumulatedElapsed = 0
        uiState = .idle
        pushUI()
        // The engine already salvaged the partial file into ~/Movies/camcord.
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
        NSSound.beep()
        PermissionRecovery.noteCaptureFailure()
    }

    private func scale(for display: SCDisplay) -> CGFloat {
        NSScreen.screens.first { $0.cgDirectDisplayID == display.displayID }?.backingScaleFactor ?? 2
    }
}
