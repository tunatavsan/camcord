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

    /// Builds a real movie whose audio tracks contain constant stereo PCM before AAC
    /// encoding. Each video track carries a distinct transform and title metadata.
    private func makeMovie(
        audioValues: [Double],
        videoTransforms: [CGAffineTransform] = [.identity],
        seconds: Double,
        to url: URL
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let fps: Int32 = 30
        let width = 160
        let height = 120

        var videoInputs: [(AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor)] = []
        for (index, transform) in videoTransforms.enumerated() {
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            input.transform = transform
            let title = AVMutableMetadataItem()
            title.identifier = .commonIdentifierTitle
            title.value = "video-\(index)" as NSString
            input.metadata = [title]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ]
            )
            guard writer.canAdd(input) else { throw MixerTestError.writerSetup }
            writer.add(input)
            videoInputs.append((input, adaptor))
        }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        var audioInputs: [AVAssetWriterInput] = []
        for _ in audioValues {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw MixerTestError.writerSetup }
            writer.add(input)
            audioInputs.append(input)
        }

        guard writer.startWriting() else { throw MixerTestError.writer(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(Double(fps) * seconds)
        for (trackIndex, pair) in videoInputs.enumerated() {
            for frame in 0..<frameCount {
                while !pair.0.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                let pts = CMTime(value: CMTimeValue(frame), timescale: fps)
                guard let buffer = Self.pixelBuffer(width: width, height: height, fill: UInt8(0x22 + trackIndex * 0x33)),
                      pair.1.append(buffer, withPresentationTime: pts)
                else { throw MixerTestError.append }
            }
            pair.0.markAsFinished()
        }

        let sampleRate = 48_000.0
        let chunkFrames = 1_024
        let totalFrames = Int(sampleRate * seconds)
        for (trackIndex, input) in audioInputs.enumerated() {
            var frame = 0
            while frame < totalFrames {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                let count = min(chunkFrames, totalFrames - frame)
                let value = audioValues[trackIndex]
                let sample = try AudioTestPCM.make(
                    channels: [
                        [Double](repeating: value, count: count),
                        [Double](repeating: value, count: count),
                    ],
                    sampleRate: sampleRate,
                    presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(sampleRate))
                )
                guard input.append(sample) else { throw MixerTestError.append }
                frame += count
            }
            input.markAsFinished()
        }

        await writer.finishWriting()
        guard writer.status == .completed else { throw MixerTestError.writer(writer.error) }
    }

    private static func pixelBuffer(width: Int, height: Int, fill: UInt8) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, Int32(fill), CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    private func decodedAudioLevels(at url: URL) async throws -> (rms: Double, peak: Double, finite: Bool) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MixerTestError.missingTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        )
        guard reader.canAdd(output) else { throw MixerTestError.reader }
        reader.add(output)
        guard reader.startReading() else { throw MixerTestError.reader }

        var sumSquares = 0.0
        var sampleCount = 0
        var peak = 0.0
        var finite = true
        while let sampleBuffer = output.copyNextSampleBuffer() {
            for value in try AudioTestPCM.decode(sampleBuffer).channels.flatMap({ $0 }) {
                finite = finite && value.isFinite
                if value.isFinite {
                    sumSquares += value * value
                    peak = max(peak, abs(value))
                    sampleCount += 1
                }
            }
        }
        guard reader.status == .completed, sampleCount > 0 else { throw MixerTestError.reader }
        return (sqrt(sumSquares / Double(sampleCount)), peak, finite)
    }

    private func videoEvidence(
        _ tracks: [AVAssetTrack]
    ) async throws -> (titles: Set<String>, transforms: Set<TransformKey>, samples: Int) {
        var titles: Set<String> = []
        var transforms: Set<TransformKey> = []
        var samples = 0
        for track in tracks {
            transforms.insert(TransformKey(try await track.load(.preferredTransform)))
            let metadata = try await track.load(.metadata)
            for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle) {
                if let title = try await item.load(.stringValue) { titles.insert(title) }
            }

            guard let asset = track.asset else { throw MixerTestError.missingTrack }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { throw MixerTestError.reader }
            reader.add(output)
            guard reader.startReading() else { throw MixerTestError.reader }
            if output.copyNextSampleBuffer() != nil { samples += 1 }
            reader.cancelReading()
        }
        return (titles, transforms, samples)
    }

    private struct TransformKey: Hashable {
        let values: [Int]
        init(_ transform: CGAffineTransform) {
            values = [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
                .map { Int(($0 * 1_000).rounded()) }
        }
    }

    @Test("mix uses unity source volume and preserves every video track's transform, metadata, and samples")
    func unityMixAndMultipleVideoTracks() async throws {
        let source = tempURL(ext: "mov")
        defer { try? FileManager.default.removeItem(at: source) }
        let transforms: [CGAffineTransform] = [
            .identity,
            CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 120, ty: 0),
        ]
        try await makeMovie(audioValues: [0.20, 0.15], videoTransforms: transforms, seconds: 0.6, to: source)
        let before = AVURLAsset(url: source)
        let beforeDuration = try await before.load(.duration)

        try await AudioTrackMixer.mixInPlace(url: source, fileType: .mov)

        let after = AVURLAsset(url: source)
        let audioTracks = try await after.loadTracks(withMediaType: .audio)
        let videoTracks = try await after.loadTracks(withMediaType: .video)
        let evidence = try await videoEvidence(videoTracks)
        let audio = try await decodedAudioLevels(at: source)
        #expect(audioTracks.count == 1)
        #expect(videoTracks.count == 2)
        #expect(evidence.titles == ["video-0", "video-1"])
        #expect(evidence.transforms == Set(transforms.map(TransformKey.init)))
        #expect(evidence.samples == 2)
        #expect(try await after.load(.duration) == beforeDuration)
        #expect(audio.finite)
        // 0.20 + 0.15 at unity is ~0.35; the former per-track 0.707 gain is ~0.247.
        #expect(audio.rms > 0.30)
        #expect(audio.rms < 0.40)
    }

    @Test("near-full-scale summed tracks are finite and peak protected after real AAC decode")
    func summedPeakProtection() async throws {
        let source = tempURL(ext: "mov")
        defer { try? FileManager.default.removeItem(at: source) }
        try await makeMovie(audioValues: [0.75, 0.75], seconds: 0.5, to: source)

        try await AudioTrackMixer.mixInPlace(url: source, fileType: .mov)
        let levels = try await decodedAudioLevels(at: source)

        #expect(levels.finite)
        #expect(levels.rms > 0.70)
        #expect(levels.rms < 0.96)
        // AAC can overshoot the PCM ceiling slightly after decode, but must remain safe.
        #expect(levels.peak < 1.02)
    }

    @Test("a failed mix leaves the original bytes untouched")
    func failurePreservesOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("camcord-mixer-readonly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("original.mov")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try await makeMovie(audioValues: [0.2, 0.1], seconds: 0.3, to: source)
        let before = try Data(contentsOf: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        do {
            try await AudioTrackMixer.mixInPlace(url: source, fileType: .mov)
            Issue.record("expected the read-only destination directory to reject the temporary mix")
        } catch {
            #expect(try Data(contentsOf: source) == before)
        }
    }

    @Test("a single audio track reports that mixing is unnecessary")
    func singleTrackIsNotNeeded() async throws {
        let source = tempURL(ext: "mov")
        defer { try? FileManager.default.removeItem(at: source) }
        try await makeMovie(audioValues: [0.2], seconds: 0.3, to: source)

        do {
            try await AudioTrackMixer.mixInPlace(url: source, fileType: .mov)
            Issue.record("expected MixError.notNeeded for a single-audio-track file")
        } catch AudioTrackMixer.MixError.notNeeded {
            // Expected.
        }
    }

    private enum MixerTestError: Error {
        case writerSetup
        case writer(Error?)
        case append
        case missingTrack
        case reader
    }
}
