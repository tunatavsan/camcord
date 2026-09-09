import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Testing

@testable import Camcord

@Suite("Camera compositor")
struct CameraCompositorTests {
    @Test("disabled camera is an identity no-op")
    func disabledIsIdentity() throws {
        let screen = try sampleBuffer(buffer: solidBuffer(width: 160, height: 90, bgra: (20, 30, 40, 255)))
        let camera = solidBuffer(width: 32, height: 18, bgra: (0, 240, 0, 255))
        let output = try compositor().composite(
            screen: screen,
            camera: camera,
            options: CameraOptions(enabled: false)
        )
        #expect(output === screen)
    }

    @Test("layout keeps a fixed 16:9 shape even with a 4:3 camera")
    func layoutCornersAndAspect() {
        for corner in CameraCorner.allCases {
            let options = CameraOptions(enabled: true, corner: corner, widthFraction: 0.2)
            let rect = options.rect(in: CGSize(width: 1000, height: 600))
            #expect(abs(rect.width / rect.height - 16.0 / 9.0) < 0.03)
            switch corner {
            case .topLeft: #expect(rect.midX < 500 && rect.midY > 300)
            case .topRight: #expect(rect.midX > 500 && rect.midY > 300)
            case .bottomLeft: #expect(rect.midX < 500 && rect.midY < 300)
            case .bottomRight: #expect(rect.midX > 500 && rect.midY < 300)
            }
        }
    }

    @Test("composite places contrasting camera pixels in the selected corner")
    func compositePlacesCameraInCorner() throws {
        let screenBuffer = solidBuffer(width: 200, height: 120, bgra: (12, 12, 12, 255))
        let screen = try sampleBuffer(buffer: screenBuffer)
        let camera = solidBuffer(width: 40, height: 20, bgra: (20, 230, 30, 255))
        let options = CameraOptions(
            enabled: true,
            corner: .topRight,
            widthFraction: 0.35,
            mirrored: false
        )
        let compositor = compositor()
        let output = try compositor.composite(screen: screen, camera: camera, options: options)
        let outputBuffer = try #require(CMSampleBufferGetImageBuffer(output))
        let rect = options.rect(in: CGSize(width: 200, height: 120))

        let cameraPixel = pixel(outputBuffer, ciX: Int(rect.midX), ciY: Int(rect.midY))
        let oppositePixel = pixel(outputBuffer, ciX: 20, ciY: 20)
        #expect(cameraPixel.g > 170)
        #expect(oppositePixel.r < 40 && oppositePixel.g < 40 && oppositePixel.b < 40)
    }

    @Test("mirror reverses the camera's left and right halves")
    func mirrorReversesHorizontally() throws {
        let screen = try sampleBuffer(buffer: solidBuffer(width: 200, height: 120, bgra: (0, 0, 0, 255)))
        let camera = splitBuffer(width: 40, height: 20)
        let compositor = compositor()
        let base = CameraOptions(
            enabled: true,
            corner: .bottomLeft,
            widthFraction: 0.4,
            mirrored: false
        )
        let rect = base.rect(in: CGSize(width: 200, height: 120))

        let unmirrored = try #require(CMSampleBufferGetImageBuffer(
            try compositor.composite(screen: screen, camera: camera, options: base)
        ))
        let normalLeft = pixel(unmirrored, ciX: Int(rect.minX + rect.width * 0.3), ciY: Int(rect.midY))
        let normalRight = pixel(unmirrored, ciX: Int(rect.minX + rect.width * 0.7), ciY: Int(rect.midY))
        #expect(normalLeft.r > normalLeft.b)
        #expect(normalRight.b > normalRight.r)

        var mirroredOptions = base
        mirroredOptions.mirrored = true
        let mirrored = try #require(CMSampleBufferGetImageBuffer(
            try compositor.composite(screen: screen, camera: camera, options: mirroredOptions)
        ))
        let mirroredLeft = pixel(mirrored, ciX: Int(rect.minX + rect.width * 0.3), ciY: Int(rect.midY))
        let mirroredRight = pixel(mirrored, ciX: Int(rect.minX + rect.width * 0.7), ciY: Int(rect.midY))
        #expect(mirroredLeft.b > mirroredLeft.r)
        #expect(mirroredRight.r > mirroredRight.b)
    }

    @Test("camera output builds its own format when screen row alignment differs")
    func outputFormatMatchesItsOwnBuffer() throws {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 162, 90, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferBytesPerRowAlignmentKey as String: 4096,
             kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
        #expect(status == kCVReturnSuccess)
        let input = try #require(buffer)
        CVPixelBufferLockBaseAddress(input, [])
        memset(CVPixelBufferGetBaseAddress(input), 0, CVPixelBufferGetDataSize(input))
        CVPixelBufferUnlockBaseAddress(input, [])
        let sample = try sampleBuffer(buffer: input)
        let camera = solidBuffer(width: 32, height: 18, bgra: (0, 240, 0, 255))
        let output = try compositor().composite(screen: sample, camera: camera, options: CameraOptions(enabled: true))
        let outputBuffer = try #require(CMSampleBufferGetImageBuffer(output))
        #expect(CVPixelBufferGetBytesPerRow(outputBuffer) != CVPixelBufferGetBytesPerRow(input))
        #expect(CMVideoFormatDescriptionMatchesImageBuffer(try #require(CMSampleBufferGetFormatDescription(output)), imageBuffer: outputBuffer))
    }

    @Test("timing, frame attachments, color metadata, and format survive composition")
    func preservesMediaContract() throws {
        let screenBuffer = solidBuffer(width: 160, height: 90, bgra: (20, 30, 40, 255))
        CVBufferSetAttachment(
            screenBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            screenBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            .shouldPropagate
        )
        let pts = CMTime(value: 12_345, timescale: 600)
        let duration = CMTime(value: 10, timescale: 600)
        let screen = try sampleBuffer(buffer: screenBuffer, pts: pts, duration: duration)
        setSampleAttachment(screen, key: "camera-test-frame", value: "preserved")
        let camera = solidBuffer(width: 32, height: 18, bgra: (0, 240, 0, 255))
        let compositor = compositor()
        let options = CameraOptions(enabled: true)

        let first = try compositor.composite(screen: screen, camera: camera, options: options)
        let outputBuffer = try #require(CMSampleBufferGetImageBuffer(first))

        #expect(CMSampleBufferGetPresentationTimeStamp(first) == pts)
        #expect(CMSampleBufferGetDuration(first) == duration)
        #expect(CVPixelBufferGetWidth(outputBuffer) == 160)
        #expect(CVPixelBufferGetHeight(outputBuffer) == 90)
        #expect(CVPixelBufferGetPixelFormatType(outputBuffer) == kCVPixelFormatType_32BGRA)
        #expect(sampleAttachment(first, key: "camera-test-frame") as? String == "preserved")
        #expect(CVBufferCopyAttachment(outputBuffer, kCVImageBufferColorPrimariesKey, nil) as? String
            == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        #expect(CVBufferCopyAttachment(outputBuffer, kCVImageBufferTransferFunctionKey, nil) as? String
            == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
    }
}

private struct BGRA {
    let b: UInt8
    let g: UInt8
    let r: UInt8
    let a: UInt8
}

private func compositor() -> CameraCompositor {
    CameraCompositor(context: CIContext(options: [
        .useSoftwareRenderer: true,
        .cacheIntermediates: false,
    ]))
}

private func solidBuffer(
    width: Int,
    height: Int,
    bgra: (UInt8, UInt8, UInt8, UInt8)
) -> CVPixelBuffer {
    makeBuffer(width: width, height: height) { _, _ in bgra }
}

private func splitBuffer(width: Int, height: Int) -> CVPixelBuffer {
    makeBuffer(width: width, height: height) { x, _ in
        x < width / 2 ? (0, 0, 240, 255) : (240, 0, 0, 255)
    }
}

private func makeBuffer(
    width: Int,
    height: Int,
    pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
) -> CVPixelBuffer {
    var result: CVPixelBuffer?
    precondition(CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
        &result
    ) == kCVReturnSuccess)
    let buffer = result!
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in 0..<width {
            let value = pixel(x, y)
            let offset = y * rowBytes + x * 4
            base[offset] = value.0
            base[offset + 1] = value.1
            base[offset + 2] = value.2
            base[offset + 3] = value.3
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

private func sampleBuffer(
    buffer: CVPixelBuffer,
    pts: CMTime = CMTime(value: 7, timescale: 30),
    duration: CMTime = CMTime(value: 1, timescale: 30)
) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: buffer,
        formatDescriptionOut: &format
    ) == noErr, let format else { throw TestError.creation }
    var timing = CMSampleTimingInfo(
        duration: duration,
        presentationTimeStamp: pts,
        decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: buffer,
        formatDescription: format,
        sampleTiming: &timing,
        sampleBufferOut: &sample
    ) == noErr, let sample else { throw TestError.creation }
    return sample
}

private func pixel(_ buffer: CVPixelBuffer, ciX: Int, ciY: Int) -> BGRA {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let y = CVPixelBufferGetHeight(buffer) - 1 - ciY
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let offset = y * rowBytes + ciX * 4
    return BGRA(b: base[offset], g: base[offset + 1], r: base[offset + 2], a: base[offset + 3])
}

private func setSampleAttachment(_ sample: CMSampleBuffer, key: String, value: String) {
    let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)!
    let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
    CFDictionarySetValue(
        dictionary,
        Unmanaged.passUnretained(key as NSString).toOpaque(),
        Unmanaged.passUnretained(value as NSString).toOpaque()
    )
}

private func sampleAttachment(_ sample: CMSampleBuffer, key: String) -> Any? {
    guard let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) else {
        return nil
    }
    let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: NSDictionary.self)
    return dictionary[key]
}

private enum TestError: Error { case creation }
