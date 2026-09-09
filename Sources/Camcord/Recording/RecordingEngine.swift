import AppKit
import AVFoundation
@preconcurrency import ScreenCaptureKit
import os

/// Lifecycle owner for one recording at a time: builds the `SCContentFilter` +
/// `SCStreamConfiguration` for the chosen target, starts/stops the `SCStream`, and
/// coordinates the `StreamWriter` (whose hot-path state is confined to the single
/// `sampleHandlerQueue` -- this engine only ever touches it by dispatching onto that
/// queue).
///
/// HEVC is the default codec; if stream/writer setup fails with it, the engine tears
/// down and retries once with H.264 (`VideoCodecChoice.fallback`).
@MainActor
final class RecordingEngine: NSObject {
    /// What to record.
    enum Target {
        /// A clamped region on one display (`RegionClamp` output + the matching SCDisplay).
        case region(RegionClamp.Result, SCDisplay, excluding: SCRunningApplication?)
        case window(SCWindow)
        case display(SCDisplay, scale: CGFloat, excluding: SCRunningApplication?)
    }

    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "recording-engine")

    private let sampleQueue = DispatchQueue(label: "dev.tavsan.camcord.recording.samples", qos: .userInitiated)

    private var stream: SCStream?
    var streamWriter: StreamWriter?
    private var delegateRelay: StreamDelegateRelay?
    /// Each installed stream owns exactly one error callback. Retired streams may
    /// still deliver callbacks after stop/restart; they must never touch a new writer.
    var streamToken: UUID?
    private var writerToken: UUID?
    private var pendingStart: StreamStartAttempt?
    private var startCancelled = false
    private var cameraSource: CameraCapture?
    private var cameraToken: UUID?
    private var cameraTimer: DispatchSourceTimer?
    var onCameraIssue: ((String) -> Void)?

    /// Set at `start()`: whether to collapse the file's two audio tracks into one at
    /// finalize, and which container that file is, so `finalize` can run the mixer.
    private var pendingAudioMix = false
    private var outputFileType: AVFileType = .mov

    var isRecording: Bool { stream != nil }

    /// Called (on the main actor) when the stream dies out from under us -- display
    /// unplugged, TCC revoked mid-flight. The URL is the salvaged partial file in
    /// ~/Movies/camcord (nil when nothing could be salvaged).
    var onUnexpectedStop: ((URL?, Error) -> Void)?

    /// Called (on the main actor) when a dead stream was rebuilt into the same writer
    /// and the recording continued — e.g. after a fullscreen app's display mode switch.
    var onRecovered: (() -> Void)?
    var onAudioMixFailure: ((URL) -> Void)?

    func updateAudioGains(_ settings: RecordingSettings) {
        guard let writer = streamWriter else { return }
        let systemDB = settings.resolvedSystemAudioGainDB
        let microphoneDB = settings.resolvedMicrophoneGainDB
        sampleQueue.async { writer.updateAudioGains(systemDB: systemDB, microphoneDB: microphoneDB) }
    }

    func updateCameraOptions(_ options: CameraOptions) {
        guard let writer = streamWriter else { return }
        sampleQueue.async { writer.updateCameraOptions(options) }
    }

    func healthSnapshot() async -> RecordingHealth? {
        guard let writer = streamWriter else { return nil }
        return await withCheckedContinuation { continuation in
            sampleQueue.async { continuation.resume(returning: writer.healthSnapshot()) }
        }
    }

    /// Everything needed to rebuild the stream after an unexpected death: the logical
    /// target (re-resolved by ID against fresh shareable content), the exact
    /// configuration OBJECT (its width/height/pixel format must keep matching the
    /// writer's fixed inputs), and which outputs to re-attach.
    private struct ActiveSession {
        let target: Target
        let configuration: SCStreamConfiguration
        let systemAudio: Bool
        let microphone: Bool
    }
    private var activeSession: ActiveSession?
    private var restartAttempts = 0
    private var lastRestartAt: Date?

    // MARK: - Start

    func start(
        target: Target,
        settings: RecordingSettings,
        outputURL: URL,
        initiallyPaused: Bool = false,
        preparedCamera: CameraCapture? = nil
    ) async throws {
        guard stream == nil else { throw RecordingError.alreadyRecording }
        startCancelled = false
        var didStart = false
        defer { if !didStart { clearStreamState() } }
        if settings.camera.enabled {
            let token = UUID()
            cameraToken = token
            let source = preparedCamera ?? CameraCapture()
            source.setLossHandler { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.cameraToken == token else { return }
                    self.onCameraIssue?("Kamera bağlantısı kesildi — ekran kaydı sürüyor")
                }
            }
            cameraSource = source
            let options = settings.camera.resolved()
            let fps = settings.fps
            do {
                if preparedCamera == nil {
                    try await withHardTimeout(.seconds(5), onTimeout: CameraCaptureError.didNotStart) {
                        try await source.start(deviceID: options.deviceID, fps: fps)
                        try await source.waitForFirstFrame()
                    }
                }
                guard !startCancelled else { throw CancellationError() }
                CameraPreviewMonitor.shared.useRecordingSource(source)
            } catch {
                cameraSource = nil
                cameraToken = nil
                Task.detached { await source.stop() }
                if startCancelled { throw CancellationError() }
                CameraPreviewMonitor.shared.useRecordingSource(nil)
                onCameraIssue?("Kamera açılamadı — ekran kaydı kamerasız başlayacak")
            }
        }
        guard !startCancelled else { throw CancellationError() }

        // Recorded now (independent of the codec-fallback chain below): whether the
        // finished file's two audio tracks should be mixed into one, and its container.
        pendingAudioMix = settings.shouldMixAudioTracks
        outputFileType = settings.effectiveContainer.fileType

        // Walk the whole fallback chain (ProRes → HEVC → H.264) so a failure shared by
        // the higher-quality codecs still degrades all the way to the most compatible
        // one before giving up, instead of stopping after a single hop.
        var codec: VideoCodecChoice? = settings.resolvedCodec
        var lastError: Error?
        while let current = codec {
            do {
                try await attemptStart(
                    target: target,
                    settings: settings,
                    outputURL: outputURL,
                    codec: current,
                    initiallyPaused: initiallyPaused
                )
                didStart = true
                return
            } catch {
                lastError = error
                // Only an adopted writer can clean its own empty output. A rejected
                // writer may be pointing at an existing file; never delete by path here.
                if case RecordingError.incompleteRecording = error { throw error }
                if startCancelled { throw CancellationError() }
                if let next = current.fallback {
                    logger.error("\(String(describing: current), privacy: .public) start failed, retrying with \(String(describing: next), privacy: .public): \(String(describing: error), privacy: .public)")
                }
                codec = current.fallback
            }
        }
        throw lastError ?? RecordingError.writerFailed(nil)
    }

    private func attemptStart(
        target: Target,
        settings: RecordingSettings,
        outputURL: URL,
        codec: VideoCodecChoice,
        initiallyPaused: Bool
    ) async throws {
        // 30 or 60 fps (clamped to a sane range); the video clock's timescale.
        let fps = CMTimeScale(max(1, min(120, settings.fps)))
        let frameDuration = CMTime(value: 1, timescale: fps)
        let (filter, configuration, pixelWidth, pixelHeight) = makeFilterAndConfiguration(
            target: target,
            codec: codec,
            frameDuration: frameDuration,
            resolutionScale: settings.resolutionScale,
            dynamicRange: settings.dynamicRange
        )

        configuration.showsCursor = settings.showsCursor
        configuration.capturesAudio = settings.systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        if settings.microphone {
            configuration.captureMicrophone = true
            // The chosen input if it's still attached, otherwise the system default —
            // a persisted device ID for an unplugged mic must not be passed through.
            let chosen = settings.microphoneDeviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
            configuration.microphoneCaptureDeviceID = chosen?.uniqueID
                ?? AVCaptureDevice.default(for: .audio)?.uniqueID
        }

        // A quality-based profile (ProRes) carries no bitrate; if it fell back to a
        // bitrate-driven codec (HEVC/H.264), give that codec a real high-quality target
        // instead of "automatic". A custom "auto" (0) stays auto — the user chose it.
        let bitrate: Int
        if settings.resolvedBitrateMbps > 0 {
            bitrate = settings.resolvedBitrateMbps
        } else if !codec.isProRes, settings.profile != .custom {
            bitrate = RecordingProfile.maximum.bitrateMbps
        } else {
            bitrate = 0
        }

        let writer = try StreamWriter(
            outputURL: outputURL,
            container: settings.effectiveContainer,
            codec: codec,
            bitrateMbps: bitrate,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            frameDuration: frameDuration,
            dynamicRange: settings.dynamicRange,
            includeSystemAudio: settings.systemAudio,
            includeMicrophone: settings.microphone,
            initiallyPaused: initiallyPaused,
            systemAudioGainDB: settings.resolvedSystemAudioGainDB,
            microphoneGainDB: settings.resolvedMicrophoneGainDB,
            cameraSource: cameraSource,
            cameraOptions: settings.camera
        )

        let token = UUID()
        let relay = StreamDelegateRelay { [weak self] error in
            Task { @MainActor [weak self] in
                await self?.handleUnexpectedStop(error, token: token)
            }
        }

        // Disk-full/quota failure surfaces on the writer, not the stream — SCStream
        // keeps happily delivering into a dead writer. Route it like a stream death.
        let writerID = UUID()
        writer.onRuntimeFailure = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleWriterRuntimeFailure(token: writerID)
            }
        }

        writer.onCameraFailure = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.writerToken == writerID else { return }
                self.onCameraIssue?("Kamera videoya eklenemedi — önizleme ve ekran kaydı sürüyor")
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: relay)
        do {
            // One shared queue confines all sample and writer mutations.
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: sampleQueue)
            if settings.systemAudio {
                try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: sampleQueue)
            }
            if settings.microphone {
                try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: sampleQueue)
            }
            try await startStream(stream)
            // Apple documents that SCStream output timestamps use this synchronization
            // clock. Convert the same host boundary used by pause/resume before the
            // cue gate opens, avoiding receipt-time error from a delayed first frame.
            if let sourceClock = stream.synchronizationClock {
                let hostTime = Self.currentHostTime()
                let sourceTime = CMSyncConvertTime(
                    hostTime,
                    from: CMClockGetHostTimeClock(),
                    to: sourceClock
                )
                await withCheckedContinuation { continuation in
                    sampleQueue.async {
                        writer.synchronizeSourceClock(sourceTime: sourceTime, hostTime: hostTime)
                        continuation.resume()
                    }
                }
            }
            if let error = relay.stopError { throw error }
            guard writer.isWriting else { throw RecordingError.writerFailed(nil) }
        } catch {
            let originalError = error
            let box = StreamBox(stream)
            // Mark before awaiting stop: a late successful start cannot append past it.
            await withCheckedContinuation { continuation in
                sampleQueue.async { writer.markFinished(atHostTime: nil); continuation.resume() }
            }
            Task.detached { try? await box.stream.stopCapture() }
            do {
                let partial = try await writer.finishWriting()
                throw RecordingError.incompleteRecording(partial, originalError)
            } catch RecordingError.nothingCaptured {
                // The writer removed only the empty file it created. Codec retry is safe.
                throw RecordingError.writerFailed(originalError)
            }
        }

        self.stream = stream
        streamToken = token
        writerToken = writerID
        streamWriter = writer
        if cameraSource != nil {
            cameraTimer = Self.makeCameraTimer(writer: writer, fps: fps, queue: sampleQueue)
        }
        delegateRelay = relay
        activeSession = ActiveSession(
            target: target,
            configuration: configuration,
            systemAudio: settings.systemAudio,
            microphone: settings.microphone
        )
        restartAttempts = 0
        lastRestartAt = nil
        logger.notice("Recording started (\(pixelWidth)x\(pixelHeight), codec \(String(describing: codec), privacy: .public)) -> \(outputURL.lastPathComponent, privacy: .public)")
    }

    /// Kept on the engine's actor so tests exercise the same callback-registration
    /// boundary as a real camera-enabled start, using the actual Dispatch timer.
    static func makeCameraTimer(writer: StreamWriter, fps: CMTimeScale, queue: DispatchQueue) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1 / Double(fps), leeway: .milliseconds(1))
        // DispatchSource's legacy callback can inherit MainActor from registration.
        // It executes on sampleQueue: explicitly Sendable prevents that inherited
        // actor check and keeps all per-frame work off the UI executor.
        timer.setEventHandler { @Sendable in writer.cameraTick() }
        timer.resume()
        return timer
    }

    private func makeFilterAndConfiguration(
        target: Target,
        codec: VideoCodecChoice,
        frameDuration: CMTime,
        resolutionScale: ResolutionScale,
        dynamicRange: DynamicRange
    ) -> (SCContentFilter, SCStreamConfiguration, Int, Int) {
        let configuration: SCStreamConfiguration
        if dynamicRange == .hdr && codec != .h264 {
            // Apple's matched HDR combo (10-bit pixel format + color space +
            // captureDynamicRange). Hand-setting the fields individually leaves
            // captureDynamicRange at .sdr and the writer then tags SDR pixels as HLG.
            // LOCAL display, not canonical: we capture and play back on the same
            // screen (WWDC24 10088); canonical normalizes for cross-device sharing
            // and blows out brightness when watched locally.
            configuration = SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)
        } else {
            configuration = SCStreamConfiguration()
            configuration.pixelFormat = codec.pixelFormat
            configuration.colorSpaceName = codec.colorSpaceName
        }
        configuration.minimumFrameInterval = frameDuration
        configuration.queueDepth = 6

        // For .oneX, the output is sized to logical points (SCK downscales from the
        // native source); for .native it is full Retina pixels.
        let filter: SCContentFilter
        let pixelWidth: Int
        let pixelHeight: Int

        switch target {
        case .region(let clamp, let display, let excluding):
            let apps = excluding.map { [$0] } ?? []
            filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
            configuration.sourceRect = clamp.sourceRect
            switch resolutionScale {
            case .native:
                pixelWidth = clamp.pixelWidth
                pixelHeight = clamp.pixelHeight
            case .oneX:
                pixelWidth = RegionClamp.evenFloor(clamp.clampedRegion.width)
                pixelHeight = RegionClamp.evenFloor(clamp.clampedRegion.height)
            }

        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            // The writer's dimensions are fixed for the whole file, but the window
            // isn't: when the user resizes it mid-recording, SCK must rescale the
            // content into the surface (aspect-preserving letterbox) instead of
            // leaving the revealed area black at the old size.
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true

            // ScreenCaptureKit bug: full-screen exclusive games often report their logical size as
            // their physical size (e.g., 3024x1964 instead of 1512x982), but pointPixelScale stays 2.0.
            // Multiplying by 2 would double-scale the video to 6048x3928, causing the game to sit in the corner.
            // SCWindow.frame is CG space (top-left origin); NSScreen.frame is AppKit
            // space — convert before intersecting or secondary displays mismatch.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let windowFrameAppKit = Geometry.cgToAppKit(window.frame, primaryScreenHeight: primaryHeight)
            let intersectedScreens = NSScreen.screens.filter { $0.frame.intersects(windowFrameAppKit) }
            let screen = intersectedScreens.first ?? NSScreen.main
            let screenLogicalWidth = screen?.frame.width ?? 0
            let screenBackingScale = screen?.backingScaleFactor ?? 1.0

            let isAbnormallyWide = intersectedScreens.count <= 1 && filter.contentRect.width > screenLogicalWidth + 10
            let isScaleMismatch = CGFloat(filter.pointPixelScale) > screenBackingScale
            let isDoubleScaledBug = isAbnormallyWide || isScaleMismatch

            let effectiveScale = isDoubleScaledBug ? 1.0 : CGFloat(filter.pointPixelScale)
            let physicalWidth = filter.contentRect.width * effectiveScale
            let physicalHeight = filter.contentRect.height * effectiveScale

            if resolutionScale == .native {
                pixelWidth = RegionClamp.evenFloor(physicalWidth)
                pixelHeight = RegionClamp.evenFloor(physicalHeight)
            } else {
                let logicalScale = isDoubleScaledBug ? screenBackingScale : CGFloat(filter.pointPixelScale)
                pixelWidth = RegionClamp.evenFloor(physicalWidth / logicalScale)
                pixelHeight = RegionClamp.evenFloor(physicalHeight / logicalScale)
            }

        case .display(let display, let scale, let excluding):
            let apps = excluding.map { [$0] } ?? []
            filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
            // SCDisplay.width/.height are LOGICAL POINTS (e.g. 1800×1169 on a 2x Retina
            // MacBook whose native panel is 3600×2338). For .native, multiply by the
            // screen's backingScaleFactor to get physical pixels. For .oneX, use them
            // directly — they ARE the 1x logical size.
            let effectiveScale = resolutionScale == .native ? scale : 1.0
            pixelWidth = RegionClamp.evenFloor(display.frame.width * effectiveScale)
            pixelHeight = RegionClamp.evenFloor(display.frame.height * effectiveScale)
        }

        configuration.width = pixelWidth
        configuration.height = pixelHeight
        return (filter, configuration, pixelWidth, pixelHeight)
    }

    // MARK: - Pause / resume (confinement: mutate the writer only on its queue)

    func pause() {
        guard let writer = streamWriter else { return }
        let hostTime = Self.currentHostTime()
        sampleQueue.async { writer.pause(atHostTime: hostTime) }
    }

    func resume() {
        guard let writer = streamWriter else { return }
        let hostTime = Self.currentHostTime()
        sampleQueue.async { writer.resume(atHostTime: hostTime) }
    }

    // MARK: - Stop

    /// Stops capture and finalizes the file. Returns the finished recording's URL.
    func stop() async throws -> URL {
        guard let stream, let writer = streamWriter else { throw RecordingError.notRecording }
        // Freeze the user's Stop boundary before the potentially five-second SCK wait.
        // Finalization must never turn stopCapture latency into recorded static tail time.
        let stopHostTime = Self.currentHostTime()
        // Drop the engine's references BEFORE any await: a late didStopWithError /
        // writer-failure callback landing mid-finalize must see streamWriter == nil,
        // or it finalizes the same writer a second time and deletes the finished file.
        clearStreamState()

        // Seal the writer on its owning queue before asking SCK to stop. The stop call can
        // time out after five seconds; callbacks arriving during that wait must not append
        // beyond the user-command boundary. finalize() repeats this idempotently.
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                writer.markFinished(atHostTime: stopHostTime)
                continuation.resume()
            }
        }

        do {
            // stopCapture is the same continuation-bridged replayd round-trip the
            // rest of the app refuses to trust unbounded (see HardTimeout) -- a
            // wedged replayd here would otherwise hang stop() and, on the quit
            // path, leave Cmd-Q permanently unanswered. On timeout we abandon the
            // stream and still finalize: markFinished() hard-stops any late buffers.
            let box = StreamBox(stream)
            try await withHardTimeout(.seconds(5), onTimeout: RecordingError.writerFailed(nil)) {
                try await box.stream.stopCapture()
            }
        } catch {
            // Already-stopped streams throw; the writer finalize below still salvages the file.
            logger.notice("stopCapture threw or timed out (continuing to finalize): \(String(describing: error), privacy: .public)")
        }

        return try await finalize(writer, endHostTime: stopHostTime)
    }

    /// SCStream is not Sendable in the 15.x SDK; passing it into the hard-timeout's
    /// detached task is safe here because stopCapture is documented thread-safe and
    /// this engine has already dropped its own reference (clearStreamState).
    private struct StreamBox: @unchecked Sendable {
        let stream: SCStream
        init(_ stream: SCStream) { self.stream = stream }
    }

    /// Cancels an in-flight start without blocking the main actor. A late successful
    /// ScreenCaptureKit start is explicitly stopped by its owner instead of orphaned.
    func cancelPendingStart() {
        startCancelled = true
        pendingStart?.abandon()
    }

    private func startStream(_ stream: SCStream) async throws {
        guard !startCancelled else { throw CancellationError() }
        let attempt = StreamStartAttempt(stream)
        pendingStart = attempt
        defer { if pendingStart === attempt { pendingStart = nil } }
        do {
            try await withHardTimeout(.seconds(5), onTimeout: CaptureError.timeout) {
                try await attempt.start()
            }
            guard !startCancelled else { throw CancellationError() }
        } catch {
            attempt.abandon()
            throw error
        }
    }

    func handleUnexpectedStop(_ error: Error, token: UUID) async {
        guard streamToken == token, let writer = streamWriter else { return }
        streamToken = nil // duplicate delivery from this stream is now inert
        logger.error("Stream stopped unexpectedly: \(String(describing: error), privacy: .public)")
        // OBS-style resilience: a display reconfiguration (fullscreen app alt-tab, mode
        // switch, Space teardown) kills the STREAM while the writer is still healthy.
        // Rebuild the stream into the same writer and keep the recording alive; only
        // end the recording when a restart is hopeless or fails.
        if writer.isWriting, shouldAttemptRestart(after: error), let session = activeSession {
            // A display transition may still be in progress when the first rebuild
            // runs. Retry this failure with bounded backoff, checking ownership at
            // every suspension so a user Stop always wins over recovery.
            while restartAttempts < 3, streamWriter === writer {
                do {
                    if restartAttempts > 0 {
                        try await Task.sleep(for: .milliseconds(250 * restartAttempts))
                    }
                    guard streamWriter === writer else { return }
                    if try await restartCapture(session, writer: writer) {
                        logger.notice("Stream restarted after unexpected stop (attempt \(self.restartAttempts))")
                        onRecovered?()
                    }
                    return
                } catch {
                    guard streamWriter === writer else { return }
                    logger.error("Stream restart failed: \(String(describing: error), privacy: .public)")
                    guard shouldAttemptRestart(after: error) else { break }
                }
            }
        }
        guard streamWriter === writer else { return }
        clearStreamState()
        // Salvage whatever was written so a long recording isn't lost.
        do {
            let salvaged = try await finalize(writer)
            await waitForPendingMixes()
            onUnexpectedStop?(salvaged, error)
        } catch RecordingError.incompleteRecording(let url, let underlying) {
            onUnexpectedStop?(url, underlying ?? error)
        } catch {
            onUnexpectedStop?(nil, error)
        }
    }

    /// Restart only when it can plausibly succeed: never against a TCC revocation
    /// (preflight fails) and never in a tight crash-loop — 3 attempts, with the
    /// counter forgiven after 30s of stable capture so a long session can survive
    /// many well-spaced reconfigurations.
    private func shouldAttemptRestart(after error: Error) -> Bool {
        guard CGPreflightScreenCaptureAccess() else { return false }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain {
            switch SCStreamError.Code(rawValue: nsError.code) {
            case .systemStoppedStream,   // macOS 15 catch-all for "died out from under us" (display reconfiguration)
                 .attemptToStartStreamState, .attemptToStopStreamState,
                 .attemptToUpdateFilterState, .attemptToConfigState,
                 .noDisplayList, .noCaptureSource:
                break   // transient — worth a retry
            default:
                // userStopped (system UI stop = intentional), userDeclined (TCC
                // revoked), entitlement/parameter errors… retrying can't help.
                return false
            }
        }
        if let last = lastRestartAt, Date().timeIntervalSince(last) > 30 {
            restartAttempts = 0
        }
        return restartAttempts < 3
    }

    /// Rebuilds filter + stream around the SAME writer/configuration. Returns false when
    /// the session ended (user stop) while rebuilding — the orphan stream is discarded.
    private func restartCapture(_ session: ActiveSession, writer: StreamWriter) async throws -> Bool {
        restartAttempts += 1
        lastRestartAt = Date()

        // Old SCDisplay/SCWindow handles are stale after a reconfiguration — re-resolve
        // by ID against fresh content. Bounded like every other SCK call in the app.
        let content = try await withHardTimeout(.seconds(3), onTimeout: CaptureError.timeout) {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        guard streamWriter === writer else { return false }
        let ownApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let excluded = ownApp.map { [$0] } ?? []

        let filter: SCContentFilter
        switch session.target {
        case .display(let old, _, _):
            guard let display = content.displays.first(where: { $0.displayID == old.displayID }) else {
                throw RecordingError.writerFailed(nil)   // display unplugged — salvage
            }
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        case .region(_, let old, _):
            // sourceRect and output size persist on the reused configuration object.
            guard let display = content.displays.first(where: { $0.displayID == old.displayID }) else {
                throw RecordingError.writerFailed(nil)
            }
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        case .window(let old):
            guard let window = content.windows.first(where: { $0.windowID == old.windowID }) else {
                throw RecordingError.writerFailed(nil)   // window closed — nothing to resume
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let token = UUID()
        let relay = StreamDelegateRelay { [weak self] error in
            Task { @MainActor [weak self] in
                await self?.handleUnexpectedStop(error, token: token)
            }
        }
        let stream = SCStream(filter: filter, configuration: session.configuration, delegate: relay)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: sampleQueue)
        if session.systemAudio {
            try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if session.microphone {
            try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: sampleQueue)
        }
        try await startStream(stream)
        if let error = relay.stopError { throw error }

        // stop() may have ended the session during the awaits above (it nils
        // streamWriter before its first await) — discard the orphan, change nothing.
        guard streamWriter === writer else {
            let box = StreamBox(stream)
            Task.detached { try? await box.stream.stopCapture() }
            return false
        }
        self.stream = stream
        streamToken = token
        self.delegateRelay = relay
        return true
    }

    /// Stop a failed writer's live stream and retain completed movie fragments.
    private func handleWriterRuntimeFailure(token: UUID) {
        guard writerToken == token, let stream, let writer = streamWriter else { return }
        logger.error("Writer runtime failure; stopping the orphaned stream")
        clearStreamState()
        Task {
            let box = StreamBox(stream)
            try? await withHardTimeout(.seconds(5), onTimeout: CaptureError.timeout) {
                try await box.stream.stopCapture()
            }
            // Movie fragments may contain the only surviving copy of a long session.
            // Preserve it even when AVFoundation cannot finalize the trailing fragment.
            do {
                let url = try await finalize(writer)
                await waitForPendingMixes()
                onUnexpectedStop?(url, RecordingError.incompleteRecording(url, nil))
            } catch RecordingError.incompleteRecording(let url, let underlying) {
                onUnexpectedStop?(url, underlying ?? RecordingError.incompleteRecording(url, nil))
            } catch {
                onUnexpectedStop?(nil, error)
            }
        }
    }

    private var finalizations: [ObjectIdentifier: Task<URL, Error>] = [:]
    var isFinalizing: Bool { !finalizations.isEmpty || isMixing }

    private func finalize(_ writer: StreamWriter, endHostTime: CMTime? = nil) async throws -> URL {
        let id = ObjectIdentifier(writer)
        if let existing = finalizations[id] { return try await existing.value }
        let shouldMix = pendingAudioMix
        let fileType = outputFileType
        // Salvage has no user Stop boundary: nil ends at the last accepted media.
        let task = Task { @MainActor in
            // Snapshot the output policy before suspending: late stop/recovery callers
            // must never apply a future recording's settings to this file.
            await withCheckedContinuation { continuation in
                sampleQueue.async {
                    writer.markFinished(atHostTime: endHostTime)
                    continuation.resume()
                }
            }
            let url = try await writer.finishWriting()
            if shouldMix { startBackgroundAudioMix(url: url, fileType: fileType) }
            return url
        }
        finalizations[id] = task
        defer { finalizations[id] = nil }
        return try await task.value
    }

    private static func currentHostTime() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    // MARK: - Asynchronous audio mix

    /// In-flight background mixes, keyed by id so several can overlap and all be awaited
    /// on the app-termination path (a Cmd-Q right after stopping still gets the mixed file).
    private var pendingMixes: [Int: Task<Void, Never>] = [:]
    private var nextMixID = 0

    /// True while any background audio mix is still running.
    var isMixing: Bool { !pendingMixes.isEmpty }

    private func startBackgroundAudioMix(url: URL, fileType: AVFileType) {
        let id = nextMixID
        nextMixID += 1
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await AudioTrackMixer.mixInPlace(url: url, fileType: fileType)
            } catch AudioTrackMixer.MixError.notNeeded {
                // The file ended up with a single audio track — nothing to mix.
            } catch {
                self.logger.error("Audio mix failed; keeping the multi-track recording: \(String(describing: error), privacy: .public)")
                self.onAudioMixFailure?(url)
            }
            self.pendingMixes[id] = nil
        }
        pendingMixes[id] = task
    }

    /// Waits before publishing final file actions and before application termination.
    /// Capture and UI work remain free to run while the audio pass completes.
    func waitForPendingMixes() async {
        // An unexpected-stop salvage can still be writing its movie container when
        // the user presses Stop or Quit. Its mix only exists after that task completes.
        for task in Array(finalizations.values) { _ = try? await task.value }
        for task in Array(pendingMixes.values) {
            await task.value
        }
    }

    private func clearStreamState() {
        streamToken = nil
        writerToken = nil
        pendingStart?.abandon()
        cameraToken = nil
        cameraTimer?.cancel()
        cameraTimer = nil
        if let source = cameraSource { Task.detached { await source.stop() } }
        cameraSource = nil
        CameraPreviewMonitor.shared.useRecordingSource(nil)
        stream = nil
        streamWriter = nil
        delegateRelay = nil
        activeSession = nil
    }
}

/// Owns the late-completion cleanup of a non-cooperative ScreenCaptureKit start.
private final class StreamStartAttempt: @unchecked Sendable {
    private let stream: SCStream
    private let abandoned = OSAllocatedUnfairLock(initialState: false)

    init(_ stream: SCStream) { self.stream = stream }

    func start() async throws {
        try await stream.startCapture()
        if abandoned.withLock({ $0 }) {
            try? await stream.stopCapture()
            throw CancellationError()
        }
    }

    func abandon() {
        let first = abandoned.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
        if first {
            Task.detached { [self] in try? await stream.stopCapture() }
        }
    }
}

/// Error delivery can precede startCapture's return. The lock retains that error for
/// the caller; later callbacks additionally carry the installed stream's identity.
private final class StreamDelegateRelay: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let onStop: @Sendable (Error) -> Void
    private let errorStorage = OSAllocatedUnfairLock<Error?>(initialState: nil)

    var stopError: Error? { errorStorage.withLock { $0 } }

    init(onStop: @escaping @Sendable (Error) -> Void) {
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        errorStorage.withLock { $0 = error }
        onStop(error)
    }
}
