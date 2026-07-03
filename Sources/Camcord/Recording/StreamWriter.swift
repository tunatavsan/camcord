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
        codec: VideoCodecChoice,
        pixelWidth: Int,
        pixelHeight: Int,
        frameDuration: CMTime,
        includeSystemAudio: Bool,
        includeMicrophone: Bool
    ) throws {
        self.outputURL = outputURL
        pauseClock = PauseClock(frameDuration: frameDuration)

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
        ]
        // Capture-side colorSpaceName and these encode-side properties MUST stay
        // matched (VideoCodecChoice owns both) or colors wash out (TN QA1839 / -12917).
        videoSettings[AVVideoColorPropertiesKey] = codec.colorProperties
        if let compressionProperties = codec.compressionProperties {
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
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: newPTS,
            decodeTimeStamp: .invalid
        )
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
            // of a false success.
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw RecordingError.nothingCaptured
        }
        guard writer.status == .writing else {
            throw RecordingError.writerFailed(writer.error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RecordingError.writerFailed(writer.error)
        }
        return outputURL
    }
}

// MARK: - Codec choice

/// Owns BOTH sides of the color contract: the capture-side pixel format/color space
/// on `SCStreamConfiguration` and the encode-side codec/color properties on the
/// writer input. Keeping them in one type is what guarantees they stay matched.
enum VideoCodecChoice {
    case hevc
    case h264

    var avCodec: AVVideoCodecType {
        switch self {
        case .hevc: .hevc
        case .h264: .h264
        }
    }

    var pixelFormat: OSType {
        switch self {
        case .hevc: kCVPixelFormatType_ARGB2101010LEPacked
        case .h264: kCVPixelFormatType_32BGRA
        }
    }

    var colorSpaceName: CFString {
        switch self {
        case .hevc: CGColorSpace.displayP3
        case .h264: CGColorSpace.sRGB
        }
    }

    var colorProperties: [String: Any] {
        switch self {
        case .hevc:
            [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        case .h264:
            [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        }
    }

    /// The HEVC path captures 10-bit (`ARGB2101010LEPacked`); without an explicit
    /// Main10 profile the encoder may default to 8-bit Main and silently truncate.
    var compressionProperties: [String: Any]? {
        switch self {
        case .hevc:
            [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String]
        case .h264:
            nil
        }
    }

    var fallback: VideoCodecChoice? {
        switch self {
        case .hevc: .h264
        case .h264: nil
        }
    }
}

enum RecordingError: Error {
    case writerRejectedInput
    case writerFailed(Error?)
    case alreadyRecording
    case notRecording
    /// The recording ended before a single complete video frame was written.
    case nothingCaptured
}
