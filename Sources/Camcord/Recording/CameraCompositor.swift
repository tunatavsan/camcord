import CoreImage
import CoreMedia
import CoreVideo
import Foundation

enum CameraCompositorError: Error {
    case missingScreenImage
    case invalidDimensions
    case poolCreationFailed(CVReturn)
    case poolExhausted(CVReturn)
    case missingFormatDescription
    case sampleCreationFailed(OSStatus)
    case filterUnavailable
}

/// Sample-queue-confined Core Image compositor. The output always uses the screen buffer's exact
/// dimensions and pixel format; unsupported HDR destinations fail instead of becoming 8-bit SDR.
final class CameraCompositor {
    private struct PoolKey: Hashable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
    }

    private let context: CIContext
    private var pools: [PoolKey: CVPixelBufferPool] = [:]
    private var outputFormat: CMVideoFormatDescription?
    private let poolAllocationAttributes = [
        kCVPixelBufferPoolAllocationThresholdKey as String: 4
    ] as CFDictionary

    init(context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.context = context
    }

    func composite(
        screen: CMSampleBuffer,
        camera: CVPixelBuffer,
        options: CameraOptions
    ) throws -> CMSampleBuffer {
        let options = options.resolved()
        guard options.enabled else { return screen }
        guard let screenBuffer = CMSampleBufferGetImageBuffer(screen) else {
            throw CameraCompositorError.missingScreenImage
        }

        let width = CVPixelBufferGetWidth(screenBuffer)
        let height = CVPixelBufferGetHeight(screenBuffer)
        let cameraWidth = CVPixelBufferGetWidth(camera)
        let cameraHeight = CVPixelBufferGetHeight(camera)
        guard width > 0, height > 0, cameraWidth > 0, cameraHeight > 0 else {
            throw CameraCompositorError.invalidDimensions
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(screenBuffer)
        let output = try makeOutputBuffer(width: width, height: height, pixelFormat: pixelFormat)
        CVBufferRemoveAllAttachments(output)
        CVBufferPropagateAttachments(screenBuffer, output)

        let screenExtent = CGRect(x: 0, y: 0, width: width, height: height)
        let cameraRect = options.rect(in: screenExtent.size)
        let radius = CameraOptions.cornerRadius(for: cameraRect.size)

        let screenImage = CIImage(cvPixelBuffer: screenBuffer)
        let sourceCameraImage = CIImage(cvPixelBuffer: camera)
        var cameraImage = sourceCameraImage
            .transformed(by: CGAffineTransform(
                translationX: -sourceCameraImage.extent.minX,
                y: -sourceCameraImage.extent.minY
            ))
        if options.mirrored {
            cameraImage = cameraImage.transformed(by: CGAffineTransform(
                a: -1, b: 0, c: 0, d: 1,
                tx: cameraImage.extent.width, ty: 0
            ))
        }
        cameraImage = aspectFill(cameraImage, in: cameraRect)

        let transparent = CIImage(color: .clear).cropped(to: screenExtent)
        let outerMask = try roundedMask(rect: cameraRect, radius: radius).cropped(to: screenExtent)
        // The shadow is sized off the TILE, not off the corner: the tile carries a light
        // Apple-ish curve now, and a shadow derived from it would have shrunk with it —
        // the separation from the desktop behind is exactly what has to grow. One set of
        // numbers for both renderers, so the file lifts the tile the way the screen does.
        let drop = CameraOptions.shadow(for: cameraRect.size)
        let shadowMask = outerMask.transformed(by: CGAffineTransform(translationX: 0, y: drop.offsetY))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: drop.blur])
            .cropped(to: screenExtent)

        let shadow = try masked(
            CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: drop.alpha)).cropped(to: screenExtent),
            mask: shadowMask,
            background: transparent
        )
        // The same glass edge `FloatingCameraView` strokes on screen: a diagonal gradient of
        // light along the hairline, and a darker line immediately inside it so the boundary
        // survives bright content instead of turning into a flat white border.
        let hairline = CameraOptions.edgeHighlightWidth(for: cameraRect.size)
        let innerRect = cameraRect.insetBy(dx: hairline, dy: hairline)
        let innerRadius = max(0, radius - hairline)
        let innerMask = try roundedMask(rect: innerRect, radius: innerRadius).cropped(to: screenExtent)
        let ring = try masked(
            try edgeGradient(in: cameraRect).cropped(to: screenExtent),
            mask: band(outer: outerMask, inner: innerMask, extent: screenExtent),
            background: transparent
        )
        let contrastWidth = CameraOptions.edgeShadowWidth(for: cameraRect.size)
        let coreMask = try roundedMask(
            rect: innerRect.insetBy(dx: contrastWidth, dy: contrastWidth),
            radius: max(0, innerRadius - contrastWidth)
        ).cropped(to: screenExtent)
        let contrast = try masked(
            CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: CameraOptions.edgeShadowAlpha))
                .cropped(to: screenExtent),
            mask: band(outer: innerMask, inner: coreMask, extent: screenExtent),
            background: transparent
        )
        let clippedCamera = try masked(cameraImage, mask: outerMask, background: transparent)
        let composed = ring
            .composited(over: contrast.composited(
                over: clippedCamera.composited(over: shadow.composited(over: screenImage))
            ))
            .cropped(to: screenExtent)

        context.render(
            composed,
            to: output,
            bounds: screenExtent,
            colorSpace: colorSpace(from: screenBuffer)
        )
        return try makeSampleBuffer(imageBuffer: output, copying: screen)
    }

    private func makeOutputBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) throws -> CVPixelBuffer {
        let key = PoolKey(width: width, height: height, pixelFormat: pixelFormat)
        let pool: CVPixelBufferPool
        if let existing = pools[key] {
            pool = existing
        } else {
            let poolAttributes = [
                kCVPixelBufferPoolMinimumBufferCountKey as String: 3
            ] as CFDictionary
            let pixelAttributes = [
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ] as CFDictionary
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                poolAttributes,
                pixelAttributes,
                &created
            )
            guard status == kCVReturnSuccess, let created else {
                throw CameraCompositorError.poolCreationFailed(status)
            }
            pools[key] = created
            pool = created
        }

        var output: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            poolAllocationAttributes,
            &output
        )
        guard status == kCVReturnSuccess, let output else {
            throw CameraCompositorError.poolExhausted(status)
        }
        return output
    }

    private func aspectFill(_ image: CIImage, in rect: CGRect) -> CIImage {
        let scale = max(rect.width / image.extent.width, rect.height / image.extent.height)
        let fittedSize = CGSize(width: image.extent.width * scale, height: image.extent.height * scale)
        let x = rect.midX - fittedSize.width / 2
        let y = rect.midY - fittedSize.height / 2
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: x, y: y))
    }

    private func roundedMask(rect: CGRect, radius: CGFloat) throws -> CIImage {
        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": radius,
            "inputColor": CIColor.white,
        ]), let output = filter.outputImage else {
            throw CameraCompositorError.filterUnavailable
        }
        return output
    }

    /// The band between two concentric rounded masks: the hairline itself, or the darker
    /// line inside it.
    private func band(outer: CIImage, inner: CIImage, extent: CGRect) -> CIImage {
        outer.applyingFilter("CISourceOutCompositing", parameters: [
            kCIInputBackgroundImageKey: inner
        ]).cropped(to: extent)
    }

    /// The hairline's light: brightest at the tile's top-leading corner, nearly gone at the
    /// opposite one, so the edge reads as glass catching light from above.
    private func edgeGradient(in rect: CGRect) throws -> CIImage {
        let stops = CameraOptions.edgeHighlight
        guard let filter = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: rect.minX, y: rect.maxY),
            "inputPoint1": CIVector(x: rect.maxX, y: rect.minY),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: stops.bright),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: stops.dim),
        ]), let output = filter.outputImage else {
            throw CameraCompositorError.filterUnavailable
        }
        return output
    }

    private func masked(
        _ foreground: CIImage,
        mask: CIImage,
        background: CIImage
    ) throws -> CIImage {
        guard let filter = CIFilter(name: "CIBlendWithAlphaMask", parameters: [
            kCIInputImageKey: foreground,
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask,
        ]), let output = filter.outputImage else {
            throw CameraCompositorError.filterUnavailable
        }
        return output
    }

    private func colorSpace(from buffer: CVPixelBuffer) -> CGColorSpace? {
        guard let attachment = CVBufferCopyAttachment(
            buffer,
            kCVImageBufferCGColorSpaceKey,
            nil
        ) else { return nil }
        guard CFGetTypeID(attachment) == CGColorSpace.typeID else { return nil }
        return unsafeDowncast(attachment, to: CGColorSpace.self)
    }

    private func makeSampleBuffer(
        imageBuffer: CVPixelBuffer,
        copying source: CMSampleBuffer
    ) throws -> CMSampleBuffer {
        // A pooled render destination can have a different row stride or color
        // attachment set than SCK's source, even at identical dimensions/format.
        // Reusing the source description then fails with InvalidMediaFormat (-12743).
        if outputFormat.map({ CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: imageBuffer) }) != true {
            var created: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescriptionOut: &created
            )
            guard status == noErr, let created else { throw CameraCompositorError.missingFormatDescription }
            outputFormat = created
        }
        guard let format = outputFormat else { throw CameraCompositorError.missingFormatDescription }
        var timing = CMSampleTimingInfo()
        let timingStatus = CMSampleBufferGetSampleTimingInfo(
            source,
            at: 0,
            timingInfoOut: &timing
        )
        guard timingStatus == noErr else {
            throw CameraCompositorError.sampleCreationFailed(timingStatus)
        }
        var result: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &result
        )
        guard status == noErr, let result else {
            throw CameraCompositorError.sampleCreationFailed(status)
        }
        CMPropagateAttachments(source, destination: result)
        copySampleAttachments(from: source, to: result)
        return result
    }

    private func copySampleAttachments(from source: CMSampleBuffer, to destination: CMSampleBuffer) {
        guard
            let sourceArray = CMSampleBufferGetSampleAttachmentsArray(source, createIfNecessary: false),
            CFArrayGetCount(sourceArray) > 0,
            let destinationArray = CMSampleBufferGetSampleAttachmentsArray(destination, createIfNecessary: true),
            CFArrayGetCount(destinationArray) > 0
        else { return }
        let sourceDictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(sourceArray, 0),
            to: NSDictionary.self
        )
        let destinationDictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(destinationArray, 0),
            to: NSMutableDictionary.self
        )
        destinationDictionary.addEntries(from: sourceDictionary as! [AnyHashable: Any])
    }
}
