import AVFoundation
import CoreMedia
import Testing

@testable import Camcord

@Suite("AudioTrackMixer")
struct AudioTrackMixerTests {

    private func tempURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("camcord-mixer-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    /// Builds a `.mov` with one video track and `audioTrackCount` audio tracks, each a
    /// constant tone, ~`seconds` long. Returns the URL (caller deletes).
    private func makeMovie(audioTrackCount: Int, seconds: Double, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let fps: Int32 = 30
        let width = 160, height = 120

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        var audioInputs: [AVAssetWriterInput] = []
        for _ in 0..<audioTrackCount {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInputs.append(input)
        }

        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        // Video: a handful of solid frames.
        let frameCount = Int(Double(fps) * seconds)
        for i in 0..<frameCount {
            while !videoInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let pts = CMTime(value: CMTimeValue(i), timescale: fps)
            if let buffer = Self.pixelBuffer(width: width, height: height) {
                adaptor.append(buffer, withPresentationTime: pts)
            }
        }
        videoInput.markAsFinished()

        // Audio: constant tone chunks per track.
        let sampleRate = 48_000.0
        let chunkFrames = 1024
        let totalFrames = Int(sampleRate * seconds)
        for (index, input) in audioInputs.enumerated() {
            var frame = 0
            let tone: Float = index == 0 ? 0.2 : 0.15
            while frame < totalFrames {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                let count = min(chunkFrames, totalFrames - frame)
                if let sample = Self.audioSampleBuffer(startFrame: frame, frames: count, sampleRate: sampleRate, value: tone) {
                    input.append(sample)
                }
                frame += count
            }
            input.markAsFinished()
        }

        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    private static func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            memset(base, 0x44, CVPixelBufferGetBytesPerRow(pb) * height)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    private static func audioSampleBuffer(startFrame: Int, frames: Int, sampleRate: Double, value: Float) -> CMSampleBuffer? {
        let channels = 2
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDesc
        ) == noErr, let formatDesc else { return nil }

        let byteCount = frames * channels * MemoryLayout<Float>.size
        let samples = [Float](repeating: value, count: frames * channels)
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let copied = samples.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Float>.size * channels
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDesc,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    @Test("two audio tracks are collapsed into one, video and duration preserved")
    func mixesTwoTracksIntoOne() async throws {
        let source = tempURL(ext: "mov")
        defer { try? FileManager.default.removeItem(at: source) }
        try await makeMovie(audioTrackCount: 2, seconds: 1.0, to: source)

        let before = AVURLAsset(url: source)
        let beforeAudio = try await before.loadTracks(withMediaType: .audio)
        #expect(beforeAudio.count == 2)
        let beforeDuration = try await before.load(.duration)

        try await AudioTrackMixer.mixInPlace(url: source, fileType: .mov)

        let after = AVURLAsset(url: source)
        let afterAudio = try await after.loadTracks(withMediaType: .audio)
        let afterVideo = try await after.loadTracks(withMediaType: .video)
        #expect(afterAudio.count == 1)          // the two tracks became one
        #expect(afterVideo.count == 1)          // video preserved
        let afterDuration = try await after.load(.duration)
        // Duration within ~0.2s (encoder priming / fragment rounding).
        #expect(abs(afterDuration.seconds - beforeDuration.seconds) < 0.2)
    }

    @Test("a single-audio-track file is left untouched (notNeeded)")
    func singleTrackIsNotNeeded() async throws {
        let source = tempURL(ext: "mov")
        defer { try? FileManager.default.removeItem(at: source) }
        try await makeMovie(audioTrackCount: 1, seconds: 0.5, to: source)

        do {
            try await AudioTrackMixer.mixInPlace(url: source, fileType: .mov)
            Issue.record("expected MixError.notNeeded for a single-audio-track file")
        } catch AudioTrackMixer.MixError.notNeeded {
            // Expected: nothing to mix.
        }
    }
}
