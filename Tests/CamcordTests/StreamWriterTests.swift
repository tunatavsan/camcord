import AVFoundation
import ScreenCaptureKit
import Testing
@testable import Camcord

@Suite("Stream writer file safety")
struct StreamWriterTests {
    @Test("an unavailable window size fails without an Objective-C exception or empty file")
    func rejectsEmptyDimensions() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-invalid-size-\(UUID()).mov")
        #expect(throws: RecordingError.self) {
            _ = try StreamWriter(outputURL: url, container: .mov, codec: .hevc, bitrateMbps: 5,
                pixelWidth: 0, pixelHeight: 340, frameDuration: CMTime(value: 1, timescale: 60),
                dynamicRange: .sdr, includeSystemAudio: false, includeMicrophone: false)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("an initially paused writer excludes cue-era video and microphone callbacks")
    func initialCueGateExcludesDelayedMediaFromEncodedFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-start-cue-gate-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = WriterTestHostClock(CMTime(seconds: 100, preferredTimescale: 600))
        let writer = try StreamWriter(
            outputURL: url, container: .mov, codec: .h264, bitrateMbps: 1,
            pixelWidth: 64, pixelHeight: 48, frameDuration: CMTime(value: 1, timescale: 30),
            dynamicRange: .sdr, includeSystemAudio: false, includeMicrophone: true,
            initiallyPaused: true, hostTimeProvider: { clock.now }
        )
        let cueAudio = Array(repeating: 0.8, count: 1_024)

        // A cue-era frame establishes the source/host mapping but is rejected.
        writer.consume(try videoFrame(index: 300), of: .screen) // source t=10 / host t=100
        writer.consume(try AudioTestPCM.make(
            channels: [cueAudio], presentationTimeStamp: CMTime(seconds: 10.5, preferredTimescale: 48_000)
        ), of: .microphone)

        clock.now = CMTime(seconds: 101, preferredTimescale: 600)
        writer.resume() // source floor = 11

        // These were captured before resume but delivered after its queue barrier.
        writer.consume(try videoFrame(index: 329), of: .screen) // source t=10.967
        // Resume seeds the latest gated complete frame at source t=11. Microphone
        // delivery can lag that accepted screen frame; this cue-era packet must
        // remain excluded even after the writer session has started.
        writer.consume(try AudioTestPCM.make(
            channels: [cueAudio], presentationTimeStamp: CMTime(seconds: 10.98, preferredTimescale: 48_000)
        ), of: .microphone)
        writer.consume(try AudioTestPCM.make(
            channels: [Array(repeating: 0.1, count: 1_024)],
            presentationTimeStamp: CMTime(seconds: 11, preferredTimescale: 48_000)
        ), of: .microphone)
        writer.consume(try videoFrame(index: 331), of: .screen)
        writer.markFinished(atHostTime: CMTime(seconds: 101.1, preferredTimescale: 600))
        _ = try await writer.finishWriting()

        let asset = AVURLAsset(url: url)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(writer.healthSnapshot().video.appended == 2)
        #expect(writer.healthSnapshot().microphone.samples.appended == 1)
    }

    @Test("a static screen with no post-cue complete frame still creates a real movie")
    func initialCueGateSeedsStaticScreenAtReleaseBoundary() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-start-cue-static-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = WriterTestHostClock(CMTime(seconds: 100, preferredTimescale: 600))
        let writer = try StreamWriter(
            outputURL: url, container: .mov, codec: .h264, bitrateMbps: 1,
            pixelWidth: 64, pixelHeight: 48, frameDuration: CMTime(value: 1, timescale: 30),
            dynamicRange: .sdr, includeSystemAudio: false, includeMicrophone: false,
            initiallyPaused: true, hostTimeProvider: { clock.now }
        )

        // The stream clock says source t=10 corresponds to host t=100.
        writer.synchronizeSourceClock(
            sourceTime: CMTime(seconds: 10, preferredTimescale: 600),
            hostTime: CMTime(seconds: 100, preferredTimescale: 600)
        )
        // Simulate delivery latency: receipt time must not replace the stream clock.
        clock.now = CMTime(seconds: 100.5, preferredTimescale: 600)
        // SCK can send this one complete frame, followed only by .idle frames.
        writer.consume(try videoFrame(index: 300), of: .screen) // source t=10 / host t=100
        clock.now = CMTime(seconds: 101, preferredTimescale: 600)
        writer.resume()
        // No further complete video callback arrives.
        writer.markFinished(atHostTime: CMTime(seconds: 102, preferredTimescale: 600))
        _ = try await writer.finishWriting()

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let range = try await track.load(.timeRange)
        #expect(abs(range.start.seconds) < 0.02)
        #expect(abs(range.duration.seconds - 1) < 0.02)
        #expect(writer.healthSnapshot().video.appended == 1)
    }

    @Test("a silent static recording ends at the explicit host boundary")
    func staticRecordingUsesHostBoundary() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-static-end-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let anchorHost = CMTime(seconds: 100, preferredTimescale: 600)
        let writer = try StreamWriter(
            outputURL: url, container: .mov, codec: .h264, bitrateMbps: 1,
            pixelWidth: 64, pixelHeight: 48, frameDuration: CMTime(value: 1, timescale: 30),
            dynamicRange: .sdr, includeSystemAudio: false, includeMicrophone: false,
            hostTimeProvider: { anchorHost }
        )
        writer.consume(try videoFrame(index: 300), of: .screen) // source t=10
        writer.markFinished(atHostTime: CMTime(seconds: 103, preferredTimescale: 600))
        _ = try await writer.finishWriting()

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let trackDuration = try await track.load(.timeRange).duration.seconds
        #expect(abs(duration - 3) < 0.02)
        #expect(abs(trackDuration - 3) < 0.02)
    }

    @Test("explicit pause and resume preserve static active time in the encoded movie")
    func staticTimeAroundPauseIsPreserved() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-static-pause-boundary-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let anchorHost = CMTime(seconds: 100, preferredTimescale: 600)
        let writer = try StreamWriter(
            outputURL: url, container: .mov, codec: .h264, bitrateMbps: 1,
            pixelWidth: 64, pixelHeight: 48, frameDuration: CMTime(value: 1, timescale: 30),
            dynamicRange: .sdr, includeSystemAudio: false, includeMicrophone: false,
            hostTimeProvider: { anchorHost }
        )
        writer.consume(try videoFrame(index: 300), of: .screen) // source t=10
        writer.pause(atHostTime: CMTime(seconds: 102, preferredTimescale: 600))
        writer.resume(atHostTime: CMTime(seconds: 104, preferredTimescale: 600))
        writer.consume(try videoFrame(index: 450), of: .screen) // source t=15 -> output t=13
        writer.markFinished(atHostTime: CMTime(seconds: 105, preferredTimescale: 600))
        _ = try await writer.finishWriting()

        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        // The second frame begins at three active seconds and retains its 1/30 s span.
        #expect(abs(duration - (3 + 1.0 / 30.0)) < 0.02)
    }

    @Test("a frozen stop boundary is not extended by delayed finalization")
    func delayedFinalizationUsesFrozenStopBoundary() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-static-stop-boundary-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = WriterTestHostClock(CMTime(seconds: 100, preferredTimescale: 600))
        let writer = try StreamWriter(
            outputURL: url, container: .mov, codec: .h264, bitrateMbps: 1,
            pixelWidth: 64, pixelHeight: 48, frameDuration: CMTime(value: 1, timescale: 30),
            dynamicRange: .sdr, includeSystemAudio: false, includeMicrophone: false,
            hostTimeProvider: { clock.now }
        )
        writer.consume(try videoFrame(index: 300), of: .screen) // anchor source t=10 / host t=100
        let stopBoundary = CMTime(seconds: 102, preferredTimescale: 600)
        clock.now = CMTime(seconds: 107, preferredTimescale: 600) // simulated stopCapture timeout
        writer.markFinished(atHostTime: stopBoundary)
        // A stream callback arriving during that timeout is rejected by the sealed writer.
        writer.consume(try videoFrame(index: 450), of: .screen)
        _ = try await writer.finishWriting()

        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 2) < 0.02)
        #expect(writer.healthSnapshot().video.appended == 1)
    }

    @Test("finalizing twice preserves the completed recording")
    func completedFileSurvivesDuplicateFinalize() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-writer-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try StreamWriter(
            outputURL: url, container: .mov, codec: .h264, bitrateMbps: 1,
            pixelWidth: 64, pixelHeight: 48, frameDuration: CMTime(value: 1, timescale: 30),
            dynamicRange: .sdr, includeSystemAudio: false, includeMicrophone: false
        )
        for frame in 0..<6 {
            writer.consume(try videoFrame(index: frame), of: .screen)
            try await Task.sleep(for: .milliseconds(5))
        }
        writer.markFinished()
        writer.markFinished()
        writer.consume(try videoFrame(index: 100), of: .screen)
        let first = try await writer.finishWriting()
        #expect(first == url)
        let bytes = try Data(contentsOf: url)
        #expect(!bytes.isEmpty)
        let second = try await writer.finishWriting()
        #expect(second == url)
        #expect(try Data(contentsOf: url) == bytes)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
    }

    @Test("the written movie omits paused time and rejects paused frames")
    func pauseClosesMovieTimeline() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-pause-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = WriterTestHostClock(.zero)
        let writer = try StreamWriter(
            outputURL: url, container: .mov, codec: .h264, bitrateMbps: 1,
            pixelWidth: 64, pixelHeight: 48, frameDuration: CMTime(value: 1, timescale: 30),
            dynamicRange: .sdr, includeSystemAudio: false, includeMicrophone: false,
            hostTimeProvider: { clock.now }
        )
        for frame in 0..<6 {
            writer.consume(try videoFrame(index: frame), of: .screen)
            try await Task.sleep(for: .milliseconds(5))
        }
        clock.now = CMTime(value: 6, timescale: 30)
        writer.pause() // Convenience API must use the injected production clock path.
        writer.consume(try videoFrame(index: 300), of: .screen)
        clock.now = CMTime(value: 600, timescale: 30)
        writer.resume()
        for frame in 600..<606 {
            writer.consume(try videoFrame(index: frame), of: .screen)
            try await Task.sleep(for: .milliseconds(5))
        }
        writer.markFinished()
        _ = try await writer.finishWriting()
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(duration > 0.3 && duration < 0.5)
    }

    @Test("speech resumes over a static desktop and the encoded timeline stays monotonic")
    func staticScreenAudioResume() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-static-audio-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let anchorHost = CMTime(seconds: 100, preferredTimescale: 48_000)
        let writer = try StreamWriter(
            outputURL: url, container: .mov, codec: .h264, bitrateMbps: 1,
            pixelWidth: 64, pixelHeight: 48, frameDuration: CMTime(value: 1, timescale: 30),
            dynamicRange: .sdr, includeSystemAudio: true, includeMicrophone: false,
            hostTimeProvider: { anchorHost }
        )
        writer.consume(try videoFrame(index: 0), of: .screen)
        let channel = Array(repeating: 0.1, count: 1_024)
        for block in 0..<50 {
            let sample = try AudioTestPCM.make(channels: [channel, channel],
                presentationTimeStamp: CMTime(value: Int64(block * 1_024), timescale: 48_000))
            writer.consume(sample, of: .audio)
            try await Task.sleep(for: .milliseconds(10))
        }
        writer.pause(atHostTime: CMTimeAdd(
            anchorHost, CMTime(value: 50 * 1_024, timescale: 48_000)
        ))
        writer.resume(atHostTime: CMTimeAdd(
            anchorHost, CMTime(seconds: 10, preferredTimescale: 48_000)
        ))
        for block in 0..<50 {
            let sample = try AudioTestPCM.make(channels: [channel, channel],
                presentationTimeStamp: CMTime(value: Int64(480_000 + block * 1_024), timescale: 48_000))
            writer.consume(sample, of: .audio)
            try await Task.sleep(for: .milliseconds(10))
        }
        // No changed screen frame has arrived since the initial screenshot.
        #expect(writer.healthSnapshot().systemAudio.samples.appended == 100)
        writer.consume(try videoFrame(index: 332), of: .screen)
        try await Task.sleep(for: .milliseconds(10))
        writer.markFinished()
        _ = try await writer.finishWriting()
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let range = try await track.load(.timeRange)
        #expect(range.duration.seconds > 2 && range.duration.seconds < 2.3)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var previous = CMTime.invalid
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            #expect(!previous.isValid || pts > previous)
            previous = pts
        }
        #expect(reader.status == .completed)
    }

    @Test("resume grants enabled audio sources a fresh health interval")
    func resumeRefreshesAudioHealth() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-resume-health-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try StreamWriter(
            outputURL: url, container: .mov, codec: .h264, bitrateMbps: 1,
            pixelWidth: 64, pixelHeight: 48, frameDuration: CMTime(value: 1, timescale: 30),
            dynamicRange: .sdr, includeSystemAudio: true, includeMicrophone: true
        )
        writer.consume(try videoFrame(index: 0), of: .screen)
        writer.pause()
        writer.resume()

        let health = writer.healthSnapshot()
        let uptime = ProcessInfo.processInfo.systemUptime
        #expect(health.systemAudio.isReceiving(at: uptime))
        #expect(health.microphone.isReceiving(at: uptime))
        writer.markFinished(atHostTime: nil)
        _ = try await writer.finishWriting()
    }

    @MainActor
    @Test("unexpected stream stop salvages through the last accepted media frame")
    func unexpectedStopSalvagesLastAcceptedDuration() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-unexpected-stop-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try StreamWriter(
            outputURL: url, container: .mov, codec: .h264, bitrateMbps: 1,
            pixelWidth: 64, pixelHeight: 48, frameDuration: CMTime(value: 1, timescale: 30),
            dynamicRange: .sdr, includeSystemAudio: false, includeMicrophone: false
        )
        writer.consume(try videoFrame(index: 0), of: .screen)
        writer.consume(try videoFrame(index: 15, duration: .invalid), of: .screen)

        let engine = RecordingEngine()
        let token = UUID()
        engine.streamWriter = writer
        engine.streamToken = token
        var handedOverURL: URL?
        engine.onUnexpectedStop = { url, _ in handedOverURL = url }
        let error = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.systemStoppedStream.rawValue
        )
        await engine.handleUnexpectedStop(error, token: token)

        #expect(handedOverURL == url)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - (0.5 + 1.0 / 30.0)) < 0.02)
    }

    private func videoFrame(
        index: Int,
        duration: CMTime = CMTime(value: 1, timescale: 30)
    ) throws -> CMSampleBuffer {
        var optionalPixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
                                   nil, &optionalPixel) == kCVReturnSuccess)
        let pixel = try #require(optionalPixel)
        CVPixelBufferLockBaseAddress(pixel, [])
        if let base = CVPixelBufferGetBaseAddress(pixel) {
            memset(base, Int32(96 + index), CVPixelBufferGetBytesPerRow(pixel) * 48)
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var optionalFormat: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                    imageBuffer: pixel, formatDescriptionOut: &optionalFormat) == noErr)
        let format = try #require(optionalFormat)
        var timing = CMSampleTimingInfo(duration: duration,
                    presentationTimeStamp: CMTime(value: Int64(index), timescale: 30), decodeTimeStamp: .invalid)
        var optionalSample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                    imageBuffer: pixel, formatDescription: format, sampleTiming: &timing,
                    sampleBufferOut: &optionalSample) == noErr)
        let sample = try #require(optionalSample)
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true))
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        let statusKey = SCStreamFrameInfo.status.rawValue as NSString
        let complete = NSNumber(value: SCFrameStatus.complete.rawValue)
        CFDictionarySetValue(attachment, Unmanaged.passUnretained(statusKey).toOpaque(),
                            Unmanaged.passUnretained(complete).toOpaque())
        return sample
    }
}

private final class WriterTestHostClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CMTime

    init(_ value: CMTime) { self.value = value }

    var now: CMTime {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
