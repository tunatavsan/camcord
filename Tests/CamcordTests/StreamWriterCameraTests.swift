import AVFoundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import Testing
import os

@testable import Camcord

@Suite("Stream writer camera cadence", .serialized)
struct StreamWriterCameraTests {
    @MainActor
    @Test("the engine's real camera timer runs off the main actor and writes playable frames")
    func engineCameraTimerExecutorBoundary() async throws {
        let url = temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = FakeCameraFrameSource(try pixelBuffer(width: 80, height: 60, color: .red))
        let options = CameraOptions(enabled: true, corner: .bottomRight, widthFraction: 0.30, mirrored: false)
        let writer = try makeWriter(url: url, source: source, options: options)
        // Seed the immutable screen before the timer owns subsequent writer work.
        writer.consume(try screenSample(pts: CMTime(value: 100, timescale: 30)), of: .screen)
        let queue = DispatchQueue(label: "dev.tavsan.camcord.test.camera-timer")
        let timer = RecordingEngine.makeCameraTimer(writer: writer, fps: 30, queue: queue)
        defer { timer.cancel() }

        var appended = 0
        let deadline = ContinuousClock.now + .seconds(2)
        while appended < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(35))
            appended = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: writer.healthSnapshot().video.appended) }
            }
        }
        timer.cancel()
        await withCheckedContinuation { continuation in
            queue.async { writer.markFinished(); continuation.resume() }
        }
        #expect(appended >= 3)
        _ = try await writer.finishWriting()
        let frames = try await decodedFrames(at: url)
        #expect(frames.count >= 3)
        #expect(try #require(frames.last).color(atCI: CGPoint(x: 260, y: 48)).isMostlyRed)
    }

    @Test("camera ticks keep a static screen moving and encode the newest camera frame")
    func staticScreenUsesLatestCameraFrame() async throws {
        let url = temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let source = FakeCameraFrameSource(try pixelBuffer(width: 80, height: 60, color: .red))
        let options = CameraOptions(enabled: true, corner: .bottomRight, widthFraction: 0.30, mirrored: false)
        let hostAnchor = CMTime(seconds: 100, preferredTimescale: 600)
        let writer = try makeWriter(
            url: url, source: source, options: options, hostTimeProvider: { hostAnchor }
        )
        writer.consume(try screenSample(pts: CMTime(value: 100, timescale: 30)), of: .screen)

        for tick in 0..<24 {
            if tick == 12 {
                source.update(try pixelBuffer(width: 80, height: 60, color: .green))
            }
            writer.cameraTick(at: CMTimeAdd(hostAnchor, CMTime(value: Int64(tick), timescale: 30)))
            try await Task.sleep(for: .milliseconds(35))
        }

        writer.markFinished()
        _ = try await writer.finishWriting()

        let frames = try await decodedFrames(at: url)
        #expect(frames.count == 23)
        let first = try #require(frames.first)
        let last = try #require(frames.last)
        let cameraPoint = CGPoint(x: 260, y: 48)
        let screenPoint = CGPoint(x: 40, y: 90)
        #expect(first.color(atCI: cameraPoint).isMostlyRed)
        #expect(last.color(atCI: cameraPoint).isMostlyGreen)
        #expect(first.color(atCI: screenPoint).isMostlyBlue)
        #expect(last.color(atCI: screenPoint).isMostlyBlue)

        let gaps = zip(frames, frames.dropFirst()).map { CMTimeSubtract($1.pts, $0.pts).seconds }
        #expect(abs(try #require(gaps.first) - 2.0 / 30.0) < 0.002)
        #expect(gaps.dropFirst().allSatisfy { abs($0 - 1.0 / 30.0) < 0.002 })
        #expect(CMTimeSubtract(last.pts, first.pts).seconds > 0.74)
    }

    @Test("live screen callbacks append immediately and the timer waits for an idle interval")
    func liveScreenOwnsCadenceUntilIdle() async throws {
        let url = temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = FakeCameraFrameSource(try pixelBuffer(width: 80, height: 60, color: .red))
        let options = CameraOptions(enabled: true, corner: .bottomRight, widthFraction: 0.30, mirrored: false)
        let hostAnchor = CMTime(seconds: 100, preferredTimescale: 600)
        let writer = try makeWriter(
            url: url, source: source, options: options, hostTimeProvider: { hostAnchor }
        )

        writer.consume(try screenSample(pts: CMTime(value: 100, timescale: 30)), of: .screen)
        #expect(writer.healthSnapshot().video.appended == 1)
        writer.cameraTick(at: CMTimeAdd(hostAnchor, CMTime(value: 1, timescale: 30)))
        #expect(writer.healthSnapshot().video.appended == 1)
        writer.cameraTick(at: CMTimeAdd(hostAnchor, CMTime(value: 2, timescale: 30)))
        #expect(writer.healthSnapshot().video.appended == 2)
        // A real callback delivered after that idle repeat may carry an older PTS.
        // It refreshes the cached screen but must not regress the encoded timeline.
        writer.consume(try screenSample(pts: CMTime(value: 101, timescale: 30)), of: .screen)
        #expect(writer.healthSnapshot().video.appended == 2)
        writer.cameraTick(at: CMTimeAdd(hostAnchor, CMTime(value: 3, timescale: 30)))
        #expect(writer.healthSnapshot().video.appended == 3)

        writer.markFinished(atHostTime: nil)
        _ = try await writer.finishWriting()
    }

    @Test("disabling camera stops compositing on subsequent live screen frames")
    func disablingCameraStopsBurnIn() async throws {
        let url = temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = FakeCameraFrameSource(try pixelBuffer(width: 80, height: 60, color: .red))
        var options = CameraOptions(enabled: true, corner: .bottomRight, widthFraction: 0.30, mirrored: false)
        let writer = try makeWriter(url: url, source: source, options: options)

        writer.consume(try screenSample(pts: CMTime(value: 100, timescale: 30)), of: .screen)
        options.enabled = false
        writer.updateCameraOptions(options)
        writer.consume(try screenSample(pts: CMTime(value: 101, timescale: 30)), of: .screen)
        writer.markFinished(atHostTime: nil)
        _ = try await writer.finishWriting()

        let frames = try await decodedFrames(at: url)
        #expect(frames.count == 2)
        let cameraPoint = CGPoint(x: 260, y: 48)
        #expect(try #require(frames.first).color(atCI: cameraPoint).isMostlyRed)
        #expect(try #require(frames.last).color(atCI: cameraPoint).isMostlyBlue)
    }

    @Test("moving and resizing the live camera changes already-running video frames")
    func liveCameraPlacement() async throws {
        let url = temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = FakeCameraFrameSource(try pixelBuffer(width: 80, height: 60, color: .red))
        var options = CameraOptions(enabled: true, corner: .bottomRight, widthFraction: 0.30, mirrored: false)
        let writer = try makeWriter(url: url, source: source, options: options)
        writer.consume(try screenSample(pts: CMTime(value: 100, timescale: 30)), of: .screen)
        let anchor = CMClockGetTime(CMClockGetHostTimeClock())
        for tick in 0..<12 {
            if tick == 6 {
                options.position = CameraPosition(x: 0, y: 1)
                options.widthFraction = 0.4
                writer.updateCameraOptions(options)
            }
            writer.cameraTick(at: CMTimeAdd(anchor, CMTime(value: Int64(tick), timescale: 30)))
            try await Task.sleep(for: .milliseconds(35))
        }
        writer.markFinished()
        _ = try await writer.finishWriting()
        let frames = try await decodedFrames(at: url)
        let first = try #require(frames.first), last = try #require(frames.last)
        #expect(first.color(atCI: CGPoint(x: 260, y: 48)).isMostlyRed)
        #expect(last.color(atCI: CGPoint(x: 260, y: 48)).isMostlyBlue)
        #expect(first.color(atCI: CGPoint(x: 65, y: 130)).isMostlyBlue)
        #expect(last.color(atCI: CGPoint(x: 65, y: 130)).isMostlyRed)
    }

    @Test("paused camera ticks are omitted and resume without an encoded gap")
    func pauseCollapsesCameraTimeline() async throws {
        let url = temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let source = FakeCameraFrameSource(try pixelBuffer(width: 80, height: 60, color: .red))
        let options = CameraOptions(enabled: true, corner: .bottomLeft, widthFraction: 0.30, mirrored: false)
        let hostAnchor = CMTime(seconds: 100, preferredTimescale: 600)
        let writer = try makeWriter(
            url: url, source: source, options: options, hostTimeProvider: { hostAnchor }
        )
        writer.consume(try screenSample(pts: CMTime(value: 100, timescale: 30)), of: .screen)

        for tick in 0..<6 {
            writer.cameraTick(at: CMTimeAdd(hostAnchor, CMTime(value: Int64(tick), timescale: 30)))
            try await Task.sleep(for: .milliseconds(35))
        }
        writer.pause(atHostTime: CMTimeAdd(hostAnchor, CMTime(value: 6, timescale: 30)))
        for tick in 6..<36 {
            writer.cameraTick(at: CMTimeAdd(hostAnchor, CMTime(value: Int64(tick), timescale: 30)))
        }
        source.update(try pixelBuffer(width: 80, height: 60, color: .green))
        writer.resume(atHostTime: CMTimeAdd(hostAnchor, CMTime(value: 36, timescale: 30)))
        for tick in 36..<42 {
            writer.cameraTick(at: CMTimeAdd(hostAnchor, CMTime(value: Int64(tick), timescale: 30)))
            try await Task.sleep(for: .milliseconds(35))
        }

        let health = writer.healthSnapshot()
        #expect(health.video.delivered == 11)
        #expect(health.video.appended == 11)
        writer.markFinished()
        _ = try await writer.finishWriting()

        let frames = try await decodedFrames(at: url)
        #expect(frames.count == 11)
        let first = try #require(frames.first)
        let last = try #require(frames.last)
        #expect(first.color(atCI: CGPoint(x: 60, y: 48)).isMostlyRed)
        #expect(last.color(atCI: CGPoint(x: 60, y: 48)).isMostlyGreen)
        let gaps = zip(frames, frames.dropFirst()).map { CMTimeSubtract($1.pts, $0.pts).seconds }
        #expect(abs(try #require(gaps.first) - 2.0 / 30.0) < 0.002)
        #expect(gaps.dropFirst().allSatisfy { $0 > 0 && $0 < 0.05 })
        #expect(CMTimeSubtract(last.pts, first.pts).seconds < 0.39)
    }

    @Test("camera cadence preserves a real stereo audio track on the same timeline")
    func cameraCadenceKeepsStereoAudioAligned() async throws {
        let url = temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let source = FakeCameraFrameSource(try pixelBuffer(width: 80, height: 60, color: .red))
        let options = CameraOptions(enabled: true, corner: .bottomRight, widthFraction: 0.30, mirrored: false)
        let hostAnchor = CMTime(seconds: 100, preferredTimescale: 600)
        let writer = try makeWriter(
            url: url, source: source, options: options, includeSystemAudio: true,
            hostTimeProvider: { hostAnchor }
        )
        let screenPTS = CMTime(value: 100, timescale: 30)
        writer.consume(try screenSample(pts: screenPTS), of: .screen)
        let audioFramesPerTick = 1_600

        for tick in 0..<15 {
            writer.cameraTick(at: CMTimeAdd(hostAnchor, CMTime(value: Int64(tick), timescale: 30)))
            let audioPTS = CMTimeAdd(
                screenPTS,
                CMTime(value: Int64((tick + 1) * audioFramesPerTick), timescale: 48_000)
            )
            let audio = try AudioTestPCM.make(
                channels: [
                    Array(repeating: 0.10, count: audioFramesPerTick),
                    Array(repeating: 0.20, count: audioFramesPerTick),
                ],
                presentationTimeStamp: audioPTS
            )
            writer.consume(audio, of: .audio)
            try await Task.sleep(for: .milliseconds(35))
        }

        let health = writer.healthSnapshot()
        #expect(health.video.appended == 14)
        #expect(health.systemAudio.samples.appended == 15)
        writer.markFinished()
        _ = try await writer.finishWriting()

        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(videoTracks.count == 1)
        #expect(audioTracks.count == 1)
        let audioTrack = try #require(audioTracks.first)
        let descriptions = try await audioTrack.load(.formatDescriptions)
        let channelCounts = descriptions.compactMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame
        }
        #expect(channelCounts.contains(2))
        let videoDuration = try await videoTracks[0].load(.timeRange).duration.seconds
        let audioDuration = try await audioTrack.load(.timeRange).duration.seconds
        #expect(abs(videoDuration - audioDuration) < 0.08)
    }

    private func makeWriter(
        url: URL,
        source: FakeCameraFrameSource,
        options: CameraOptions,
        includeSystemAudio: Bool = false,
        hostTimeProvider: @escaping @Sendable () -> CMTime = {
            CMClockGetTime(CMClockGetHostTimeClock())
        }
    ) throws -> StreamWriter {
        try StreamWriter(
            outputURL: url,
            container: .mov,
            codec: .h264,
            bitrateMbps: 2,
            pixelWidth: 320,
            pixelHeight: 180,
            frameDuration: CMTime(value: 1, timescale: 30),
            dynamicRange: .sdr,
            includeSystemAudio: includeSystemAudio,
            includeMicrophone: false,
            cameraSource: source,
            cameraOptions: options,
            hostTimeProvider: hostTimeProvider
        )
    }

    private func temporaryMovieURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("camcord-camera-cadence-\(UUID().uuidString).mov")
    }

    private func screenSample(pts: CMTime) throws -> CMSampleBuffer {
        let pixel = try pixelBuffer(width: 320, height: 180, color: .blue)
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixel,
            formatDescriptionOut: &format
        ) == noErr, let format else { throw CameraCadenceTestError.format }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixel,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else { throw CameraCadenceTestError.sample }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else {
            throw CameraCadenceTestError.attachments
        }
        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        let key = SCStreamFrameInfo.status.rawValue as NSString
        let value = NSNumber(value: SCFrameStatus.complete.rawValue)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(value).toOpaque()
        )
        return sample
    }

    private func pixelBuffer(width: Int, height: Int, color: TestColor) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixel
        ) == kCVReturnSuccess, let pixel else { throw CameraCadenceTestError.pixel }

        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else { throw CameraCadenceTestError.pixel }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let offset = x * 4
                row[offset] = color.blue
                row[offset + 1] = color.green
                row[offset + 2] = color.red
                row[offset + 3] = 255
            }
        }
        return pixel
    }

    private func decodedFrames(at url: URL) async throws -> [DecodedFrame] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CameraCadenceTestError.missingTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        guard reader.canAdd(output) else { throw CameraCadenceTestError.reader }
        reader.add(output)
        guard reader.startReading() else { throw CameraCadenceTestError.reader }

        var frames: [DecodedFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let pixel = CMSampleBufferGetImageBuffer(sample) else {
                throw CameraCadenceTestError.pixel
            }
            frames.append(try DecodedFrame(
                pixelBuffer: pixel,
                pts: CMSampleBufferGetPresentationTimeStamp(sample)
            ))
        }
        guard reader.status == .completed else { throw CameraCadenceTestError.reader }
        return frames.sorted { $0.pts < $1.pts }
    }
}

private final class FakeCameraFrameSource: CameraFrameSource, @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var frame: CVPixelBuffer?
    }

    private let storage: OSAllocatedUnfairLock<State>

    init(_ frame: CVPixelBuffer?) {
        storage = OSAllocatedUnfairLock(initialState: State(frame: frame))
    }

    func update(_ frame: CVPixelBuffer?) {
        storage.withLockUnchecked { $0.frame = frame }
    }

    func latestFrame() -> CVPixelBuffer? {
        storage.withLockUnchecked { $0.frame }
    }
}

private struct DecodedFrame {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]
    let pts: CMTime

    init(pixelBuffer: CVPixelBuffer, pts: CMTime) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw CameraCadenceTestError.pixel
        }
        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        bytes = Array(UnsafeRawBufferPointer(start: base, count: bytesPerRow * height))
        self.pts = pts
    }

    func color(atCI point: CGPoint) -> TestColor {
        let x = min(max(Int(point.x.rounded()), 0), width - 1)
        let y = min(max(height - 1 - Int(point.y.rounded()), 0), height - 1)
        let offset = y * bytesPerRow + x * 4
        return TestColor(blue: bytes[offset], green: bytes[offset + 1], red: bytes[offset + 2])
    }
}

private struct TestColor {
    let blue: UInt8
    let green: UInt8
    let red: UInt8

    static let blue = Self(blue: 230, green: 20, red: 20)
    static let red = Self(blue: 20, green: 20, red: 230)
    static let green = Self(blue: 20, green: 230, red: 20)

    var isMostlyBlue: Bool { Int(blue) - max(Int(red), Int(green)) > 80 }
    var isMostlyRed: Bool { Int(red) - max(Int(blue), Int(green)) > 80 }
    var isMostlyGreen: Bool { Int(green) - max(Int(red), Int(blue)) > 80 }
}

private enum CameraCadenceTestError: Error {
    case attachments
    case format
    case missingTrack
    case pixel
    case reader
    case sample
}
