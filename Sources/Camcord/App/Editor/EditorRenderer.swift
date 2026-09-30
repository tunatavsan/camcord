import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Foundation
import Darwin

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
        try Task.checkCancellation()
        guard document.edits.valid else { throw EditorError.invalidEdits }
        try EditorGeometry.validateDimensions(width: document.source.width, height: document.source.height, pixels: 50_000_000)
        let bounds = document.bounds
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
            let name = annotation.kind == .blur ? "CIGaussianBlur" : "CIPixellate"
            let key = annotation.kind == .blur ? kCIInputRadiusKey : kCIInputScaleKey
            let filtered = input.clampedToExtent().applyingFilter(name, parameters: [key: annotation.style.effectSize]).cropped(to: input.extent)
            let effectBounds = rect.integral.intersection(input.extent)
            guard let image = ciContext.createCGImage(filtered, from: effectBounds) else { throw EditorError.render }
            imageContext.saveGState(); imageContext.clip(to: rect)
            imageContext.draw(image, in: effectBounds); imageContext.restoreGState()
        }
        // Top-left coordinates for vectors; crop clips every edit.
        imageContext.saveGState(); imageContext.translateBy(x: -crop.minX, y: crop.height + crop.minY); imageContext.scaleBy(x: 1, y: -1)
        for annotation in document.edits.annotations where ![.redact, .blur, .pixelate].contains(annotation.kind) {
            try Task.checkCancellation()
            draw(annotation, context: imageContext)
        }
        imageContext.restoreGState()
        guard let image = imageContext.makeImage() else { throw EditorError.render }
        try Task.checkCancellation()
        let output = try context(width: width, height: height)
        let outBounds = CGRect(x: 0, y: 0, width: width, height: height)
        if background.preset != .none {
            let first = background.preset == .graphite ? EditorColor(red: 0.10, green: 0.11, blue: 0.13) : background.color
            output.setFillColor(first.cgColor); output.fill(outBounds)
            if background.preset == .gradient, let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [first.cgColor, EditorColor(red: 0.60, green: 0.67, blue: 0.79).cgColor] as CFArray, locations: [0, 1]) {
                output.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
            }
        }
        let destination = CGRect(x: CGFloat(padding), y: CGFloat(padding), width: crop.width, height: crop.height)
        if background.preset != .none {
            let path = CGPath(roundedRect: destination.insetBy(dx: -background.frameWidth, dy: -background.frameWidth), cornerWidth: background.cornerRadius, cornerHeight: background.cornerRadius, transform: nil)
            if background.shadow { output.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: CGColor(gray: 0, alpha: 0.25)) }
            output.addPath(path); output.setFillColor(EditorColor.black.cgColor); output.fillPath(); output.setShadow(offset: .zero, blur: 0)
            output.addPath(CGPath(roundedRect: destination, cornerWidth: background.cornerRadius, cornerHeight: background.cornerRadius, transform: nil)); output.clip()
        }
        output.draw(image, in: destination)
        guard let result = output.makeImage() else { throw EditorError.render }
        let scaleX = document.pointSize.width / CGFloat(document.source.width), scaleY = document.pointSize.height / CGFloat(document.source.height)
        return EditorRendered(image: result, pointSize: CGSize(width: CGFloat(width) * scaleX, height: CGFloat(height) * scaleY))
    }

    private static func draw(_ annotation: EditorAnnotation, context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        let rect = annotation.rect, style = annotation.style
        context.setStrokeColor(style.color.cgColor); context.setFillColor(style.color.cgColor); context.setLineWidth(style.lineWidth); context.setLineCap(.round); context.setLineJoin(.round)
        switch annotation.kind {
        case .rectangle: context.stroke(rect)
        case .highlight: context.setAlpha(0.30 * style.color.alpha); context.fill(rect)
        case .arrow:
            let start = CGPoint(x: annotation.verticalArrow ? rect.midX : (annotation.reversedX ? rect.maxX : rect.minX), y: annotation.horizontalArrow ? rect.midY : (annotation.reversedY ? rect.maxY : rect.minY))
            let end = CGPoint(x: annotation.verticalArrow ? rect.midX : (annotation.reversedX ? rect.minX : rect.maxX), y: annotation.horizontalArrow ? rect.midY : (annotation.reversedY ? rect.minY : rect.maxY))
            let angle = atan2(end.y - start.y, end.x - start.x), size = max(12, style.lineWidth * 4)
            context.move(to: start); context.addLine(to: end); context.strokePath()
            context.move(to: end); context.addLine(to: CGPoint(x: end.x - cos(angle - .pi / 6) * size, y: end.y - sin(angle - .pi / 6) * size)); context.addLine(to: CGPoint(x: end.x - cos(angle + .pi / 6) * size, y: end.y - sin(angle + .pi / 6) * size)); context.closePath(); context.fillPath()
        case .text: drawText(annotation.text, rect: rect, size: style.fontSize, color: style.color.cgColor, context: context)
        case .step:
            context.fillEllipse(in: rect)
            drawText(String(annotation.stepNumber), rect: rect, size: min(rect.height * 0.65, style.fontSize), color: EditorColor.paper.cgColor, context: context, centered: true)
        default: break
        }
    }
    private static func drawText(_ text: String, rect: CGRect, size: CGFloat, color: CGColor, context: CGContext, centered: Bool = false) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
        let line = CTLineCreateWithAttributedString(string)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.saveGState(); context.translateBy(x: rect.minX, y: rect.minY + (centered ? (rect.height + size * 0.7) / 2 : size)); context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: centered ? (rect.width - width) / 2 : 0, y: 0); CTLineDraw(line, context); context.restoreGState()
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
