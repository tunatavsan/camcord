import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Testing

@testable import Camcord

@Suite("Scroll frame buffer")
struct ScrollFrameBufferTests {
    @Test("copies pixels and color space independently of the stream surface")
    func ownsImmutablePixels() throws {
        let source = try makePixelBuffer(width: 3, height: 2, value: 17)
        let displayP3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        CVBufferSetAttachment(source, kCVImageBufferCGColorSpaceKey, displayP3, .shouldPropagate)

        let buffer = ScrollFrameBuffer()
        buffer.ingest(try completeSample(source), of: .screen)
        let frame = try #require(buffer.peekLatest())

        fill(source, value: 201)

        #expect(frame.image.width == 3)
        #expect(frame.image.height == 2)
        #expect(frame.image.bytesPerRow == CVPixelBufferGetBytesPerRow(source))
        #expect(frame.image.colorSpace?.name == displayP3.name)
        #expect(firstByte(of: frame.image) == 17)
    }

    @Test("does not retain buffers from a threshold-five pixel pool")
    func releasesStreamSurfacesBeforeReturning() throws {
        let pool = try makePool(width: 8, height: 8, minimumCount: 5)
        let buffer = ScrollFrameBuffer(maximumBytes: 1_000_000, maximumFrames: 20)
        let allocationLimit = [kCVPixelBufferPoolAllocationThresholdKey as String: 5] as CFDictionary

        for value in 0..<12 {
            try autoreleasepool {
                var source: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                    kCFAllocatorDefault,
                    pool,
                    allocationLimit,
                    &source
                )
                #expect(status == kCVReturnSuccess)
                let pixelBuffer = try #require(source)
                fill(pixelBuffer, value: UInt8(value))
                buffer.ingest(try completeSample(pixelBuffer), of: .screen)
            }
        }

        #expect(buffer.stats.pendingFrameCount == 12)
        #expect(buffer.stats.droppedFrames == 0)
    }

    @Test("sequences, discards, and retains only the latest consumed snapshot")
    func sequenceAndDiscard() throws {
        let buffer = ScrollFrameBuffer()
        for value in 1...4 {
            buffer.ingest(try completeSample(makePixelBuffer(width: 2, height: 2, value: UInt8(value))), of: .screen)
        }

        #expect(buffer.frames(after: 2).map(\.seq) == [3, 4])
        buffer.discard(through: 3)
        #expect(buffer.frames(after: 0).map(\.seq) == [4])
        #expect(buffer.peekLatest()?.seq == 4)

        buffer.discard(through: 4)
        #expect(buffer.frames(after: 0).isEmpty)
        #expect(buffer.peekLatest()?.seq == 4)
        #expect(buffer.stats.pendingFrameCount == 0)

        buffer.reset()
        #expect(buffer.peekLatest() == nil)
        #expect(buffer.stats.ownedBytes == 0)
    }

    @Test("frame and byte caps evict oldest frames and report drops")
    func enforcesCaps() throws {
        let probe = try makePixelBuffer(width: 4, height: 3, value: 0)
        let frameBytes = CVPixelBufferGetBytesPerRow(probe) * CVPixelBufferGetHeight(probe)
        let buffer = ScrollFrameBuffer(maximumBytes: frameBytes * 2, maximumFrames: 3)

        for value in 1...4 {
            buffer.ingest(try completeSample(makePixelBuffer(width: 4, height: 3, value: UInt8(value))), of: .screen)
        }

        #expect(buffer.frames(after: 0).map(\.seq) == [3, 4])
        #expect(buffer.stats.pendingFrameCount == 2)
        #expect(buffer.stats.ownedBytes == frameBytes * 2)
        #expect(buffer.stats.droppedFrames == 2)
    }

    @Test("rejects incomplete, non-screen, and non-BGRA samples")
    func rejectsUnsupportedSamples() throws {
        let buffer = ScrollFrameBuffer()
        let bgra = try makePixelBuffer(width: 2, height: 2, value: 1)
        buffer.ingest(try sample(bgra, status: .idle), of: .screen)
        buffer.ingest(try completeSample(bgra), of: .audio)

        var planar: CVPixelBuffer?
        #expect(CVPixelBufferCreate(
            kCFAllocatorDefault, 2, 2, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil, &planar
        ) == kCVReturnSuccess)
        buffer.ingest(try completeSample(#require(planar)), of: .screen)

        #expect(buffer.peekLatest() == nil)
        #expect(buffer.stats.pendingFrameCount == 0)
    }

    @Test("suspend preserves snapshots, resume continues, and close is permanent")
    func intakeLifecycle() throws {
        let buffer = ScrollFrameBuffer()
        buffer.ingest(try completeSample(makePixelBuffer(width: 2, height: 2, value: 11)), of: .screen)

        buffer.suspendIntake()
        buffer.ingest(try completeSample(makePixelBuffer(width: 2, height: 2, value: 22)), of: .screen)
        #expect(buffer.frames(after: 0).map(\.seq) == [1])
        let suspendedLatest = try #require(buffer.peekLatest())
        #expect(firstByte(of: suspendedLatest.image) == 11)

        buffer.resumeIntake()
        buffer.ingest(try completeSample(makePixelBuffer(width: 2, height: 2, value: 33)), of: .screen)
        #expect(buffer.frames(after: 0).map(\.seq) == [1, 2])
        let resumedLatest = try #require(buffer.peekLatest())
        #expect(firstByte(of: resumedLatest.image) == 33)

        buffer.close()
        #expect(buffer.frames(after: 0).isEmpty)
        #expect(buffer.peekLatest() == nil)
        #expect(buffer.stats.pendingFrameCount == 0)
        #expect(buffer.stats.ownedBytes == 0)

        buffer.resumeIntake()
        buffer.reset()
        buffer.ingest(try completeSample(makePixelBuffer(width: 2, height: 2, value: 44)), of: .screen)
        #expect(buffer.peekLatest() == nil)
        #expect(buffer.stats.ownedBytes == 0)
    }
}

private func makePixelBuffer(width: Int, height: Int, value: UInt8) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
        &buffer
    )
    #expect(status == kCVReturnSuccess)
    let result = try #require(buffer)
    fill(result, value: value)
    return result
}

private func makePool(width: Int, height: Int, minimumCount: Int) throws -> CVPixelBufferPool {
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        [kCVPixelBufferPoolMinimumBufferCountKey as String: minimumCount] as CFDictionary,
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary,
        &pool
    )
    #expect(status == kCVReturnSuccess)
    return try #require(pool)
}

private func fill(_ buffer: CVPixelBuffer, value: UInt8) {
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, Int32(value), CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
}

private func completeSample(_ buffer: CVPixelBuffer) throws -> CMSampleBuffer {
    try sample(buffer, status: .complete)
}

private func sample(_ buffer: CVPixelBuffer, status: SCFrameStatus) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: buffer,
        formatDescriptionOut: &format
    ) == noErr, let format else { throw ScrollFrameBufferTestError.creation }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    var result: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: buffer,
        formatDescription: format,
        sampleTiming: &timing,
        sampleBufferOut: &result
    ) == noErr, let result else { throw ScrollFrameBufferTestError.creation }

    let attachments = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true)!
    let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
    dictionary[SCStreamFrameInfo.status] = status.rawValue
    return result
}

private func firstByte(of image: CGImage) -> UInt8? {
    guard let data = image.dataProvider?.data, CFDataGetLength(data) > 0,
        let bytes = CFDataGetBytePtr(data)
    else { return nil }
    return bytes[0]
}

private enum ScrollFrameBufferTestError: Error { case creation }
