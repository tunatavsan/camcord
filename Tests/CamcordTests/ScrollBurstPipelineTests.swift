import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Testing

@testable import Camcord

@Suite("Manual scroll burst pipeline")
struct ScrollBurstPipelineTests {
    @Test("an evicted initial viewport cannot become an apparently complete capture")
    func missingTopBlocksExport() async throws {
        let frames = ScrollFrameBuffer(maximumFrames: 2)
        let worker = ScrollStitchWorker()
        for offset in [0, 96, 192, 288] {
            try ingestFrame(into: frames, offset: offset)
        }
        let batch = try #require(await worker.consumeFrames(from: frames, after: 0, predictedOffset: 0))
        #expect(frames.stats.droppedFrames == 2)
        #expect(batch.result.hasUnresolvedContinuity)
        #expect(await worker.finalImage() == nil)
    }

    @Test("final snapshot rejects late old stream frames and resumes intake afterward")
    func finalSnapshotPreservesTemporalOrder() async throws {
        let frames = ScrollFrameBuffer()
        let worker = ScrollStitchWorker()
        for offset in [0, 96, 192] { try ingestFrame(into: frames, offset: offset) }
        let entered = AsyncStream<Void>.makeStream()
        let screenshot = AsyncStream<CGImage>.makeStream()
        let capture = Task {
            await worker.consumeRestingFrame(from: frames, after: 0, predictedOffset: 0) {
                entered.continuation.yield(())
                entered.continuation.finish()
                for await image in screenshot.stream { return image }
                throw CaptureError.timeout
            }
        }
        for await _ in entered.stream { break }
        // This callback is older than the forthcoming screenshot but arrives
        // while its asynchronous capture is suspended. It must never follow it.
        try ingestFrame(into: frames, offset: 288)
        #expect(frames.stats.pendingFrameCount == 0)
        screenshot.continuation.yield(try frameImage(offset: 384))
        screenshot.continuation.finish()
        let result = await capture.value
        #expect(result.error == nil)
        #expect(result.lastSequence == 3)
        #expect(result.result?.hasUnresolvedContinuity == false)

        try ingestFrame(into: frames, offset: 480)
        let resumed = try #require(await worker.consumeFrames(
            from: frames, after: result.lastSequence, predictedOffset: 0
        ))
        #expect(resumed.frameCount == 1)
        #expect(resumed.lastSequence == 4)
        let output = try #require(await worker.finalImage())
        try #require(output.width == 256 && output.height == 960)
        #expect(try rgbaPixels(output) == rgbaPixels(frameImage(offset: 0, height: 960)))
    }

    @Test("pooled stream bursts survive delayed consumption and reconstruct every pixel in order")
    func ownedFramesReachProductionWorker() async throws {
        let width = 256, viewportHeight = 480, stride = 96, count = 120
        var pool: CVPixelBufferPool?
        try #require(CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: viewportHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ] as CFDictionary, &pool) == kCVReturnSuccess)
        let producerPool = try #require(pool)
        let frames = ScrollFrameBuffer()
        let worker = ScrollStitchWorker()
        var lastSequence: UInt64 = 0

        // Deliver 120 frames in delayed bursts, as happens when rapid
        // scrolling overlaps another async task. The SCK-like pool has only five
        // source buffers; the real frame tap must return them immediately.
        for batchStart in [0, 30, 60, 90] {
            for index in batchStart..<(batchStart + 30) {
                try autoreleasepool {
                    var buffer: CVPixelBuffer?
                    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, producerPool, [
                        kCVPixelBufferPoolAllocationThresholdKey: 5,
                    ] as CFDictionary, &buffer)
                    try #require(status == kCVReturnSuccess)
                    let source = try #require(buffer)
                    try fill(source, offset: index * stride)
                    frames.ingest(try completeSample(source, sequence: index), of: .screen)
                }
            }
            let batch = try #require(await worker.consumeFrames(
                from: frames, after: lastSequence, predictedOffset: 0
            ))
            #expect(batch.frameCount == 30)
            #expect(!batch.result.hasUnresolvedContinuity)
            lastSequence = batch.lastSequence
            #expect(frames.stats.pendingFrameCount == 0)
            #expect(frames.stats.droppedFrames == 0)
        }

        #expect(lastSequence == UInt64(count))
        #expect(await worker.consumeFrames(from: frames, after: lastSequence, predictedOffset: 0) == nil)
        let image = try #require(await worker.finalImage())
        let expectedHeight = viewportHeight + (count - 1) * stride
        #expect(image.width == width)
        try #require(image.height == expectedHeight)
        let pixels = try rgbaPixels(image)
        var mismatchCount = 0
        for y in 0..<expectedHeight {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let expected = shade(x: x, y: y)
                if pixels[index] != expected || pixels[index + 1] != expected
                    || pixels[index + 2] != expected || pixels[index + 3] != 255 {
                    mismatchCount += 1
                }
            }
        }
        #expect(mismatchCount == 0)
    }

    private func shade(x: Int, y: Int) -> UInt8 {
        var value = UInt64(y + 1) &* 2_654_435_761 ^ UInt64(x + 7) &* 2_246_822_519
        value ^= value >> 13
        value &*= 3_266_489_917
        return UInt8(truncatingIfNeeded: value >> 19)
    }

    private func ingestFrame(into frames: ScrollFrameBuffer, offset: Int) throws {
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(nil, 256, 480, kCVPixelFormatType_32BGRA,
            nil, &buffer) == kCVReturnSuccess)
        let source = try #require(buffer)
        try fill(source, offset: offset)
        frames.ingest(try completeSample(source, sequence: offset), of: .screen)
    }

    private func frameImage(offset: Int, height: Int = 480) throws -> CGImage {
        let width = 256
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = shade(x: x, y: offset + y)
                let index = (y * width + x) * 4
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func fill(_ buffer: CVPixelBuffer, offset: Int) throws {
        try #require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            for x in 0..<CVPixelBufferGetWidth(buffer) {
                let value = shade(x: x, y: offset + y)
                let index = y * bytesPerRow + x * 4
                base[index] = value
                base[index + 1] = value
                base[index + 2] = value
                base[index + 3] = 255
            }
        }
    }

    private func completeSample(_ buffer: CVPixelBuffer, sequence: Int) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        try #require(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format
        ) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 120),
            presentationTimeStamp: CMTime(value: Int64(sequence), timescale: 120), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try #require(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: #require(format),
            sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr)
        let result = try #require(sample)
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true))
        let info = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        info[SCStreamFrameInfo.status] = SCFrameStatus.complete.rawValue
        return result
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }
}
