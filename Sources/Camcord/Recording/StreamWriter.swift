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

    private var pauseClock: PauseClock
    private var sessionStarted = false
    private var isFinished = false
    private var didLogWriterFailure = false

    let outputURL: URL

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
        includeSystemAudio: Bool,
        includeMicrophone: Bool
    ) throws {
        self.outputURL = outputURL
        pauseClock = PauseClock(frameDuration: frameDuration)

        writer = try AVAssetWriter(outputURL: outputURL, fileType: container.fileType)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
        ]
        // Capture-side colorSpaceName and these encode-side properties MUST stay
        // matched (VideoCodecChoice owns both) or colors wash out (TN QA1839 / -12917).
        videoSettings[AVVideoColorPropertiesKey] = codec.colorProperties
        if let compressionProperties = codec.compressionProperties(bitrateMbps: bitrateMbps) {
            videoSettings[AVVideoCompressionPropertiesKey] = compressionProperties
        }
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
        // A stray buffer that lands after markFinished() (most plausible on the
        // abrupt didStopWithError path, where nothing drained the stream) must not
        // reach an already-finished input — that's an uncaught NSException.
        guard !isFinished else { return }
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            handleAudio(sampleBuffer, input: systemAudioInput)
        case .microphone:
            handleAudio(sampleBuffer, input: microphoneInput)
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
        guard let retimedPTS = pauseClock.shouldAppend(pts: pts, isVideo: true) else { return }

        if !sessionStarted {
            // Video is the clock master: the session is anchored to the first video
            // buffer, and PauseClock has already dropped any audio that came earlier.
            writer.startSession(atSourceTime: retimedPTS)
            sessionStarted = true
        }

        append(sampleBuffer, retimedTo: retimedPTS, originalPTS: pts, input: videoInput)
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer, input: AVAssetWriterInput?) {
        guard let input, sessionStarted else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let retimedPTS = pauseClock.shouldAppend(pts: pts, isVideo: false) else { return }
        append(sampleBuffer, retimedTo: retimedPTS, originalPTS: pts, input: input)
    }

    private func append(_ sampleBuffer: CMSampleBuffer, retimedTo retimedPTS: CMTime, originalPTS: CMTime, input: AVAssetWriterInput) {
        guard writer.status == .writing else {
            if writer.status == .failed, !didLogWriterFailure {
                didLogWriterFailure = true
                logger.error("AVAssetWriter failed mid-recording: \(String(describing: self.writer.error), privacy: .public)")
                onRuntimeFailure?()
            }
            return
        }
        // Realtime rule: never block the capture queue waiting for the encoder.
        guard input.isReadyForMoreMediaData else { return }

        let buffer = retimedPTS == originalPTS ? sampleBuffer : retimed(sampleBuffer, to: retimedPTS)
        guard let buffer else { return }
        input.append(buffer)
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
            timing.duration = CMSampleBufferGetDuration(sampleBuffer)
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
        pauseClock.pause()
    }

    func resume() {
        pauseClock.resume()
    }

    /// Marks all inputs finished. Runs on the sample queue (FIFO with the output
    /// callbacks), and `isFinished` hard-stops any buffer that still arrives after --
    /// so nothing can append past this point regardless of SCStream's delivery
    /// ordering guarantees.
    func markFinished() {
        isFinished = true
        guard writer.status == .writing else { return }
        for input in [videoInput, systemAudioInput, microphoneInput].compactMap({ $0 }) {
            input.markAsFinished()
        }
    }

    /// Thread-safe by AVFoundation contract; called from the engine after the
    /// `markFinished` barrier has run on the sample queue (so `sessionStarted` reads
    /// here are ordered after every append).
    func finishWriting() async throws -> URL {
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
        // Every failure path below leaves a moov-less, unplayable file — remove it
        // rather than leaving junk in ~/Movies/camcord (e.g. disk filled at the
        // exact instant the user pressed stop).
        guard writer.status == .writing else {
            try? FileManager.default.removeItem(at: outputURL)
            throw RecordingError.writerFailed(writer.error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw RecordingError.writerFailed(writer.error)
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

    /// HEVC + ProRes capture 10-bit P3; H.264 stays 8-bit sRGB.
    var pixelFormat: OSType {
        self == .h264 ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_ARGB2101010LEPacked
    }

    var colorSpaceName: CFString {
        self == .h264 ? CGColorSpace.sRGB : CGColorSpace.displayP3
    }

    var colorProperties: [String: Any] {
        if self == .h264 {
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        }
        return [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
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
    case writerRejectedInput
    case writerFailed(Error?)
    case alreadyRecording
    case notRecording
    /// The recording ended before a single complete video frame was written.
    case nothingCaptured
}
