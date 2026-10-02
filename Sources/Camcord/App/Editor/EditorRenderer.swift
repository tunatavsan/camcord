import AppKit
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Foundation
import Darwin

struct EditorDisplayBase: Sendable {
    let image: CGImage
    let pointSize: CGSize
    /// Sanitized, cropped source before background/frame clipping, used by the
    /// same text/highlight statistics as export.
    let underlay: CGImage
    var backdrop: CGImage? = nil
    var sourceClip: CGImage? = nil
    /// Display-only memory: sanitized and cropped before visual effects. Export
    /// and copy render their own document and never consume this raster.
    var privacySource: CGImage? = nil
}
private struct EditorRenderComposition {
    let rendered: EditorRendered
    let underlay: CGImage
    let backdrop: CGImage?
    let sourceClip: CGImage?
    let privacySource: CGImage?
}
struct EditorRendered: Sendable {
    let image: CGImage
    let pointSize: CGSize
    var png: Data {
        get throws {
            try EditorGeometry.validateDimensions(width: image.width, height: image.height, pixels: 64_000_000)
            guard pointSize.width.isFinite, pointSize.height.isFinite, pointSize.width > 0, pointSize.height > 0 else { throw EditorError.invalidEdits }
            try Task.checkCancellation()
            let data = NSMutableData()
            guard let writer = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw EditorError.render }
            // A fresh image destination never receives original metadata, OCR strings or edits.
            let x = min(1200, max(36, 72 * Double(image.width) / pointSize.width))
            let y = min(1200, max(36, 72 * Double(image.height) / pointSize.height))
            CGImageDestinationAddImage(writer, image, nil)
            guard CGImageDestinationFinalize(writer) else { throw EditorError.render }
            return try Self.densityOnlyPNG(data as Data, x: x, y: y)
        }
    }
    /// ImageIO inserts eXIf even for a fresh raster. Keep only PNG raster/color chunks and pHYs.
    private static func densityOnlyPNG(_ encoded: Data, x: Double, y: Double) throws -> Data {
        func integer(_ value: UInt32) -> Data { Data([UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
        func chunk(_ name: String, _ payload: Data) -> Data {
            let body = Data(name.utf8) + payload
            var crc = UInt32.max
            for byte in body {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
            }
            return integer(UInt32(payload.count)) + body + integer(~crc)
        }
        guard encoded.count >= 8, encoded.count <= 268_435_456,
              encoded.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { throw EditorError.render }
        var output = Data(encoded.prefix(8)), offset = 8, sawHeader = false, sawPixels = false, sawEnd = false
        let density = integer(UInt32((x / 0.0254).rounded())) + integer(UInt32((y / 0.0254).rounded())) + Data([1])
        while offset + 12 <= encoded.count {
            let length = encoded[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= encoded.count - offset - 12 else { throw EditorError.render }
            let name = String(decoding: encoded[offset + 4..<offset + 8], as: UTF8.self)
            if name == "IHDR" { guard offset == 8, length == 13, !sawHeader else { throw EditorError.render }; sawHeader = true }
            else { guard sawHeader else { throw EditorError.render } }
            if name == "IDAT" { sawPixels = true }
            if ["IHDR", "PLTE", "tRNS", "sRGB", "gAMA", "cHRM", "iCCP", "sBIT", "IDAT", "IEND"].contains(name) {
                output.append(encoded[offset..<offset + length + 12])
            }
            if name == "IHDR" { output.append(chunk("pHYs", density)) }
            if name == "IEND" {
                guard length == 0, offset + length + 12 == encoded.count else { throw EditorError.render }
                sawEnd = true; break
            }
            offset += length + 12
        }
        guard sawHeader, sawPixels, sawEnd else { throw EditorError.render }
        return output
    }
}

/// System-only, off-main renderer. Sanitization precedes cropping and every derived effect.
enum EditorRenderer {
    static let markerColor = EditorColor(red: 1, green: 224.0 / 255, blue: 58.0 / 255)
    static func isSourceDestination(_ destination: URL, source: URL?) -> Bool {
        guard let source else { return false }
        if destination.standardizedFileURL == source.standardizedFileURL { return true }
        var original = stat(), requested = stat()
        guard stat(source.path, &original) == 0, stat(destination.path, &requested) == 0 else { return false }
        return original.st_dev == requested.st_dev && original.st_ino == requested.st_ino
    }
    static func decode(_ url: URL) throws -> EditorDocument {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path),
              let resource = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              resource.isRegularFile == true, resource.isSymbolicLink != true,
              let size = resource.fileSize, size > 0, size <= 1_073_741_824,
              ["png", "jpg", "jpeg", "tif", "tiff"].contains(url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier].contains(type as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw EditorError.invalidImage }
        try EditorGeometry.validateDimensions(width: width, height: height, pixels: 50_000_000)
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard let raw = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw EditorError.invalidImage }
        try EditorGeometry.validateDimensions(width: raw.width, height: raw.height, pixels: 50_000_000)
        let image = try normalized(raw, orientation: orientation)
        try EditorGeometry.validateDimensions(width: image.width, height: image.height, pixels: 50_000_000)
        // ImageIO rounds the top-level DPI keys; pHYs retains fractional PNG density.
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let dpiX = (png?[kCGImagePropertyPNGXPixelsPerMeter] as? Double).map { $0 * 0.0254 } ?? (properties[kCGImagePropertyDPIWidth] as? Double ?? 72)
        let dpiY = (png?[kCGImagePropertyPNGYPixelsPerMeter] as? Double).map { $0 * 0.0254 } ?? (properties[kCGImagePropertyDPIHeight] as? Double ?? 72)
        let safeX = dpiX.isFinite && (36...1200).contains(dpiX) ? dpiX : 72
        let safeY = dpiY.isFinite && (36...1200).contains(dpiY) ? dpiY : 72
        let swapped = (5...8).contains(orientation)
        return try EditorDocument(source: image, sourceURL: url, pointSize: CGSize(width: Double(image.width) * 72 / (swapped ? safeY : safeX), height: Double(image.height) * 72 / (swapped ? safeX : safeY)))
    }

    private static func normalized(_ image: CGImage, orientation: Int) throws -> CGImage {
        guard (2...8).contains(orientation) else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height), swapped = orientation >= 5
        let output = try context(width: swapped ? image.height : image.width, height: swapped ? image.width : image.height)
        let transform: CGAffineTransform
        switch orientation {
        case 2: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        default: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        }
        output.concatenate(transform); output.interpolationQuality = .none
        output.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = output.makeImage() else { throw EditorError.render }; return result
    }

    static func context(width: Int, height: Int) throws -> CGContext {
        try EditorGeometry.validateDimensions(width: width, height: height, pixels: 64_000_000)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EditorError.render }
        return context
    }

    static func render(_ document: EditorDocument) throws -> EditorRendered {
        try render(document, includesVectors: true).rendered
    }
    static func displayBase(_ document: EditorDocument) throws -> EditorDisplayBase {
        let value = try render(document, includesVectors: false)
        return EditorDisplayBase(image: value.rendered.image, pointSize: value.rendered.pointSize, underlay: value.underlay, backdrop: value.backdrop, sourceClip: value.sourceClip, privacySource:value.privacySource)
    }
    private static func render(_ document: EditorDocument, includesVectors: Bool) throws -> EditorRenderComposition {
        try Task.checkCancellation()
        guard document.edits.valid else { throw EditorError.invalidEdits }
        try EditorGeometry.validateDimensions(width: document.source.width, height: document.source.height, pixels: 50_000_000)
        let bounds = document.bounds
        let pixelScale = CGSize(width: CGFloat(document.source.width) / document.pointSize.width, height: CGFloat(document.source.height) / document.pointSize.height)
        let effectScale = sqrt(pixelScale.width * pixelScale.height)
        let crop = EditorGeometry.pixelRect(document.edits.crop, bounds: bounds)
        guard !crop.isNull, !crop.isEmpty else { throw EditorError.invalidEdits }
        let background = document.edits.background
        let padding = background.preset == .none ? 0 : Int(ceil(background.padding + background.frameWidth))
        let width = Int(crop.width) + padding * 2, height = Int(crop.height) + padding * 2
        try EditorGeometry.validateDimensions(width: width, height: height, pixels: 64_000_000)
        let sanitizedContext = try context(width: document.source.width, height: document.source.height)
        sanitizedContext.draw(document.source, in: bounds)
        // Fill using copy blend mode and integer expanded bounds: even translucent input is opaque.
        sanitizedContext.setBlendMode(.copy)
        sanitizedContext.setShouldAntialias(false)
        sanitizedContext.setFillColor(EditorColor.black.cgColor)
        for annotation in document.edits.annotations where annotation.kind == .redact {
            let rect = EditorGeometry.pixelRect(annotation.rect, bounds: bounds)
            guard !rect.isNull, !rect.isEmpty else { continue }
            sanitizedContext.fill(CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height))
        }
        guard let sanitized = sanitizedContext.makeImage(), let cropped = sanitized.cropping(to: crop) else { throw EditorError.render }
        let imageContext = try context(width: Int(crop.width), height: Int(crop.height))
        imageContext.draw(cropped, in: CGRect(origin: .zero, size: crop.size))
        // Visual obscuring samples ONLY the sanitized, cropped image, never the original.
        let ciContext = CIContext(options: [.cacheIntermediates: false])
        for annotation in document.edits.annotations where annotation.kind == .blur || annotation.kind == .pixelate {
            try Task.checkCancellation()
            let sourceRect = annotation.rect.intersection(crop)
            guard !sourceRect.isNull, !sourceRect.isEmpty else { continue }
            let rect = CGRect(x: sourceRect.minX - crop.minX, y: crop.maxY - sourceRect.maxY, width: sourceRect.width, height: sourceRect.height)
            let input = CIImage(cgImage: cropped)
            let filtered = privacyFilter(annotation, input:input, pixelScale:pixelScale, effectScale:effectScale)
            let effectBounds = rect.integral.intersection(input.extent)
            guard let image = ciContext.createCGImage(filtered, from: effectBounds) else { throw EditorError.render }
            imageContext.saveGState(); imageContext.clip(to: rect)
            imageContext.draw(image, in: effectBounds); imageContext.restoreGState()
        }
        guard let shadowSource = imageContext.makeImage() else { throw EditorError.render }
        // Top-left coordinates for vectors; crop clips every edit.
        imageContext.saveGState(); imageContext.translateBy(x: -crop.minX, y: crop.height + crop.minY); imageContext.scaleBy(x: 1, y: -1)
        for annotation in document.edits.annotations where includesVectors && ![.redact, .blur, .pixelate].contains(annotation.kind) {
            try Task.checkCancellation()
            var luminance = 1.0
            var highlight = HighlightTreatment(blendMode: .multiply, opacity: 0.6)
            if (annotation.kind == .highlight || annotation.kind == .text),
               let underlay = imageContext.makeImage()?.cropping(to: annotation.rect.intersection(crop).offsetBy(dx: -crop.minX, dy: -crop.minY)) {
                luminance = try meanLuminance(underlay)
                if annotation.kind == .highlight {
                    highlight = try highlightTreatment(underlay, color: annotation.style.color, pixelScale: pixelScale)
                }
            }
            draw(annotation, context: imageContext, pixelScale: pixelScale, underlyingLuminance: luminance, highlightTreatment: highlight)
        }
        imageContext.restoreGState()
        guard let image = imageContext.makeImage() else { throw EditorError.render }
        try Task.checkCancellation()
        let output = try context(width: width, height: height)
        let destination = try prepareBackground(document, context: output, clipSource: false, shadowSource: shadowSource, ciContext: ciContext)
        let backdrop = !includesVectors && background.preset != .none ? output.makeImage() : nil
        var sourceClip: CGImage?
        if !includesVectors && (background.preset != .none || background.imageCorners == .rounded) {
            guard let mask = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { throw EditorError.render }
            clipSource(document, context: mask, destination: destination)
            mask.setFillColor(CGColor(gray: 1, alpha: 1)); mask.fill(CGRect(x: 0, y: 0, width: width, height: height))
            sourceClip = mask.makeImage()
        }
        clipSource(document, context: output, destination: destination)
        output.draw(image, in: destination)
        guard let result = output.makeImage() else { throw EditorError.render }
        let scaleX = document.pointSize.width / CGFloat(document.source.width), scaleY = document.pointSize.height / CGFloat(document.source.height)
        return EditorRenderComposition(rendered: EditorRendered(image: result, pointSize: CGSize(width: CGFloat(width) * scaleX, height: CGFloat(height) * scaleY)), underlay: image, backdrop: backdrop, sourceClip: sourceClip, privacySource:includesVectors ? nil : cropped)
    }

    static func privacyFilter(_ annotation:EditorAnnotation, input:CIImage, pixelScale:CGSize, effectScale:CGFloat) -> CIImage {
        let name = annotation.kind == .blur ? "CIGaussianBlur" : "CIPixellate"
        let key = annotation.kind == .blur ? kCIInputRadiusKey : kCIInputScaleKey
        var parameters:[String:Any] = [key:annotation.style.effectSize * effectScale]
        if annotation.kind == .pixelate, let center = CIFilter(name:name)?.value(forKey:kCIInputCenterKey) as? CIVector {
            parameters[kCIInputCenterKey] = CIVector(x:center.x * pixelScale.width,y:center.y * pixelScale.height)
        }
        return input.clampedToExtent().applyingFilter(name,parameters:parameters).cropped(to:input.extent)
    }

    /// The card and the source have independent corner policies. Auto and Square
    /// preserve the original alpha; missing corner pixels cannot be reconstructed.
    @discardableResult static func prepareBackground(_ document: EditorDocument, context output: CGContext, presentationScale: CGFloat = 1, clipSource: Bool = true, shadowSource: CGImage? = nil, ciContext: CIContext? = nil) throws -> CGRect {
        let crop = document.edits.crop.integral, background = document.edits.background
        let padding = background.preset == .none ? 0 : ceil(background.padding + background.frameWidth)
        let bounds = CGRect(x: 0, y: 0, width: crop.width + padding * 2, height: crop.height + padding * 2)
        output.saveGState()
        if background.preset != .none {
            output.addPath(CGPath(roundedRect: bounds, cornerWidth: background.cornerRadius, cornerHeight: background.cornerRadius, transform: nil)); output.clip()
            let first = background.preset == .graphite ? EditorColor(red: 0.10, green: 0.11, blue: 0.13) : background.color
            output.setFillColor(first.cgColor); output.fill(bounds)
            if background.preset == .gradient, let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [first.cgColor, EditorColor(red: 0.60, green: 0.67, blue: 0.79).cgColor] as CFArray, locations: [0, 1]) {
                output.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: bounds.width, y: bounds.height), options: [])
            }
        }
        let destination = CGRect(x: padding, y: padding, width: crop.width, height: crop.height)
        if background.preset != .none {
            if background.shadow, let shadowSource {
                var silhouette = shadowSource
                if background.imageCorners == .rounded {
                    let sourceContext = try context(width: shadowSource.width, height: shadowSource.height)
                    Self.clipSource(document, context: sourceContext, destination: CGRect(origin: .zero, size: crop.size))
                    sourceContext.draw(shadowSource, in: CGRect(origin: .zero, size: crop.size))
                    guard let masked = sourceContext.makeImage() else { throw EditorError.render }
                    silhouette = masked
                }
                // Only the sanitized source alpha contributes to the shadow;
                // source color is never painted into the backdrop or duplicated.
                let shadow = CIImage(cgImage: silhouette).applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x:0,y:0,z:0,w:0), "inputGVector": CIVector(x:0,y:0,z:0,w:0),
                    "inputBVector": CIVector(x:0,y:0,z:0,w:0), "inputAVector": CIVector(x:0,y:0,z:0,w:0.25)])
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey:12])
                    .transformed(by: CGAffineTransform(translationX:padding,y:padding-4))
                let renderer = ciContext ?? CIContext(options: [.cacheIntermediates:false])
                guard let shadowImage = renderer.createCGImage(shadow, from:bounds) else { throw EditorError.render }
                output.draw(shadowImage, in:bounds)
            }
            if background.frameWidth > 0 {
                let radius = sourceRadius(document)
                output.addPath(CGPath(roundedRect: destination.insetBy(dx: -background.frameWidth, dy: -background.frameWidth), cornerWidth: radius.width + background.frameWidth, cornerHeight: radius.height + background.frameWidth, transform: nil))
                output.addPath(CGPath(roundedRect: destination, cornerWidth: radius.width, cornerHeight: radius.height, transform: nil))
                output.setFillColor(EditorColor.black.cgColor); output.drawPath(using: .eoFill)
            }
        }
        output.restoreGState()
        if clipSource { Self.clipSource(document, context: output, destination: destination) }
        return destination
    }
    static func clipSource(_ document: EditorDocument, context: CGContext, destination: CGRect) {
        guard document.edits.background.imageCorners == .rounded else { return }
        let radius = sourceRadius(document)
        context.addPath(CGPath(roundedRect: destination, cornerWidth: radius.width, cornerHeight: radius.height, transform: nil)); context.clip()
    }
    private static func sourceRadius(_ document: EditorDocument) -> CGSize {
        guard document.edits.background.imageCorners == .rounded else { return .zero }
        return CGSize(width: 12 * CGFloat(document.source.width) / document.pointSize.width, height: 12 * CGFloat(document.source.height) / document.pointSize.height)
    }

    /// A short stored box must still contain the first line at its requested font size.
    static func textLayoutRect(_ annotation: EditorAnnotation, pixelScale: CGSize) -> CGRect {
        guard annotation.kind == .text else { return annotation.rect }
        let font = Theme.Font.ns.text(annotation.style.fontSize, weight: .semibold)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let inset: CGFloat = annotation.style.textBackground ? 8 : 0
        var rect = annotation.rect
        rect.size.height = max(rect.height,ceil((lineHeight + inset) * pixelScale.height))
        return rect
    }
    static func textLayoutRect(_ annotation: EditorAnnotation, document: EditorDocument) -> CGRect {
        textLayoutRect(annotation,pixelScale:CGSize(width:CGFloat(document.source.width)/document.pointSize.width,height:CGFloat(document.source.height)/document.pointSize.height))
    }
    /// All presentation widths/fonts/shadows are points; persistent rectangles remain source pixels.
    static func draw(_ annotation: EditorAnnotation, context: CGContext, pixelScale: CGSize = CGSize(width: 1, height: 1), underlyingLuminance: Double = 1, highlightTreatment: HighlightTreatment = HighlightTreatment(blendMode: .multiply, opacity: 0.6), presentationScale: CGFloat = 1) {
        context.saveGState(); defer { context.restoreGState() }
        context.scaleBy(x: pixelScale.width, y: pixelScale.height)
        let source = textLayoutRect(annotation,pixelScale:pixelScale)
        let rect = CGRect(x: source.minX / pixelScale.width, y: source.minY / pixelScale.height,
                          width: source.width / pixelScale.width, height: source.height / pixelScale.height)
        let style = annotation.style, width = CGFloat(style.lineWidth)
        context.setStrokeColor(style.color.cgColor); context.setFillColor(style.color.cgColor)
        context.setLineWidth(width); context.setLineCap(.round); context.setLineJoin(.round)
        // Quartz shadows use base-space distances, independent of the drawing CTM.
        context.setShadow(offset: CGSize(width: 0, height: pixelScale.height * presentationScale), blur: 3 * sqrt(pixelScale.width * pixelScale.height) * presentationScale,
                          color: CGColor(gray: 0, alpha: 0.28))
        switch annotation.kind {
        case .rectangle:
            let radius = min(width * 1.5, min(rect.width, rect.height) / 2)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
        case .highlight:
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setBlendMode(highlightTreatment.blendMode)
            context.setFillColor(style.color.cgColor)
            context.setAlpha(highlightTreatment.opacity)
            let radius = min(3, rect.height * 0.12)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        case .arrow:
            let endpoints = annotation.resolvedArrowEndpoints
            let start = CGPoint(x: endpoints.start.x / pixelScale.width, y: endpoints.start.y / pixelScale.height)
            let end = CGPoint(x: endpoints.end.x / pixelScale.width, y: endpoints.end.y / pixelScale.height)
            context.addPath(arrowPath(from: start, to: end, width: width))
            context.fillPath()
        case .text:
            context.setShadow(offset: CGSize(width: 0, height: pixelScale.height * presentationScale), blur: 2 * sqrt(pixelScale.width * pixelScale.height) * presentationScale, color: CGColor(gray: 0, alpha: 0.35))
            if style.textBackground {
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)); context.fillPath()
                context.setShadow(offset: .zero, blur: 0, color: nil)
                drawText(annotation.text, rect: rect.insetBy(dx: 8, dy: 4), size: style.fontSize, color: CGColor(gray: 1, alpha: 1), context: context)
            } else {
                drawText(annotation.text, rect: rect, size: style.fontSize, color: style.color.cgColor, context: context, outlined: underlyingLuminance > 0.5)
            }
        case .step:
            let diameter = min(rect.width, rect.height)
            let circle = CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)
            context.fillEllipse(in: circle)
            context.setShadow(offset: .zero, blur: 0)
            context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(2)
            context.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))
            drawText(String(annotation.stepNumber), rect: circle,
                     size: min(diameter * 0.65, style.fontSize), color: CGColor(gray: 1, alpha: 1),
                     context: context, centered: true)
        default: break
        }
    }

    /// A single rounded filled silhouette: the shaft joins the head base and never reaches the tip.
    static func arrowPath(from start: CGPoint, to end: CGPoint, width: CGFloat) -> CGPath {
        let dx = end.x - start.x, dy = end.y - start.y, length = hypot(dx, dy)
        guard length > 0, width > 0 else { return CGMutablePath() }
        let u = CGPoint(x: dx / length, y: dy / length), n = CGPoint(x: -u.y, y: u.x)
        let headHalf = min(width * 1.85, length * 0.35)
        let headLength = min(width * 3, length * 0.65)
        let base = CGPoint(x: end.x - u.x * headLength, y: end.y - u.y * headLength)
        func offset(_ p: CGPoint, _ d: CGFloat) -> CGPoint { CGPoint(x: p.x + n.x * d, y: p.y + n.y * d) }
        let points = [offset(start, width * 0.2), offset(base, width * 0.5), offset(base, headHalf), end,
                      offset(base, -headHalf), offset(base, -width * 0.5), offset(start, -width * 0.2)]
        let path = CGMutablePath()
        let round = min(width * 0.16, length * 0.02)
        func corner(_ index: Int) -> (CGPoint, CGPoint) {
            let p = points[index], before = points[(index + points.count - 1) % points.count], after = points[(index + 1) % points.count]
            func toward(_ q: CGPoint) -> CGPoint {
                let distance = hypot(q.x - p.x, q.y - p.y), amount = min(round, distance / 3)
                return CGPoint(x: p.x + (q.x - p.x) * amount / max(distance, 0.0001),
                               y: p.y + (q.y - p.y) * amount / max(distance, 0.0001))
            }
            return (toward(before), toward(after))
        }
        path.move(to: corner(0).1)
        for index in 1...points.count {
            let i = index % points.count, c = corner(i)
            path.addLine(to: c.0); path.addQuadCurve(to: c.1, control: points[i])
        }
        path.closeSubpath()
        return path
    }

    private static func drawText(_ text: String, rect: CGRect, size: CGFloat, color: CGColor,
                                 context: CGContext, centered: Bool = false, outlined: Bool = false) {
        let font = Theme.Font.ns.text(size, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        context.saveGState(); defer { context.restoreGState() }
        // CoreText is y-up; the editor vectors are top-left, y-down.
        context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        if centered {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let glyphs = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            context.textPosition = CGPoint(x: (rect.width - glyphs.width) / 2 - glyphs.minX,
                                           y: (rect.height - glyphs.height) / 2 - glyphs.minY)
            CTLineDraw(line, context)
        } else {
            let string = NSAttributedString(string: text, attributes: attributes)
            let setter = CTFramesetterCreateWithAttributedString(string)
            let path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
            if outlined {
                let components = color.components ?? [1, 1, 1, 1]
                let light = components.prefix(3).reduce(0, +) / 3 > 0.5
                var outlineAttributes = attributes
                outlineAttributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = 75 / size
                outlineAttributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = CGColor(gray: light ? 0 : 1, alpha: 0.95)
                let outline = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: outlineAttributes))
                context.saveGState(); context.setShadow(offset: .zero, blur: 0, color: nil)
                CTFrameDraw(CTFramesetterCreateFrame(outline, CFRange(), path, nil), context)
                context.restoreGState()
            }
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), path, nil), context)
        }
    }

    static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    static func meanLuminance(_ image: CGImage) throws -> Double {
        let sample = try context(width: min(image.width, 64), height: min(image.height, 64))
        sample.draw(image, in: CGRect(x: 0, y: 0, width: sample.width, height: sample.height))
        guard let data = sample.data?.assumingMemoryBound(to: UInt8.self) else { throw EditorError.render }
        var sum = 0.0
        for y in 0..<sample.height { for x in 0..<sample.width {
            let offset = y * sample.bytesPerRow + x * 4
            sum += relativeLuminance(red: Double(data[offset]) / 255, green: Double(data[offset + 1]) / 255, blue: Double(data[offset + 2]) / 255)
        } }
        return sum / Double(sample.width * sample.height)
    }

    struct HighlightTreatment { let blendMode: CGBlendMode; let opacity: Double }
    /// Histogram mode estimates the background; minority repeated extremes estimate core-ink polarity.
    /// No text recognition or source-pixel replacement is involved.
    static func highlightTreatment(_ image: CGImage, color: EditorColor, pixelScale: CGSize) throws -> HighlightTreatment {
        let sample = try context(width: min(image.width, 512), height: min(image.height, 256))
        sample.draw(image, in: CGRect(x: 0, y: 0, width: sample.width, height: sample.height))
        guard let bytes = sample.data?.assumingMemoryBound(to: UInt8.self) else { throw EditorError.render }
        struct Pixel { let rgb: [Double]; let luminance: Double; let key: Int }
        var pixels: [Pixel] = [], frequency: [Int: Int] = [:], histogram = [Int](repeating: 0, count: 16)
        for y in 0..<sample.height { for x in 0..<sample.width {
            let offset = y * sample.bytesPerRow + x * 4
            let rgb = (0..<3).map { Double(bytes[offset + $0]) / 255 }
            let key = Int(bytes[offset]) << 16 | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            let luminance = relativeLuminance(red: rgb[0], green: rgb[1], blue: rgb[2])
            pixels.append(Pixel(rgb: rgb, luminance: luminance, key: key))
            histogram[min(15, Int(luminance * 16))] += 1
            frequency[key, default: 0] += 1
        } }
        let minimumCount = max(4, pixels.count / 512)
        let modalBin = histogram.indices.max(by: { histogram[$0] < histogram[$1] }) ?? 0
        let modalPixels = pixels.filter { min(15, Int($0.luminance * 16)) == modalBin }
        let backgroundLuminance = modalPixels.reduce(0) { $0 + $1.luminance } / Double(max(1, modalPixels.count))
        let backgroundIsUniform = (modalPixels.map { frequency[$0.key, default: 0] }.max() ?? 0) * 2 >= modalPixels.count
        let repeated = pixels.filter { frequency[$0.key, default: 0] >= minimumCount && frequency[$0.key, default: 0] < pixels.count / 5 }
        let dark = repeated.min(by: { $0.luminance < $1.luminance }).flatMap { $0.luminance < backgroundLuminance - 0.12 ? $0 : nil }
        let light = repeated.max(by: { $0.luminance < $1.luminance }).flatMap { $0.luminance > backgroundLuminance + 0.12 ? $0 : nil }
        var cores: Set<Int> = []
        if let dark { cores.insert(dark.key) }; if let light { cores.insert(light.key) }
        let darkCount = dark.map { frequency[$0.key, default: 0] } ?? 0
        let lightCount = light.map { frequency[$0.key, default: 0] } ?? 0
        let mode: CGBlendMode = lightCount > darkCount ? .normal : .multiply
        let radiusX = max(2, Int((14 * pixelScale.width * CGFloat(sample.width) / CGFloat(image.width)).rounded()))
        let radiusY = max(2, Int((14 * pixelScale.height * CGFloat(sample.height) / CGFloat(image.height)).rounded()))
        let offsets = [(0, -radiusY), (0, radiusY), (-radiusX, 0), (radiusX, 0)]
        let fill = [color.red, color.green, color.blue]
        func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        func mixed(_ pixel: Pixel, alpha: Double) -> Double {
            let amount = alpha * color.alpha
            let rgb = (0..<3).map { pixel.rgb[$0] * (1 - amount) + (mode == .multiply ? pixel.rgb[$0] * fill[$0] : fill[$0]) * amount }
            return relativeLuminance(red: rgb[0], green: rgb[1], blue: rgb[2])
        }
        var cap = cores.isEmpty ? 0.6 : (mode == .normal ? 0.32 : 1)
        for y in 0..<sample.height { for x in 0..<sample.width {
            let ink = pixels[y * sample.width + x]
            guard cores.contains(ink.key) else { continue }
            for (dx, dy) in offsets {
                let bx = x + dx, by = y + dy
                guard bx >= 0, bx < sample.width, by >= 0, by < sample.height else { continue }
                let background = pixels[by * sample.width + bx]
                // Reject neighboring ink/antialias samples; compare a core against background-mode pixels.
                if mode == .multiply && !backgroundIsUniform {
                    guard background.luminance > ink.luminance + 0.12 else { continue }
                } else {
                    guard abs(background.luminance - backgroundLuminance) <= 0.03125 else { continue }
                }
                let sourceContrast = contrast(ink.luminance, background.luminance)
                if mode == .multiply && sourceContrast < 4.5 { continue }
                let target = sourceContrast >= 4.5 ? min(sourceContrast, 4.55) : sourceContrast
                guard contrast(mixed(ink, alpha: cap), mixed(background, alpha: cap)) < target else { continue }
                var low = 0.0, high = cap
                for _ in 0..<14 {
                    let candidate = (low + high) / 2
                    if contrast(mixed(ink, alpha: candidate), mixed(background, alpha: candidate)) >= target { low = candidate }
                    else { high = candidate }
                }
                cap = low
            }
        } }
        let opacity = mode == .multiply && dark != nil ? max(0.35, cap) : cap
        return HighlightTreatment(blendMode: mode, opacity: opacity)
    }

    static func sample(_ image: CGImage, at point: CGPoint) throws -> String {
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0, point.x < CGFloat(image.width), point.y < CGFloat(image.height), let pixel = image.cropping(to: CGRect(x: Int(point.x), y: Int(point.y), width: 1, height: 1)) else { throw EditorError.invalidEdits }
        let context = try context(width: 1, height: 1); context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw EditorError.render }
        let alpha = Double(bytes[3]) / 255
        let values = (0..<3).map { alpha > 0 ? min(255, Int((Double(bytes[$0]) / alpha).rounded())) : 0 }
        return String(format: "#%02X%02X%02X", values[0], values[1], values[2])
    }
}
