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
        case region(RegionClamp.Result, SCDisplay)
        case window(SCWindow)
        case display(SCDisplay, scale: CGFloat)
    }

    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "recording-engine")

    private let sampleQueue = DispatchQueue(label: "dev.tavsan.camcord.recording.samples")

    private var stream: SCStream?
    private var streamWriter: StreamWriter?
    private var delegateRelay: StreamDelegateRelay?

    var isRecording: Bool { stream != nil }

    /// Called (on the main actor) when the stream dies out from under us -- display
    /// unplugged, TCC revoked mid-flight. The URL is the salvaged partial file in
    /// ~/Movies/camcord (nil when nothing could be salvaged).
    var onUnexpectedStop: ((URL?, Error) -> Void)?

    // MARK: - Start

    func start(target: Target, settings: RecordingSettings, outputURL: URL) async throws {
        guard stream == nil else { throw RecordingError.alreadyRecording }

        let initialCodec = settings.codec
        do {
            try await attemptStart(target: target, settings: settings, outputURL: outputURL, codec: initialCodec)
        } catch {
            guard let fallback = initialCodec.fallback else { throw error }
            logger.error("\(String(describing: initialCodec), privacy: .public) start failed, retrying with fallback: \(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: outputURL)
            do {
                try await attemptStart(target: target, settings: settings, outputURL: outputURL, codec: fallback)
            } catch {
                // The fallback attempt can fail AFTER its StreamWriter already
                // created the on-disk container (e.g. addStreamOutput throws) --
                // same junk-cleanup rule as the primary attempt.
                try? FileManager.default.removeItem(at: outputURL)
                throw error
            }
        }
    }

    private func attemptStart(target: Target, settings: RecordingSettings, outputURL: URL, codec: VideoCodecChoice) async throws {
        // 30 or 60 fps (clamped to a sane range); the video clock's timescale.
        let fps = CMTimeScale(max(1, min(120, settings.fps)))
        let frameDuration = CMTime(value: 1, timescale: fps)
        let (filter, configuration, pixelWidth, pixelHeight) = makeFilterAndConfiguration(
            target: target,
            codec: codec,
            frameDuration: frameDuration,
            resolutionScale: settings.resolutionScale
        )

        configuration.capturesAudio = settings.systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        if settings.microphone {
            configuration.captureMicrophone = true
            configuration.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }

        let writer = try StreamWriter(
            outputURL: outputURL,
            codec: codec,
            bitrateMbps: settings.bitrateMbps,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            frameDuration: frameDuration,
            includeSystemAudio: settings.systemAudio,
            includeMicrophone: settings.microphone
        )

        let relay = StreamDelegateRelay { [weak self] error in
            Task { @MainActor [weak self] in
                await self?.handleUnexpectedStop(error)
            }
        }

        // Disk-full/quota failure surfaces on the writer, not the stream — SCStream
        // keeps happily delivering into a dead writer. Route it like a stream death.
        writer.onRuntimeFailure = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleWriterRuntimeFailure()
            }
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: relay)
        // One shared serial queue for all three outputs = single-threaded confinement
        // for every StreamWriter access (its documented invariant).
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: sampleQueue)
        if settings.systemAudio {
            try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if settings.microphone {
            try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: sampleQueue)
        }

        do {
            try await stream.startCapture()
        } catch {
            sampleQueue.sync { writer.markFinished() }
            try? FileManager.default.removeItem(at: outputURL)
            throw RecordingError.writerFailed(error)
        }

        self.stream = stream
        streamWriter = writer
        delegateRelay = relay
        logger.notice("Recording started (\(pixelWidth)x\(pixelHeight), codec \(String(describing: codec), privacy: .public)) -> \(outputURL.lastPathComponent, privacy: .public)")
    }

    private func makeFilterAndConfiguration(
        target: Target,
        codec: VideoCodecChoice,
        frameDuration: CMTime,
        resolutionScale: ResolutionScale
    ) -> (SCContentFilter, SCStreamConfiguration, Int, Int) {
        let configuration = SCStreamConfiguration()
        configuration.minimumFrameInterval = frameDuration
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.pixelFormat = codec.pixelFormat
        configuration.colorSpaceName = codec.colorSpaceName

        // For .oneX, the output is sized to logical points (SCK downscales from the
        // native source); for .native it is full Retina pixels.
        let filter: SCContentFilter
        let pixelWidth: Int
        let pixelHeight: Int

        switch target {
        case .region(let clamp, let display):
            filter = SCContentFilter(display: display, excludingWindows: [])
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
            let scale = resolutionScale == .native ? CGFloat(filter.pointPixelScale) : 1
            pixelWidth = RegionClamp.evenFloor(filter.contentRect.width * scale)
            pixelHeight = RegionClamp.evenFloor(filter.contentRect.height * scale)

        case .display(let display, let scale):
            filter = SCContentFilter(display: display, excludingWindows: [])
            let effectiveScale = resolutionScale == .native ? scale : 1
            pixelWidth = RegionClamp.evenFloor(CGFloat(display.width) * effectiveScale)
            pixelHeight = RegionClamp.evenFloor(CGFloat(display.height) * effectiveScale)
        }

        configuration.width = pixelWidth
        configuration.height = pixelHeight
        return (filter, configuration, pixelWidth, pixelHeight)
    }

    // MARK: - Pause / resume (confinement: mutate the writer only on its queue)

    func pause() {
        guard let writer = streamWriter else { return }
        sampleQueue.async { writer.pause() }
    }

    func resume() {
        guard let writer = streamWriter else { return }
        sampleQueue.async { writer.resume() }
    }

    // MARK: - Stop

    /// Stops capture and finalizes the file. Returns the finished recording's URL.
    func stop() async throws -> URL {
        guard let stream, let writer = streamWriter else { throw RecordingError.notRecording }
        clearStreamState()

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

        return try await finalize(writer)
    }

    /// SCStream is not Sendable in the 15.x SDK; passing it into the hard-timeout's
    /// detached task is safe here because stopCapture is documented thread-safe and
    /// this engine has already dropped its own reference (clearStreamState).
    private struct StreamBox: @unchecked Sendable {
        let stream: SCStream
        init(_ stream: SCStream) { self.stream = stream }
    }

    private func handleUnexpectedStop(_ error: Error) async {
        guard let writer = streamWriter else { return }
        logger.error("Stream stopped unexpectedly: \(String(describing: error), privacy: .public)")
        clearStreamState()
        // Salvage whatever was written so a long recording isn't lost.
        let salvaged = try? await finalize(writer)
        onUnexpectedStop?(salvaged, error)
    }

    /// The writer went `.failed` mid-recording (disk full, quota). The stream is
    /// still alive but every buffer is now dropped — stop it, remove the unplayable
    /// (moov-less) partial file, and surface the failure like a stream death.
    private func handleWriterRuntimeFailure() {
        guard let stream, let writer = streamWriter else { return }
        logger.error("Writer runtime failure; stopping the orphaned stream")
        clearStreamState()
        Task {
            try? await stream.stopCapture()
            try? FileManager.default.removeItem(at: writer.outputURL)
            onUnexpectedStop?(nil, RecordingError.writerFailed(nil))
        }
    }

    private func finalize(_ writer: StreamWriter) async throws -> URL {
        // Barrier: once markFinished has run on the sample queue, no in-flight append
        // can race finishWriting.
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                writer.markFinished()
                continuation.resume()
            }
        }
        return try await writer.finishWriting()
    }

    private func clearStreamState() {
        stream = nil
        streamWriter = nil
        delegateRelay = nil
    }
}

/// `SCStreamDelegate` calls arrive on an arbitrary queue; this tiny relay is the only
/// nonisolated surface, forwarding the error into a `@Sendable` closure that hops to
/// the main actor. Holds no mutable state -- so whether `SCStream` retains its
/// delegate strongly or weakly (the SDK header doesn't say), an early dealloc merely
/// silences an already-irrelevant callback.
private final class StreamDelegateRelay: NSObject, SCStreamDelegate, Sendable {
    private let onStop: @Sendable (Error) -> Void

    init(onStop: @escaping @Sendable (Error) -> Void) {
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}
