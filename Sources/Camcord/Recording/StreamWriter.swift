import AVFoundation
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import os

/// The recording hot path: receives `CMSampleBuffer`s from all three `SCStream`
/// outputs and appends them to an `AVAssetWriter` with soft-pause retiming.
///
/// CONFINEMENT INVARIANT: every method except `init` is called ONLY on the single
/// serial `sampleHandlerQueue` that all three `addStreamOutput` registrations share
/// (`RecordingEngine` dispatches `pause`/`resume`/`markFinished` onto that same
/// queue). That single-queue confinement is what makes the mutable writer/clock state
/// safe -- the `@unchecked Sendable` below asserts exactly that invariant and nothing
/// more.
final class StreamWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "stream-writer")

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?
    private let hostTimeProvider: @Sendable () -> CMTime
    private let frameDuration: CMTime

    private var pauseClock: PauseClock
    private var sessionStarted = false
    private var isFinished = false
    private var didLogWriterFailure = false

    let outputURL: URL
    private let systemAudioProcessor = AudioSampleProcessor()
    private let microphoneProcessor = AudioSampleProcessor()
    private var systemGainDB: Double
    private var microphoneGainDB: Double
    private var health: RecordingHealth
    private let cameraSource: (any CameraFrameSource)?
    private var cameraOptions: CameraOptions
    private var cameraCompositor: CameraCompositor?
    private var cameraCompositingFailed = false
    private var latestScreenSample: CMSampleBuffer?
    private let cameraIdleThreshold: CMTime
    private var lastScreenHostTime: CMTime = .invalid
    /// Maps command-time host boundaries onto the SCK source timeline. The first
    /// complete screen sample establishes the epoch; elapsed time comes from the same
    /// monotonic host clock used for camera cadence.
    private var sourceClockAnchor: (source: CMTime, host: CMTime)?
    /// The latest complete screen received during the initial cue gate. Static
    /// screens may emit no second complete frame, so resume retimes this one frame
    /// to the exact release boundary instead of producing an empty recording.
    private var initialGateFrame: CMSampleBuffer?
    private var isAwaitingInitialRelease: Bool
    private var lastCameraPTS: CMTime = .invalid
    private var lastAppendedMediaEnd: CMTime = .invalid
    private var lastStageTime: CMTime = .invalid
    var stageSink: (@Sendable (PixelBufferBox) -> Void)? {
        didSet { lastStageTime = .invalid }
    }
    var onCameraFailure: (@Sendable () -> Void)?

    func updateCameraOptions(_ options: CameraOptions) {
        cameraOptions = options.resolved()
    }

    func updateAudioGains(systemDB: Double, microphoneDB: Double) {
        systemGainDB = systemDB.isFinite ? min(12, max(-60, systemDB)) : 0
        microphoneGainDB = microphoneDB.isFinite ? min(24, max(-24, microphoneDB)) : 0
    }

    func healthSnapshot() -> RecordingHealth { health }

    /// True while the writer can still accept samples. The stream can die (display
    /// reconfiguration) while the writer is perfectly healthy — that's the case the
    /// engine's stream-restart path checks for. `AVAssetWriter.status` is documented
    /// thread-safe to read.
    var isWriting: Bool { writer.status == .writing }

    /// Fired at most once, on the sample queue, the moment the writer transitions to
    /// `.failed` mid-recording (disk full, quota). Without this, SCStream keeps
    /// delivering, the UI keeps counting, and the user records into the void until
    /// they press stop. The engine routes it into the unexpected-stop path.
    var onRuntimeFailure: (@Sendable () -> Void)?

    /// Builds the writer and its inputs and calls `startWriting()`. Throws if the
    /// container can't be created or the writer rejects the settings -- callers use
    /// that to drive the HEVC -> H.264 fallback.
    init(
        outputURL: URL,
        container: VideoContainer,
        codec: VideoCodecChoice,
        bitrateMbps: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        frameDuration: CMTime,
        dynamicRange: DynamicRange,
        includeSystemAudio: Bool,
        includeMicrophone: Bool,
        initiallyPaused: Bool = false,
        systemAudioGainDB: Double = -6,
        microphoneGainDB: Double = 0,
        cameraSource: (any CameraFrameSource)? = nil,
        cameraOptions: CameraOptions = CameraOptions(),
        hostTimeProvider: @escaping @Sendable () -> CMTime = {
            CMClockGetTime(CMClockGetHostTimeClock())
        }
    ) throws {
        // AVAssetWriterInput raises an Objective-C exception for zero dimensions;
        // reject an unavailable window before creating a file or entering AVFoundation.
        guard pixelWidth >= 2, pixelHeight >= 2 else { throw RecordingError.invalidVideoDimensions }
        self.outputURL = outputURL
        self.cameraSource = cameraOptions.enabled ? cameraSource : nil
        self.cameraOptions = cameraOptions.resolved()
        self.hostTimeProvider = hostTimeProvider
        self.frameDuration = frameDuration
        systemGainDB = systemAudioGainDB.isFinite ? min(12, max(-60, systemAudioGainDB)) : 0
        self.microphoneGainDB = microphoneGainDB.isFinite ? min(24, max(-24, microphoneGainDB)) : 0
        health = RecordingHealth(
            systemAudio: AudioSourceHealth(enabled: includeSystemAudio),
            microphone: AudioSourceHealth(enabled: includeMicrophone)
        )
        var initialClock = PauseClock(frameDuration: frameDuration)
        if initiallyPaused { initialClock.pause() }
        pauseClock = initialClock
        isAwaitingInitialRelease = initiallyPaused
        cameraIdleThreshold = CMTimeMultiplyByRatio(frameDuration, multiplier: 3, divisor: 2)

        writer = try AVAssetWriter(outputURL: outputURL, fileType: container.fileType)
        // Crash resilience: periodically flush a movie fragment (moof) to disk so a
        // process crash / power loss / force-quit mid-recording leaves a PLAYABLE file
        // up to the last fragment, instead of a moov-less, totally unreadable loss.
        // A normal finishWriting() still consolidates into a clean, flat file — this only
        // pays off on the abnormal-exit path. 5s bounds the worst-case loss to the tail.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        let videoSettings: [String: Any] = {
            var settings: [String: Any] = [
                AVVideoCodecKey: codec.avCodec,
                AVVideoWidthKey: pixelWidth,
                AVVideoHeightKey: pixelHeight,
            ]
            // nil for HDR (see colorProperties): the source buffers' own tags flow
            // into the bitstream instead of being force-redeclared.
            if let colorProperties = codec.colorProperties(dynamicRange: dynamicRange) {
                settings[AVVideoColorPropertiesKey] = colorProperties
            }
            if let compressionProperties = codec.compressionProperties(bitrateMbps: bitrateMbps) {
                settings[AVVideoCompressionPropertiesKey] = compressionProperties
            }
            return settings
        }()

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000,
        ]

        // System audio and microphone arrive with different CMFormatDescriptions on
        // independent clocks -- they must be SEPARATE inputs (interleaving them into
        // one corrupts the container). The finished file has 1 video + up to 2 audio
        // tracks; players mix them automatically.
        if includeSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            systemAudioInput = input
        } else {
            systemAudioInput = nil
        }

        if includeMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            microphoneInput = input
        } else {
            microphoneInput = nil
        }

        for input in [videoInput, systemAudioInput, microphoneInput].compactMap({ $0 }) {
            guard writer.canAdd(input) else {
                throw RecordingError.writerRejectedInput
            }
            writer.add(input)
        }

        super.init()

        guard writer.startWriting() else {
            throw RecordingError.writerFailed(writer.error)
        }
    }

    // MARK: - SCStreamOutput (called on the shared sampleHandlerQueue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        consume(sampleBuffer, of: type)
    }

    /// The same sample-queue entry point for captured and synthetic media. Keeping the
    /// writer independent of SCStream ownership makes its file lifecycle checkable.
    func consume(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // A stray buffer that lands after markFinished() (most plausible on the
        // abrupt didStopWithError path, where nothing drained the stream) must not
        // reach an already-finished input — that's an uncaught NSException.
        guard !isFinished else { return }
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            handleAudio(sampleBuffer, input: systemAudioInput, microphone: false)
        case .microphone:
            handleAudio(sampleBuffer, input: microphoneInput, microphone: true)
        @unknown default:
            break
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        // SCStream delivers .idle/incomplete frames routinely; only .complete frames
        // carry displayable pixels.
        guard
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachmentsArray.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw),
            status == .complete
        else {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let receivedAtHostTime = hostTimeProvider()
        lastScreenHostTime = receivedAtHostTime
        if sourceClockAnchor == nil, pts.isNumeric {
            sourceClockAnchor = (pts, receivedAtHostTime)
        }

        if isAwaitingInitialRelease {
            if cameraSource != nil {
                latestScreenSample = sampleBuffer
            } else {
                initialGateFrame = sampleBuffer
            }
            return
        }

        if cameraSource != nil { latestScreenSample = sampleBuffer }
        appendVideoFrame(sampleBuffer)
    }

    /// SCK can emit only idle frames for a static desktop. Once the stream has been
    /// quiet for 1.5 frame intervals, reuse its latest complete screen so a talking
    /// head keeps moving. Live SCK frames always own their native cadence.
    func cameraTick(at hostTime: CMTime? = nil) {
        let hostTime = hostTime ?? hostTimeProvider()
        guard !isFinished, cameraOptions.enabled,
              let sample = latestScreenSample, let anchor = sourceClockAnchor else { return }
        let pts = CMTimeAdd(anchor.source, CMTimeSubtract(hostTime, anchor.host))
        guard !lastScreenHostTime.isNumeric
                || CMTimeSubtract(hostTime, lastScreenHostTime) > cameraIdleThreshold else { return }
        guard !lastCameraPTS.isValid || pts > lastCameraPTS else { return }
        guard let timed = retimed(sample, to: pts) else { return }
        appendVideoFrame(timed)
    }

    @discardableResult
    private func appendVideoFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // An idle duplicate can race a delayed real SCK callback. Keep the newest
        // screen for future repeats, but never append source time behind the frame
        // already accepted into the camera-enabled video track.
        if cameraSource != nil, lastCameraPTS.isValid, pts <= lastCameraPTS { return false }
        guard let retimedPTS = pauseClock.shouldAppend(pts: pts, isVideo: true, duration: CMSampleBufferGetDuration(sampleBuffer)) else { return false }

        if !sessionStarted {
            // Video is the clock master: the session is anchored to the first video
            // buffer, and PauseClock has already dropped any audio that came earlier.
            writer.startSession(atSourceTime: retimedPTS)
            sessionStarted = true
        }

        health.video.delivered += 1
        guard videoInput.isReadyForMoreMediaData else {
            health.video.dropped += 1
            return false
        }
        var output = sampleBuffer
        if cameraOptions.enabled, !cameraCompositingFailed, let camera = cameraSource?.latestFrame() {
            do {
                if cameraCompositor == nil { cameraCompositor = CameraCompositor() }
                output = try cameraCompositor!.composite(screen: sampleBuffer, camera: camera, options: cameraOptions)
            } catch CameraCompositorError.poolExhausted {
                // Encoder backpressure is temporary. Skip this video frame instead
                // of permanently disabling the camera or flashing a camera-less frame.
                health.video.dropped += 1
                return false
            } catch {
                cameraCompositingFailed = true
                logger.error("Camera composition failed; screen capture continues: \(String(describing: error), privacy: .public)")
                onCameraFailure?()
            }
        }
        if let stageSink {
            let now = hostTimeProvider()
            if !lastStageTime.isValid || CMTimeSubtract(now, lastStageTime) >= CMTime(value: 1, timescale: 10),
               let pixels = CMSampleBufferGetImageBuffer(output) {
                lastStageTime = now
                stageSink(PixelBufferBox(pixels))
            }
        }
        if append(output, retimedTo: retimedPTS, originalPTS: pts, input: videoInput) {
            health.video.appended += 1
            if cameraSource != nil { lastCameraPTS = pts }
            return true
        } else {
            health.video.dropped += 1
            return false
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer, input: AVAssetWriterInput?, microphone: Bool) {
        guard let input, sessionStarted else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let retimedPTS = pauseClock.shouldAppend(pts: pts, isVideo: false, duration: CMSampleBufferGetDuration(sampleBuffer)) else { return }
        var source = microphone ? health.microphone : health.systemAudio
        defer {
            if microphone { health.microphone = source } else { health.systemAudio = source }
        }
        source.samples.delivered += 1
        do {
            let processor = microphone ? microphoneProcessor : systemAudioProcessor
            let processed = try processor.process(sampleBuffer, gainDB: microphone ? microphoneGainDB : systemGainDB)
            source.levels = processed.levels
            source.lastSampleUptime = ProcessInfo.processInfo.systemUptime
            if append(processed.sampleBuffer, retimedTo: retimedPTS, originalPTS: pts, input: input) {
                source.samples.appended += 1
            } else {
                source.samples.dropped += 1
            }
        } catch {
            source.samples.dropped += 1
            if !source.processingFailed {
                logger.error("Audio processing failed (microphone=\(microphone)): \(String(describing: error), privacy: .public)")
            }
            source.processingFailed = true
        }
    }

    @discardableResult
    private func append(_ sampleBuffer: CMSampleBuffer, retimedTo retimedPTS: CMTime, originalPTS: CMTime, input: AVAssetWriterInput) -> Bool {
        guard writer.status == .writing else {
            reportWriterFailureIfNeeded()
            return false
        }
        // Realtime rule: never block the capture queue waiting for the encoder.
        guard input.isReadyForMoreMediaData else { return false }

        let buffer = retimedPTS == originalPTS ? sampleBuffer : retimed(sampleBuffer, to: retimedPTS)
        guard let buffer else { return false }
        let accepted = input.append(buffer)
        if accepted {
            let sampleDuration = CMSampleBufferGetDuration(buffer)
            let acceptedDuration = sampleDuration.isNumeric && sampleDuration > .zero
                ? sampleDuration
                : (input === videoInput ? frameDuration : .zero)
            let end = acceptedDuration > .zero
                ? CMTimeAdd(retimedPTS, acceptedDuration)
                : retimedPTS
            if !lastAppendedMediaEnd.isValid || end > lastAppendedMediaEnd {
                lastAppendedMediaEnd = end
            }
        }
        if !accepted { reportWriterFailureIfNeeded() }
        return accepted
    }

    private func reportWriterFailureIfNeeded() {
        guard writer.status == .failed, !didLogWriterFailure else { return }
        didLogWriterFailure = true
        logger.error("AVAssetWriter failed mid-recording: \(String(describing: self.writer.error), privacy: .public)")
        onRuntimeFailure?()
    }

    private func retimed(_ sampleBuffer: CMSampleBuffer, to newPTS: CMTime) -> CMSampleBuffer? {
        // A single CMSampleTimingInfo entry covering N samples must carry the
        // PER-SAMPLE duration (CoreMedia derives sample i's PTS by adding it i
        // times). Audio buffers batch hundreds of PCM frames per callback, so
        // CMSampleBufferGetDuration -- the TOTAL across all samples -- would inflate
        // every sample's spacing N-fold and break audio PTS monotonicity after a
        // resume. Reuse the source buffer's own first timing entry (already
        // per-sample) and swap only the PTS.
        var timing = CMSampleTimingInfo()
        if CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing) != noErr {
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            if numSamples > 0 {
                timing.duration = CMTimeMultiplyByRatio(CMSampleBufferGetDuration(sampleBuffer), multiplier: 1, divisor: Int32(numSamples))
            } else {
                timing.duration = CMSampleBufferGetDuration(sampleBuffer)
            }
        }
        timing.presentationTimeStamp = newPTS
        timing.decodeTimeStamp = .invalid
        var retimedBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimedBuffer
        )
        guard status == noErr else {
            logger.error("CMSampleBufferCreateCopyWithNewTiming failed: \(status)")
            return nil
        }
        return retimedBuffer
    }

    // MARK: - Pause / finish (dispatched onto the sampleHandlerQueue by the engine)

    func pause() {
        pause(atHostTime: hostTimeProvider())
    }

    /// Installs ScreenCaptureKit's authoritative source↔host clock mapping. The
    /// engine calls this after startCapture succeeds; direct writer tests and older
    /// fallback paths can still establish an approximate anchor from the first frame.
    func synchronizeSourceClock(sourceTime: CMTime, hostTime: CMTime) {
        guard !sessionStarted, sourceTime.isNumeric, hostTime.isNumeric else { return }
        sourceClockAnchor = (sourceTime, hostTime)
    }

    func pause(atHostTime hostTime: CMTime) {
        guard let sourceTime = sourceTime(atHostTime: hostTime) else {
            pauseClock.pause()
            return
        }
        pauseClock.pause(atSourceTime: sourceTime)
    }

    func resume() {
        resume(atHostTime: hostTimeProvider())
    }

    func resume(atHostTime hostTime: CMTime) {
        let resumeUptime = ProcessInfo.processInfo.systemUptime
        if health.systemAudio.enabled { health.systemAudio.lastSampleUptime = resumeUptime }
        if health.microphone.enabled { health.microphone.lastSampleUptime = resumeUptime }
        guard let sourceTime = sourceTime(atHostTime: hostTime) else {
            pauseClock.resume()
            isAwaitingInitialRelease = false
            initialGateFrame = nil
            return
        }
        pauseClock.resume(atSourceTime: sourceTime)
        guard isAwaitingInitialRelease else { return }
        isAwaitingInitialRelease = false
        defer { initialGateFrame = nil }
        guard cameraSource == nil,
              let initialGateFrame,
              let boundaryFrame = retimed(initialGateFrame, to: sourceTime)
        else { return }
        appendVideoFrame(boundaryFrame)
    }

    /// Marks all inputs finished. Runs on the sample queue (FIFO with the output
    /// callbacks), and `isFinished` hard-stops any buffer that still arrives after --
    /// so nothing can append past this point regardless of SCStream's delivery
    /// ordering guarantees.
    func markFinished() {
        markFinished(atHostTime: hostTimeProvider())
    }

    func markFinished(atHostTime hostTime: CMTime?) {
        guard !isFinished else { return }
        isFinished = true
        latestScreenSample = nil
        initialGateFrame = nil
        guard writer.status == .writing else { return }
        let endTime: CMTime? = if let hostTime,
                                  let sourceTime = sourceTime(atHostTime: hostTime) {
            pauseClock.endTime(atSourceTime: sourceTime)
        } else if lastAppendedMediaEnd.isValid {
            lastAppendedMediaEnd
        } else {
            nil
        }
        if sessionStarted, let endTime {
            // finishWriting alone truncates the movie at the latest appended sample.
            // An explicit end retains elapsed static-screen time without encoding copies.
            writer.endSession(atSourceTime: endTime)
        }
        for input in [videoInput, systemAudioInput, microphoneInput].compactMap({ $0 }) {
            input.markAsFinished()
        }
    }

    private func sourceTime(atHostTime hostTime: CMTime) -> CMTime? {
        guard hostTime.isNumeric, let anchor = sourceClockAnchor, anchor.host.isNumeric else { return nil }
        return CMTimeAdd(anchor.source, CMTimeSubtract(hostTime, anchor.host))
    }

    /// Thread-safe by AVFoundation contract; called from the engine after the
    /// `markFinished` barrier has run on the sample queue (so `sessionStarted` reads
    /// here are ordered after every append).
    func finishWriting() async throws -> URL {
        // Late stop/recovery paths may converge here. A completed file is immutable;
        // repeat finalization must return it, never remove the user's recording.
        if writer.status == .completed { return outputURL }
        guard sessionStarted else {
            // Zero complete frames were ever delivered (sub-frame recording, or the
            // stream only produced .idle frames). Finishing a session-less writer
            // fails it anyway, and either outcome leaves an unplayable/empty file —
            // cancel, remove the stray file, and report "nothing captured" instead
            // of a false success. (cancelWriting is documented for .writing only —
            // a .failed writer needs no cancel, just the file cleanup.)
            if writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: outputURL)
            throw RecordingError.nothingCaptured
        }
        // A failed tail does not prove earlier movie fragments are unreadable.
        // Preserve the only copy for recovery and report an incomplete recording.
        guard writer.status == .writing else {
            throw RecordingError.incompleteRecording(outputURL, writer.error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RecordingError.incompleteRecording(outputURL, writer.error)
        }
        return outputURL
    }
}

// MARK: - Codec choice

/// Owns BOTH sides of the color contract: the capture-side pixel format/color space
/// on `SCStreamConfiguration` and the encode-side codec/color properties on the
/// writer input. Keeping them in one type is what guarantees they stay matched.
///
/// The user-facing codec lineup (persisted in `RecordingSettings`):
///  • H.264 — 8-bit, maximum compatibility.
///  • HEVC (H.265) — 10-bit P3, the efficient high-quality default.
///  • ProRes 422 Proxy / LT / 422 / HQ and ProRes 4444 — near-lossless, quality-based,
///    large; the "use the whole machine" production masters. Hardware-encoded on Apple
///    Silicon. Higher tiers = higher data rate + quality.
enum VideoCodecChoice: String, Codable, CaseIterable {
    case h264
    case hevc
    case proResProxy
    case proResLT
    case proRes422
    case proResHQ
    case proRes4444

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .proResProxy: .proRes422Proxy
        case .proResLT: .proRes422LT
        case .proRes422: .proRes422
        case .proResHQ: .proRes422HQ
        case .proRes4444: .proRes4444
        }
    }

    var isProRes: Bool {
        switch self {
        case .h264, .hevc: false
        default: true
        }
    }

    /// SDR capture: HEVC + ProRes capture 10-bit P3; H.264 stays 8-bit sRGB.
    /// (HDR capture bypasses these — the engine uses the SCK HDR preset there.)
    var pixelFormat: OSType {
        self == .h264 ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_ARGB2101010LEPacked
    }

    var colorSpaceName: CFString {
        self == .h264 ? CGColorSpace.sRGB : CGColorSpace.displayP3
    }

    /// Writer-side color tags. CRITICAL: the declared transfer function must match the
    /// curve the capture ACTUALLY carries — sRGB/displayP3 buffers hold the sRGB (IEC
    /// 61966-2-1) curve, and declaring ITU_R_709_2 instead makes VideoToolbox silently
    /// re-curve every frame to BT.709 and tag it so; players then decode per BT.1886
    /// (~gamma 2.4) and the recording plays back darker/contrastier than the screen.
    ///
    /// HDR returns nil ON PURPOSE: the SCK HDR preset decides the real transfer (PQ or
    /// HLG); redeclaring here force-retags the data (PQ-as-HLG = blown-out brightness).
    /// Omission makes VideoToolbox propagate the source buffers' own tags losslessly —
    /// the same choice every shipping SCK recorder makes for its HDR path.
    func colorProperties(dynamicRange: DynamicRange) -> [String: Any]? {
        if dynamicRange == .hdr, self != .h264 { return nil }
        if self == .h264 {
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        }
        // SDR HEVC/ProRes: 10-bit Display P3 capture (P3 primaries, sRGB curve).
        // The explicit set stays (an RGB source has no YCbCr matrix attachment to
        // propagate) — only the transfer function differs from plain 709.
        return [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
    }

    /// Compression properties for this codec at the given bitrate (Mbps; 0 = auto).
    /// ProRes is quality-based and ignores bitrate.
    func compressionProperties(bitrateMbps: Int) -> [String: Any]? {
        var props: [String: Any] = [:]
        switch self {
        case .hevc:
            // The HEVC path captures 10-bit; without an explicit Main10 profile the
            // encoder may default to 8-bit Main and silently truncate.
            props[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        case .h264:
            // High profile: better compression efficiency than the default Main/Baseline.
            props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        default:
            break  // ProRes is quality-based
        }
        if bitrateMbps > 0, !isProRes {
            props[AVVideoAverageBitRateKey] = bitrateMbps * 1_000_000
        }
        return props.isEmpty ? nil : props
    }

    /// Degrade one tier on start failure: any ProRes → HEVC → H.264 → give up. (A
    /// ProRes failure on Apple Silicon is systemic, so all tiers would fail alike —
    /// jump straight to HEVC rather than walking every ProRes variant.)
    var fallback: VideoCodecChoice? {
        switch self {
        case .proResProxy, .proResLT, .proRes422, .proResHQ, .proRes4444: .hevc
        case .hevc: .h264
        case .h264: nil
        }
    }
}

/// Output container. `.mp4` is the most broadly compatible for sharing/upload;
/// `.mov` is Apple-native and required for ProRes.
enum VideoContainer: String, Codable, CaseIterable {
    case mov
    case mp4

    var fileType: AVFileType {
        switch self {
        case .mov: .mov
        case .mp4: .mp4
        }
    }

    var ext: String { rawValue }
}

enum RecordingError: Error {
    case invalidVideoDimensions
    case writerRejectedInput
    case writerFailed(Error?)
    case alreadyRecording
    case notRecording
    /// The recording ended before a single complete video frame was written.
    case nothingCaptured
    /// A failed recording is kept because completed movie fragments may be recoverable.
    case incompleteRecording(URL, Error?)
}
