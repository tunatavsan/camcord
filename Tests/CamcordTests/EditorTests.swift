import AppKit
import CoreGraphics
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import SwiftUI
import Testing
@testable import Camcord

@Suite("Editor contextual control layout", .serialized) @MainActor
struct EditorControlLayoutTests {
    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
    }
    @Test("Fit reserves the measured production capsule for every tool and selected content through resize")
    func measuredCapsuleFit() async throws {
        let session = EditorSession()
        let image = try EditorRendererTests.image(width: 480, height: 300)
        session.open(CapturedScreenshot(id: UUID(), image: image, pointSize: CGSize(width: 480, height: 300), kind: .screenshot, saveToDiskRequested: false))
        await session.waitForRendering()
        let host = NSHostingController(rootView: EditorWorkspace(session: session, services: nil))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 580), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = host
        defer { session.stop(); window.close() }
        for tool in EditorTool.allCases {
            session.selectedID = nil; session.tool = tool
            if tool == .text || tool == .step {
                session.add(tool: tool, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 100))
            }
            for size in [CGSize(width: 800, height: 580), CGSize(width: 640, height: 480)] {
                window.setContentSize(size)
                for _ in 0..<4 {
                    host.view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                }
                let scroll = try #require(descendants(host.view, of: EditorScrollNSView.self).first)
                let canvas = try #require(scroll.documentView as? EditorCanvasNSView)
                let showsStyle = session.selectedAnnotation != nil || tool != .select && tool != .crop
                if showsStyle {
                    let capsule = NSHostingView(rootView: EditorStyleCapsule(session: session))
                    let actualHeight = capsule.fittingSize.height
                    #expect(actualHeight > 0)
                    #expect(abs(scroll.fitTopClearance - (Theme.Space.m + actualHeight + 8)) < 0.001)
                    let imageRect = scroll.convert(CGRect(origin: canvas.imageOrigin, size: canvas.imageSize), from: canvas)
                    #expect(imageRect.minY + 0.001 >= scroll.fitTopClearance)
                    #expect(imageRect.maxY <= scroll.contentSize.height - Theme.Editor.canvasMargin + 1)
                } else {
                    #expect(scroll.fitTopClearance == 0 && canvas.fitTopInset == 0)
                }
                session.fitZoom = false
                for scale in [CGFloat(1), CGFloat(2)] {
                    session.reportBackingScale(scale); session.zoom = session.actualPixelZoom
                    scroll.synchronize(viewport: scroll.contentSize)
                    #expect(scroll.magnification == 1 / scale && canvas.fitTopInset == 0)
                }
                canvas.viewDidChangeBackingProperties()
                #expect(session.backingScale == window.backingScaleFactor && canvas.fitTopInset == 0)
                session.fitZoom = true
            }
        }
        #expect(!window.isVisible)
    }
    @Test("Native custom color well has swatch dimensions, circular hit bounds and a working color action")
    func nativeColorWell() async throws {
        let session = EditorSession()
        session.open(CapturedScreenshot(id: UUID(), image: try EditorRendererTests.image(), pointSize: CGSize(width: 8, height: 6), kind: .screenshot, saveToDiskRequested: false))
        await session.waitForRendering()
        session.add(tool: .rectangle, from: .zero, to: CGPoint(x: 6, y: 5))
        defer { session.stop() }
        let host = NSHostingView(rootView: EditorStyleCapsule(session: session))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let well = try #require(descendants(host, of: EditorContinuousColorWell.self).first)
        #expect(well.intrinsicContentSize == CGSize(width: 16, height: 16))
        #expect(well.frame.size == CGSize(width: Theme.Editor.swatchSize, height: Theme.Editor.swatchSize))
        #expect(well.accessibilityLabel() == String(localized: "Custom color"))
        #expect(well.colorWellStyle == .minimal && well.supportsAlpha)
        #expect(well.hitTest(well.frame.origin) == nil)
        #expect(well.hitTest(CGPoint(x: well.frame.midX, y: well.frame.midY)) === well)
        let custom = NSColor(srgbRed: 0.2, green: 0.3, blue: 0.8, alpha: 0.6)
        well.color = custom
        #expect(well.sendAction(well.action, to: well.target))
        let selected = try #require(session.selectedAnnotation)
        #expect(abs(selected.style.color.red - 0.2) < 0.001 && abs(selected.style.color.alpha - 0.6) < 0.001)
        #expect(selected.style.color == session.style.color)
        session.undo()
        #expect(session.selectedAnnotation?.style.color != selected.style.color)
    }
}

@Suite("Screenshot editor pixels and privacy")
struct EditorRendererTests {
    @Test("Default semibold text on an actual dark underlay has colored glyphs and no light contrast outline")
    func darkTextWithoutOutline() throws {
        let context = try EditorRenderer.context(width: 180, height: 80)
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 180, height: 80))
        var document = try EditorDocument(source: #require(context.makeImage()))
        document.edits.annotations = [EditorAnnotation(kind: .text, rect: CGRect(x: 8, y: 8, width: 164, height: 64), text: "Ready")]
        let image = try EditorRenderer.render(document).image
        let output = try EditorRenderer.context(width: 180, height: 80)
        output.draw(image, in: CGRect(x: 0, y: 0, width: 180, height: 80))
        let bytes = try #require(output.data?.assumingMemoryBound(to: UInt8.self))
        var colored = 0, lightOutline = 0
        for y in 0..<80 { for x in 0..<180 {
            let offset = y * output.bytesPerRow + x * 4
            if bytes[offset] > 120 && bytes[offset + 1] < 100 && bytes[offset + 2] < 100 { colored += 1 }
            if min(bytes[offset], bytes[offset + 1], bytes[offset + 2]) > 120 { lightOutline += 1 }
        } }
        #expect(colored > 20 && lightOutline == 0)
    }
    @Test("Actual sheet light, dark and busy source glyph contrast survives Highlight at both densities", arguments: [0, 1, 2], [1, 2])
    func sheetHighlightContrast(background: Int, scale: Int) throws {
        let source = try ShellAnnotationSheet.background(kind: background, scale: scale, size: CGSize(width: 280, height: 140))
        var document = try EditorDocument(source: source, pointSize: CGSize(width: 280, height: 140))
        let rect = CGRect(x: 20 * scale, y: 54 * scale, width: 240 * scale, height: 27 * scale)
        document.edits.annotations = [EditorAnnotation(kind: .highlight, rect: rect, style: EditorStyle(color: EditorRenderer.markerColor))]
        let image = try EditorRenderer.render(document).image
        let underlay = try #require(source.cropping(to: rect))
        let treatment = try EditorRenderer.highlightTreatment(underlay, color: EditorRenderer.markerColor, pixelScale: CGSize(width: scale, height: scale))
        func luminance(_ image: CGImage, _ x: Int, _ y: Int) throws -> Double {
            let hex = try EditorRenderer.sample(image, at: CGPoint(x: x * scale, y: y * scale))
            let channels = try [1, 3, 5].map { Double(try #require(Int(hex.dropFirst($0).prefix(2), radix: 16))) / 255 }
            return EditorRenderer.relativeLuminance(red: channels[0], green: channels[1], blue: channels[2])
        }
        func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        let core = try EditorRenderer.sample(source, at: CGPoint(x: 110 * scale, y: 71 * scale))
        var count = 0, qualifying = 0, floorExceptions = 0, lower = 0
        var minimumQualifyingSource = Double.infinity, minimumQualifyingAfter = Double.infinity
        for y in 65..<79 { for x in 20..<260 {
            guard try EditorRenderer.sample(source, at: CGPoint(x: x * scale, y: y * scale)) == core else { continue }
            let before = try contrast(luminance(source, x, y), luminance(source, x, 57))
            let after = try contrast(luminance(image, x, y), luminance(image, x, 57))
            count += 1
            if before >= 4.5 {
                qualifying += 1; minimumQualifyingSource = min(minimumQualifyingSource, before); minimumQualifyingAfter = min(minimumQualifyingAfter, after)
                if after < 4.5 {
                    floorExceptions += 1
                    #expect(abs(treatment.opacity - 0.35) < 0.000001)
                }
            } else { lower += 1 }
        } }
        #expect(count > 20 && qualifying > 20)
        if background != 2 { #expect(treatment.opacity >= 0.2) }
        else { #expect(treatment.opacity >= 0.35) }
        print("Editor actual sheet background \(background) at \(scale)x: corePairs=\(count), qualifying=\(qualifying), lower=\(lower), floorExceptions=\(floorExceptions), minQualifyingSource=\(minimumQualifyingSource), minQualifyingAfter=\(minimumQualifyingAfter), opacity=\(treatment.opacity), mode=\(treatment.blendMode.rawValue)")
    }
    @Test("Multiply Highlight preserves the source red channel and dark text at real point density", arguments: [1, 2])
    func multiplyHighlight(scale: Int) throws {
        let context = try EditorRenderer.context(width: 80 * scale, height: 48 * scale)
        context.setFillColor(CGColor(red: 249.0 / 255, green: 249.0 / 255, blue: 249.0 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80 * scale, height: 48 * scale))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 20 * scale, y: 20 * scale, width: 8 * scale, height: 8 * scale))
        for color in [EditorRenderer.markerColor, EditorColor(red: 1, green: 0.5, blue: 0.2, alpha: 0.5)] {
            var document = try EditorDocument(source: #require(context.makeImage()), pointSize: CGSize(width: 80, height: 48))
            document.edits.annotations = [EditorAnnotation(kind: .highlight,
                rect: CGRect(x: 4 * scale, y: 4 * scale, width: 72 * scale, height: 40 * scale), style: EditorStyle(color: color))]
            let image = try EditorRenderer.render(document).image
            let sample = try EditorRenderer.sample(image, at: CGPoint(x: 40 * scale, y: 24 * scale))
            let red = try #require(Int(sample.dropFirst().prefix(2), radix: 16))
            let green = try #require(Int(sample.dropFirst(3).prefix(2), radix: 16))
            let blue = try #require(Int(sample.dropFirst(5).prefix(2), radix: 16))
            let alpha = color.alpha
            #expect(abs(red - 249) <= 1)
            #expect(abs(green - Int((249 * (1 - alpha + alpha * color.green)).rounded())) <= 2)
            #expect(abs(blue - Int((249 * (1 - alpha + alpha * color.blue)).rounded())) <= 2)
            #expect(try EditorRenderer.sample(image, at: CGPoint(x: 24 * scale, y: 24 * scale)) == "#000000")
        }
    }
    @Test("Arrow fill tapers into its head without a round shaft cap beyond the tip; Retina preserves point weight")
    func arrowHeadAndPointWeight() throws {
        func rendered(scale: Int) throws -> EditorRendered {
            let source = try EditorRenderer.context(width: 160 * scale, height: 80 * scale)
            source.setFillColor(CGColor(gray: 1, alpha: 1)); source.fill(CGRect(x: 0, y: 0, width: 160 * scale, height: 80 * scale))
            var document = try EditorDocument(source: #require(source.makeImage()), pointSize: CGSize(width: 160, height: 80))
            document.edits.annotations = [EditorAnnotation(kind: .arrow,
                rect: CGRect(x: 20 * scale, y: 40 * scale, width: 100 * scale, height: scale), horizontalArrow: true)]
            return try EditorRenderer.render(document)
        }
        func redPixels(_ image: CGImage) throws -> [CGPoint] {
            let bitmap = try EditorRenderer.context(width: image.width, height: image.height)
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let data = try #require(bitmap.data?.assumingMemoryBound(to: UInt8.self))
            return (0..<image.height).flatMap { y in
                (0..<image.width).compactMap { x in
                    let offset = y * bitmap.bytesPerRow + x * 4
                    return data[offset] > 150 && data[offset + 1] < 100 && data[offset + 2] < 120
                        ? CGPoint(x: x, y: y) : nil
                }
            }
        }
        let one = try redPixels(rendered(scale: 1).image), two = try redPixels(rendered(scale: 2).image)
        #expect(!one.isEmpty && !two.isEmpty)
        #expect(one.allSatisfy { $0.x < 120 })
        #expect(two.allSatisfy { $0.x < 240 })
        let oneWeight = one.filter { $0.x == 70 }.count, twoWeight = two.filter { $0.x == 140 }.count
        #expect(oneWeight >= 2)
        #expect(twoWeight >= oneWeight * 2 - 2)
        let head = EditorRenderer.arrowPath(from: CGPoint(x: 20, y: 40), to: CGPoint(x: 120, y: 40), width: 4)
        #expect(head.boundingBox.maxX <= 120)
        #expect(head.boundingBox.height >= 14 && head.boundingBox.height < 16)
        #expect(head.contains(CGPoint(x: 112, y: 40)))
    }
    @Test("Dark Highlight uses actual underlay luminance and keeps neutral source text above 4.5 contrast", arguments: [1, 2])
    func darkHighlightContrast(scale: Int) throws {
        let context = try EditorRenderer.context(width: 80 * scale, height: 48 * scale)
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 80 * scale, height: 48 * scale))
        context.setFillColor(CGColor(gray: 0.94, alpha: 1)); context.fill(CGRect(x: 20 * scale, y: 20 * scale, width: 8 * scale, height: 8 * scale))
        var document = try EditorDocument(source: #require(context.makeImage()), pointSize: CGSize(width: 80, height: 48))
        document.edits.annotations = [EditorAnnotation(kind: .highlight, rect: CGRect(x: 4 * scale, y: 4 * scale, width: 72 * scale, height: 40 * scale), style: EditorStyle(color: EditorRenderer.markerColor))]
        let image = try EditorRenderer.render(document).image
        func channels(_ point: CGPoint) throws -> [Double] {
            let hex = try EditorRenderer.sample(image, at: point)
            return try [1, 3, 5].map { Double(try #require(Int(hex.dropFirst($0).prefix(2), radix: 16))) / 255 }
        }
        let background = try channels(CGPoint(x: 40 * scale, y: 24 * scale)), text = try channels(CGPoint(x: 24 * scale, y: 24 * scale))
        let backgroundL = EditorRenderer.relativeLuminance(red: background[0], green: background[1], blue: background[2])
        let textL = EditorRenderer.relativeLuminance(red: text[0], green: text[1], blue: text[2])
        let contrast = (textL + 0.05) / (backgroundL + 0.05)
        #expect(contrast >= 4.5)
        print("Editor Highlight measured neutral-source contrast at \(scale)x: \(contrast)")
        #expect(background[0] > 0.3 && background[1] > 0.25)
        #expect(abs(background[0] - (0.1 * 0.68 + 0.32)) < 0.02)
    }
    @Test("Point-size effect parameters preserve actual blur and pixel-block footprint at Retina density", arguments: [EditorTool.blur, .pixelate])
    func effectPointDensity(tool: EditorTool) throws {
        if tool == .pixelate, let center = CIFilter(name: "CIPixellate")?.value(forKey: kCIInputCenterKey) as? CIVector {
            print("Editor current CoreImage pixelate default center: \(center.x), \(center.y)")
        }
        func rendered(scale: Int) throws -> CGImage {
            let context = try EditorRenderer.context(width: 96 * scale, height: 64 * scale)
            context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 96 * scale, height: 64 * scale))
            if tool == .pixelate {
                for x in 0..<96 {
                    let gray = Double(x) / 95
                    context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
                    context.fill(CGRect(x: x * scale, y: 0, width: scale, height: 64 * scale))
                }
            } else {
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 32 * scale, y: 0, width: 32 * scale, height: 64 * scale))
            }
            var document = try EditorDocument(source: #require(context.makeImage()), pointSize: CGSize(width: 96, height: 64))
            document.edits.annotations = [EditorAnnotation(kind: tool, rect: document.bounds, style: EditorStyle(effectSize: 12))]
            return try EditorRenderer.render(document).image
        }
        let one = try rendered(scale: 1), two = try rendered(scale: 2)
        let normalized = try EditorRenderer.context(width: 96, height: 64); normalized.interpolationQuality = .high
        normalized.draw(two, in: CGRect(x: 0, y: 0, width: 96, height: 64))
        let normalizedImage = try #require(normalized.makeImage())
        var error = 0
        for x in 8..<88 {
            let a = try #require(Int(try EditorRenderer.sample(one, at: CGPoint(x: x, y: 32)).dropFirst().prefix(2), radix: 16))
            let b = try #require(Int(try EditorRenderer.sample(normalizedImage, at: CGPoint(x: x, y: 32)).dropFirst().prefix(2), radix: 16))
            error += abs(a - b)
        }
        let meanError = Double(error) / 80
        print("Editor \(tool) actual normalized 1x/2x raster mean channel error: \(meanError)")
        #expect(meanError < 4)
    }
    static func image(width: Int = 16, height: Int = 12, secret: UInt8 = 255) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            bytes[offset] = x < width / 2 ? secret : 20
            bytes[offset + 1] = y < height / 2 ? 40 : 180
            bytes[offset + 2] = 70; bytes[offset + 3] = 255
        } }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    @Test("Source coordinates preserve asymmetric image orientation and crop density")
    func cropRetina() throws {
        var doc = try EditorDocument(source: Self.image(), pointSize: CGSize(width: 8, height: 6))
        let unchanged = try EditorRenderer.render(doc)
        #expect(try EditorRenderer.sample(unchanged.image, at: CGPoint(x: 0, y: 0)) == "#FF2846")
        #expect(try EditorRenderer.sample(unchanged.image, at: CGPoint(x: 15, y: 11)) == "#14B446")
        doc.edits.crop = CGRect(x: 8, y: 0, width: 8, height: 6)
        let result = try EditorRenderer.render(doc)
        #expect(result.image.width == 8); #expect(result.image.height == 6)
        #expect(result.pointSize == CGSize(width: 4, height: 3))
        #expect(try EditorRenderer.sample(result.image, at: CGPoint(x: 0, y: 0)) == "#142846")
    }
    @Test("All eight TIFF orientations normalize source pixels and swap density axes")
    func orientations() throws {
        let root = EditorTemporaryExports().directory.deletingLastPathComponent().appendingPathComponent("editor-orientation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let expected = ["#FF2846", "#142846", "#14B446", "#FFB446", "#FF2846", "#FFB446", "#14B446", "#142846"]
        for orientation in 1...8 {
            let url = root.appendingPathComponent("orientation-\(orientation).tiff")
            let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(writer, try Self.image(width: 4, height: 2), [kCGImagePropertyOrientation: orientation, kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 72] as CFDictionary)
            #expect(CGImageDestinationFinalize(writer))
            let document = try EditorRenderer.decode(url)
            #expect(document.source.width == (orientation < 5 ? 4 : 2)); #expect(document.source.height == (orientation < 5 ? 2 : 4))
            #expect(document.pointSize == CGSize(width: 2, height: 2))
            #expect(try EditorRenderer.sample(document.source, at: .zero) == expected[orientation - 1])
        }
    }
    @Test("Solid redact expands fractional bounds and makes every protected pixel opaque")
    func opaqueRedaction() throws {
        var doc = try EditorDocument(source: Self.image())
        doc.edits.annotations = [EditorAnnotation(kind: .redact, rect: CGRect(x: 1.2, y: 1.2, width: 3.3, height: 2.3), style: EditorStyle(color: EditorColor(red: 1, green: 0, blue: 0, alpha: 0.1)))]
        let image = try EditorRenderer.render(doc).image
        for y in 1...3 { for x in 1...4 { #expect(try EditorRenderer.sample(image, at: CGPoint(x: x, y: y)) == "#000000") } }
        #expect(try EditorRenderer.sample(image, at: CGPoint(x: 1, y: 9)) == "#FFB446")
        let pixel = try #require(image.cropping(to: CGRect(x: 2, y: 2, width: 1, height: 1)))
        let context = try EditorRenderer.context(width: 1, height: 1); context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(context.data!.assumingMemoryBound(to: UInt8.self)[3] == 255)
    }
    @Test("Solid redaction precedes every blur, pixelation and background pixel")
    func derivedPrivacy() throws {
        var first = try EditorDocument(source: Self.image(secret: 255))
        var second = try EditorDocument(source: Self.image(secret: 7))
        let annotations = [EditorAnnotation(kind: .redact, rect: CGRect(x: 0, y: 0, width: 8, height: 12)), EditorAnnotation(kind: .blur, rect: CGRect(x: 0, y: 0, width: 16, height: 12)), EditorAnnotation(kind: .pixelate, rect: CGRect(x: 0, y: 0, width: 16, height: 12))]
        first.edits.annotations = annotations; second.edits.annotations = annotations
        first.edits.background = EditorBackground(preset: .gradient, padding: 10, cornerRadius: 3, frameWidth: 2, shadow: true)
        second.edits.background = first.edits.background
        let firstPNG = try EditorRenderer.render(first).png, secondPNG = try EditorRenderer.render(second).png
        #expect(firstPNG == secondPNG)
        let exported = try #require(CGImageSourceCreateWithData(firstPNG as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(exported, 0, nil))
        let protectedHex = try EditorRenderer.sample(decoded, at: CGPoint(x: 16, y: 16))
        #expect((Int(protectedHex.dropFirst().prefix(2), radix: 16) ?? 255) <= 20)
    }
    @Test("Secrets outside crop cannot influence image, shadow or gradient")
    func outsideCropPrivacy() throws {
        var first = try EditorDocument(source: Self.image(secret: 255)), second = try EditorDocument(source: Self.image(secret: 7))
        first.edits.crop = CGRect(x: 8, y: 0, width: 8, height: 12); second.edits.crop = first.edits.crop
        first.edits.background = EditorBackground(preset: .gradient, padding: 8, cornerRadius: 2); second.edits.background = first.edits.background
        first.edits.annotations = [EditorAnnotation(kind: .blur, rect: first.bounds)]; second.edits.annotations = first.edits.annotations
        #expect(try EditorRenderer.render(first).png == EditorRenderer.render(second).png)
    }
    @Test("Flattened PNG contains new raster and DPI only, with no source metadata")
    func flattenedMetadata() throws {
        var doc = try EditorDocument(source: Self.image(), pointSize: CGSize(width: 8, height: 6))
        doc.edits.annotations = [EditorAnnotation(kind: .text, rect: CGRect(x: 0, y: 0, width: 16, height: 12), text: "test@private.example")]
        let data = try EditorRenderer.render(doc).png
        #expect(!String(decoding: data, as: UTF8.self).contains("test@private.example"))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyIPTCDictionary] == nil)
        // Inspect actual PNG chunks: ImageIO may synthesize dimensional property dictionaries.
        var chunkNames: [String] = [], offset = 8
        while offset + 12 <= data.count {
            let length = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= data.count - offset - 12 else { Issue.record("Malformed PNG chunk"); break }
            chunkNames.append(String(decoding: data[offset + 4..<offset + 8], as: UTF8.self))
            offset += length + 12
        }
        #expect(chunkNames.contains("pHYs"))
        #expect(!chunkNames.contains("eXIf")); #expect(!chunkNames.contains("tEXt")); #expect(!chunkNames.contains("iTXt")); #expect(!chunkNames.contains("zTXt"))
        #expect(abs((properties[kCGImagePropertyDPIWidth] as? Double ?? 0) - 144) < 0.1)
    }
    @Test("Fresh PNG decodes exact pixels and preserves 1x, Retina and fractional density",
          arguments: [CGSize(width: 16, height: 12), CGSize(width: 8, height: 6), CGSize(width: 9.25, height: 7.75)])
    func pngDensity(points: CGSize) throws {
        let image = try Self.image()
        let png = try EditorRendered(image: image, pointSize: points).png
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == image.width); #expect(decoded.height == image.height)
        #expect(try EditorRenderer.sample(decoded, at: .zero) == "#FF2846")
        #expect(try EditorRenderer.sample(decoded, at: CGPoint(x: 15, y: 11)) == "#14B446")
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let density = try #require(properties[kCGImagePropertyPNGDictionary] as? [CFString: Any])
        #expect(abs((density[kCGImagePropertyPNGXPixelsPerMeter] as? Double ?? 0) * 0.0254 - 72 * 16 / points.width) < 0.02)
        #expect(abs((density[kCGImagePropertyPNGYPixelsPerMeter] as? Double ?? 0) * 0.0254 - 72 * 12 / points.height) < 0.02)
        let root = EditorTemporaryExports().directory.deletingLastPathComponent().appendingPathComponent("editor-density-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.png"); try png.write(to: file)
        let reopened = try EditorRenderer.decode(file)
        #expect(abs(reopened.pointSize.width - points.width) < 0.004)
        #expect(abs(reopened.pointSize.height - points.height) < 0.004)
    }
    @Test("Fresh PNG retains indexed palette and transparent raster pixels")
    func paletteAndTransparency() throws {
        let table: [UInt8] = [255, 0, 0, 0, 255, 0]
        let indexed = try table.withUnsafeBufferPointer { table in
            let space = try #require(CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: 1, colorTable: table.baseAddress!))
            let provider = try #require(CGDataProvider(data: Data([0, 1]) as CFData))
            return try #require(CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 2, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        }
        #expect(indexed.colorSpace?.model == .indexed)
        let palettePNG = try EditorRendered(image: indexed, pointSize: CGSize(width: 2, height: 1)).png
        let paletteSource = try #require(CGImageSourceCreateWithData(palettePNG as CFData, nil))
        let palettePixels = try #require(CGImageSourceCreateImageAtIndex(paletteSource, 0, nil))
        #expect(try EditorRenderer.sample(palettePixels, at: .zero) == "#FF0000")
        #expect(try EditorRenderer.sample(palettePixels, at: CGPoint(x: 1, y: 0)) == "#00FF00")
        let provider = try #require(CGDataProvider(data: Data([255, 0, 0, 255, 0, 0, 0, 0]) as CFData))
        let transparent = try #require(CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let alphaPNG = try EditorRendered(image: transparent, pointSize: CGSize(width: 2, height: 1)).png
        let alphaSource = try #require(CGImageSourceCreateWithData(alphaPNG as CFData, nil))
        let alphaPixels = try #require(CGImageSourceCreateImageAtIndex(alphaSource, 0, nil))
        let bitmap = try EditorRenderer.context(width: 2, height: 1); bitmap.draw(alphaPixels, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        let bytes = try #require(bitmap.data?.assumingMemoryBound(to: UInt8.self))
        #expect(bytes[3] == 255); #expect(bytes[7] == 0)
    }
    @Test("All annotation tools produce a flattened visible edit")
    func actualAnnotations() throws {
        let source = try Self.image(width: 128, height: 128)
        let baseline = try EditorRenderer.render(EditorDocument(source: source)).png
        for tool in [EditorTool.arrow, .rectangle, .text, .highlight, .step, .blur, .pixelate, .redact] {
            var doc = try EditorDocument(source: source)
            doc.edits.annotations = [EditorAnnotation(kind: tool, rect: CGRect(x: 35, y: 35, width: 60, height: 60), text: "Hello", stepNumber: 3)]
            #expect(try EditorRenderer.render(doc).png != baseline, "Tool \(tool) must change real output pixels")
        }
    }
    @Test("Finite bounds, checked allocation budgets and reversed drags")
    func limits() throws {
        #expect(throws: EditorError.self) { try EditorGeometry.validateDimensions(width: 40_001, height: 1, pixels: 50_000_000) }
        #expect(throws: EditorError.self) { try EditorGeometry.validateDimensions(width: 10_000, height: 10_000, pixels: 50_000_000) }
        let bounds = CGRect(x: 0, y: 0, width: 16, height: 12)
        #expect(EditorGeometry.drag(from: CGPoint(x: 10, y: 8), to: CGPoint(x: 2, y: 1), bounds: bounds) == CGRect(x: 2, y: 1, width: 8, height: 7))
        #expect(EditorGeometry.sourcePoint(view: CGPoint(x: 110, y: 90), origin: CGPoint(x: 10, y: 10), zoom: 2) == CGPoint(x: 50, y: 40))
        #expect(EditorGeometry.sourcePoint(view: .zero, origin: .zero, zoom: .nan) == nil)
        #expect(throws: EditorError.self) { try EditorRendered(image: Self.image(), pointSize: CGSize(width: CGFloat.infinity, height: 1)).png }
        var doc = try EditorDocument(source: Self.image()); doc.edits.background.padding = .infinity
        #expect(throws: EditorError.self) { try EditorRenderer.render(doc) }
    }
    @Test("Vision geometry and sensitive text parser expose only kinds and boxes")
    func ocrParsing() {
        #expect(EditorSensitiveText.kinds(in: "Contact user@example.com and +39 123 456 7890") == [.email, .phone])
        #expect(EditorSensitiveText.kinds(in: "Build 1234") == [])
        #expect(EditorGeometry.visionRect(CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.3), width: 100, height: 200) == CGRect(x: 10, y: 100, width: 40, height: 60))
    }
    @Test("Native Vision finds synthetic email and phone boxes in source coordinates")
    func nativeVision() async throws {
        let context = try EditorRenderer.context(width: 1200, height: 260)
        context.setFillColor(EditorColor.paper.cgColor); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 260))
        var fixture = try EditorDocument(source: #require(context.makeImage()))
        let style = EditorStyle(color: .black, fontSize: 64)
        fixture.edits.annotations = [EditorAnnotation(kind: .text, rect: CGRect(x: 40, y: 40, width: 1100, height: 80), style: style, text: "user@example.com"), EditorAnnotation(kind: .text, rect: CGRect(x: 40, y: 150, width: 1100, height: 80), style: style, text: "+39 123 456 7890")]
        let document = try EditorDocument(source: EditorRenderer.render(fixture).image)
        let suggestions = try await EditorWorker().recognize(document)
        let email = try #require(suggestions.first { $0.kind == .email }), phone = try #require(suggestions.first { $0.kind == .phone })
        #expect(email.rect.midY < 130); #expect(phone.rect.midY > 130)
        #expect(document.bounds.contains(email.rect)); #expect(document.bounds.contains(phone.rect))
    }
    @Test("Pin budgets cap count and combined pixels") @MainActor
    func pinBudget() {
        #expect(PinnedScreenshotController.canPin(width: 5000, height: 5000, count: 2, pixelCount: 50_000_000))
        #expect(!PinnedScreenshotController.canPin(width: 5000, height: 5000, count: 5, pixelCount: 0))
        #expect(!PinnedScreenshotController.canPin(width: 5000, height: 5000, count: 1, pixelCount: 80_000_000))
        #expect(!PinnedScreenshotController.canPin(width: Int.max, height: Int.max, count: 0, pixelCount: 0))
    }
}

@Suite("Screenshot editor session") @MainActor
struct EditorSessionTests {
    private func capture() throws -> CapturedScreenshot {
        CapturedScreenshot(id: UUID(), image: try EditorRendererTests.image(), pointSize: CGSize(width: 8, height: 6), kind: .screenshot, saveToDiskRequested: false)
    }
    @Test("Vector changes retain the accepted raster until replacement is ready")
    func interactionBaseRetention() async throws {
        let session = EditorSession(); session.open(try capture()); await session.waitForRendering()
        let original = try #require(session.preview?.image)
        session.add(tool: .rectangle, from: CGPoint(x: 1, y: 1), to: CGPoint(x: 5, y: 5))
        #expect(session.preview?.image === original)
        session.stop()
    }

    @Test("Native scroll magnification keeps crop and background coordinates single-scaled and presentation clean")
    func nativeCanvasMagnification() async throws {
        let session = EditorSession()
        session.open(try capture())
        let cleanRevision = session.revision
        session.fitZoom = false; session.zoom = 2
        session.showsBackgroundInspector = true
        session.style.lineWidth = 8
        session.tool = .highlight
        #expect(session.style.color == EditorRenderer.markerColor)
        #expect(!session.hasUnsavedEdits)
        #expect(session.revision == cleanRevision)
        session.chooseColor(.ink)
        session.tool = .select; session.tool = .highlight
        session.add(tool: .highlight, from: .zero, to: CGPoint(x: 4, y: 4))
        #expect(session.document?.edits.annotations.last?.style.color == .ink)
        session.undo()
        #expect(!session.hasUnsavedEdits)
        #expect(session.revision > cleanRevision)
        session.edit { $0.crop = CGRect(x: 2, y: 3, width: 10, height: 7); $0.background.preset = .paper; $0.background.padding = 12; $0.background.frameWidth = 1 }
        await session.waitForRendering()
        let scroll = EditorScrollNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 240))
        scroll.allowsMagnification = true; scroll.minMagnification = 0.02; scroll.maxMagnification = 16
        let canvas = EditorCanvasNSView(); canvas.session = session; scroll.documentView = canvas
        scroll.synchronize(viewport: scroll.contentSize)
        #expect(scroll.magnification == 2)
        #expect(canvas.zoom == 1)
        let source = CGPoint(x: 6, y: 5)
        let mapped = canvas.viewRect(CGRect(origin: source, size: CGSize(width: 1, height: 1)))
        let clipPoint = scroll.contentView.convert(mapped.origin, from: canvas)
        let documentPoint = canvas.convert(clipPoint, from: scroll.contentView)
        let actual = try #require(canvas.sourcePoint(documentPoint))
        #expect(abs(actual.x - source.x) < 0.0001 && abs(actual.y - source.y) < 0.0001)
        #expect(abs(scroll.convert(mapped, from: canvas).width - 2) < 0.0001)
        session.fitZoom = true
        scroll.synchronize(viewport: scroll.contentSize)
        let imageRect = canvas.viewRect(session.document!.edits.crop)
        let fullImageWidth = canvas.imageSize.width * scroll.magnification
        let fullImageHeight = canvas.imageSize.height * scroll.magnification
        #expect(fullImageWidth <= scroll.contentSize.width - Theme.Editor.canvasMargin * 2 + 0.001)
        #expect(fullImageHeight <= scroll.contentSize.height - Theme.Editor.canvasMargin * 2 + 0.001)
        #expect(imageRect.width == 10)
        session.undo(); #expect(!session.hasUnsavedEdits)
        session.stop()
    }
    @Test("Canvas accessibility edit actions reject missing selection and unchanged boundary edits")
    func accessibilitySelectionActions() throws {
        let canvas = EditorCanvasNSView()
        let absent = try #require(canvas.accessibilityCustomActions())
        for action in absent { #expect(action.handler?() == false) }
        #expect(canvas.accessibilityPerformDelete() == false)
        let session = EditorSession(); canvas.session = session
        session.open(try capture())
        for action in try #require(canvas.accessibilityCustomActions()) { #expect(action.handler?() == false) }
        #expect(canvas.accessibilityPerformDelete() == false)
        session.add(tool: .rectangle, from: .zero, to: CGPoint(x: 4, y: 4))
        let selected = try #require(canvas.accessibilityCustomActions())
        #expect(selected[0].handler?() == false)
        #expect(selected[1].handler?() == true)
        #expect(canvas.accessibilityPerformDelete() == true)
        #expect(canvas.accessibilityPerformDelete() == false); session.stop()
    }
    @Test("Snapshot undo restores crop, annotations and background without copying source")
    func undoRedo() throws {
        let session = EditorSession(); session.open(try capture()); let source = session.document!.source
        session.add(tool: .rectangle, from: CGPoint(x: 1, y: 1), to: CGPoint(x: 7, y: 6))
        session.edit { $0.crop = CGRect(x: 2, y: 2, width: 10, height: 8); $0.background.preset = .paper }
        #expect(session.hasUnsavedEdits); #expect(session.document!.edits.annotations.count == 1)
        session.undo(); #expect(session.document!.edits.crop == session.document!.bounds); #expect(session.document!.edits.annotations.count == 1)
        session.undo(); #expect(session.document!.edits.annotations.isEmpty); #expect(!session.hasUnsavedEdits)
        session.redo(); #expect(session.document!.source === source); #expect(session.document!.edits.annotations.count == 1)
        let originalStyle = try #require(session.selectedAnnotation?.style)
        session.beginContinuousEdit()
        session.updateSelected { $0.style.lineWidth = 7 }; session.updateSelected { $0.style.lineWidth = 8 }
        session.editUndoManager.undo(); #expect(session.selectedAnnotation?.style == originalStyle)
        session.updateSelected { $0.style.lineWidth = 9 }; session.editUndoManager.undo()
        #expect(session.selectedAnnotation?.style == originalStyle); session.endContinuousEdit()
        session.stop()
    }
    @Test("Fresh capture cannot silently discard edits; explicit discard opens requested identity")
    func captureGuard() async throws {
        let session = EditorSession(), first = try capture(), second = try capture()
        session.open(first); session.add(tool: .redact, from: .zero, to: CGPoint(x: 6, y: 6)); session.open(second)
        #expect(session.document?.id == first.id); #expect(session.pendingCapture?.id == second.id)
        await session.discardAndOpenPending(); #expect(session.document?.id == second.id); #expect(!session.hasUnsavedEdits)
        session.stop()
    }
    @Test("Pending-open cancellation and failed approved load preserve edits and route only accepted documents")
    func pendingDecision() async throws {
        let worker = EditorWorker(decoder: { _ in throw EditorError.invalidImage })
        let session = EditorSession(worker: worker), first = try capture(), second = try capture()
        var accepted = 0; session.onDocumentAccepted = { accepted += 1 }
        session.open(first); session.add(tool: .rectangle, from: .zero, to: CGPoint(x: 6, y: 6)); session.open(second)
        #expect(accepted == 1); session.cancelPending(); #expect(session.pendingCapture == nil); #expect(session.hasUnsavedEdits)
        #expect(await session.open(url: URL(fileURLWithPath: "/damaged-fixture.png")) == false)
        await session.discardAndOpenPending(); #expect(session.document?.id == first.id); #expect(session.hasUnsavedEdits); #expect(accepted == 1)
        session.open(second); session.nudge(dx: 1, dy: 1); await session.discardAndOpenPending()
        #expect(session.document?.id == second.id); #expect(accepted == 2); session.stop()
    }
    @Test("Explicit OCR apply produces opaque redactions in one undo step without storing recognized text")
    func applyOCR() async throws {
        let worker = EditorWorker(recognizer: { _ in [EditorSensitiveSuggestion(kind: .email, rect: CGRect(x: 1, y: 1, width: 4, height: 4)), EditorSensitiveSuggestion(kind: .phone, rect: CGRect(x: 8, y: 1, width: 4, height: 4))] })
        let session = EditorSession(worker: worker); session.open(try capture()); session.findSensitiveText(); await session.waitForSensitiveText()
        #expect(session.document?.edits.annotations.isEmpty == true)
        session.applySuggestions(); #expect(session.document?.edits.annotations.count == 2); #expect(session.document?.edits.annotations.allSatisfy { $0.kind == .redact && $0.text.isEmpty } == true)
        let output = try await session.flattened(); #expect(try EditorRenderer.sample(output.image, at: CGPoint(x: 2, y: 2)) == "#000000")
        session.undo(); #expect(session.document?.edits.annotations.isEmpty == true); #expect(!session.canUndo); session.stop()
    }
    @Test("Step numbers increment; selection movement and text edits are undoable")
    func editing() throws {
        let session = EditorSession(); session.open(try capture())
        session.add(tool: .step, from: CGPoint(x: 1, y: 1), to: CGPoint(x: 5, y: 5))
        session.add(tool: .step, from: CGPoint(x: 7, y: 1), to: CGPoint(x: 11, y: 5))
        #expect(session.document?.edits.annotations.map(\.stepNumber) == [1, 2])
        session.nudge(dx: 1, dy: 1); #expect(session.selectedAnnotation?.rect.origin == CGPoint(x: 8, y: 2)); session.undo()
        session.stop()
    }
    @Test("Export and named clipboard use flattened edits and leave source file unchanged")
    func exportPreservesSource() async throws {
        let root = EditorTemporaryExports().directory.deletingLastPathComponent().appendingPathComponent("editor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("original.png"), output = root.appendingPathComponent("edited.png")
        let original = try EditorRenderer.render(EditorDocument(source: EditorRendererTests.image())).png
        try original.write(to: sourceURL)
        let session = EditorSession(temporaryExports: EditorTemporaryExports(root: root)); await session.open(url: sourceURL)
        session.add(tool: .redact, from: .zero, to: CGPoint(x: 6, y: 6)); try await session.export(to: output)
        #expect(try Data(contentsOf: sourceURL) == original)
        let image = try EditorRenderer.decode(output).source
        #expect(try EditorRenderer.sample(image, at: CGPoint(x: 2, y: 2)) == "#000000")
        let board = NSPasteboard(name: NSPasteboard.Name("editor-\(UUID().uuidString)"))
        #expect(await session.copy(to: board)); #expect(board.data(forType: .png) != nil)
        let temporary = try await session.temporaryExport(); #expect(temporary != sourceURL)
        #expect(try Data(contentsOf: temporary) == Data(contentsOf: output))
        session.stop(); session.temporaryExports.cleanup()
    }
    @Test("Annotation and background styles persist only in supplied isolated preferences")
    func rememberedStyles() throws {
        let name = "editor-style-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let session = EditorSession(defaults: defaults); session.open(try capture())
        session.style = EditorStyle(color: EditorColor(red: 0.1, green: 0.2, blue: 0.3), lineWidth: 8); session.rememberStyle()
        session.edit { $0.background.preset = .gradient; $0.background.padding = 28 }
        let second = EditorSession(defaults: defaults); second.open(try capture())
        #expect(second.style.lineWidth == 8); #expect(second.document?.edits.background.preset == .gradient); #expect(second.document?.edits.background.padding == 28)
        second.tool = .highlight
        #expect(second.style.color == session.style.color)
        second.tool = .arrow; #expect(second.style.lineWidth == 8)
        session.stop(); second.stop()
    }
    @Test("Old tool styles retain values and new text capsule survives editing, undo and flattened export")
    func compatibleTextBackground() async throws {
        let legacy = Data(#"{"color":{"red":0.92,"green":0.18,"blue":0.22,"alpha":1},"lineWidth":4,"fontSize":28,"effectSize":12}"#.utf8)
        let old = try JSONDecoder().decode(EditorStyle.self, from: legacy)
        #expect(old.lineWidth == 4 && old.fontSize == 28 && old.effectSize == 12 && !old.textBackground)
        let session = EditorSession(); session.open(try capture())
        session.tool = .arrow; #expect(session.style.lineWidth == 6)
        session.tool = .rectangle; #expect(session.style.lineWidth == 4)
        session.chooseLineWidth(10); session.tool = .arrow; #expect(session.style.lineWidth == 10)
        session.add(tool: .text, from: .zero, to: CGPoint(x: 10, y: 8))
        let baseline = try await session.flattened().png
        session.updateSelected { $0.style.textBackground = true }
        #expect(session.hasUnsavedEdits)
        let style = try #require(session.selectedAnnotation?.style)
        #expect(try JSONDecoder().decode(EditorStyle.self, from: JSONEncoder().encode(style)) == style)
        let changed = try await session.flattened().png
        #expect(changed != baseline)
        session.undo(); #expect(session.document?.edits.annotations.last?.style.textBackground == false)
        #expect(try await session.flattened().png == baseline)
        session.redo(); #expect(session.document?.edits.annotations.last?.style.textBackground == true)
        #expect(try await session.flattened().png == changed)
        session.stop()
    }
    @Test("Original-file aliases cannot be overwritten through export")
    func exportAliasGuard() async throws {
        let cache = EditorTemporaryExports(), root = cache.directory.deletingLastPathComponent().appendingPathComponent("editor-alias-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png"), alias = root.appendingPathComponent("alias.png")
        let data = try EditorRenderer.render(EditorDocument(source: EditorRendererTests.image())).png
        try data.write(to: source); try FileManager.default.linkItem(at: source, to: alias)
        let session = EditorSession(); await session.open(url: source)
        session.add(tool: .redact, from: .zero, to: CGPoint(x: 6, y: 6))
        await #expect(throws: EditorError.self) { try await session.export(to: alias) }
        #expect(try Data(contentsOf: source) == data); session.stop()
    }
    @Test("Pixel loupe samples crop-aware source coordinates and copies to a named pasteboard")
    func pixelLoupe() async throws {
        let session = EditorSession(); session.open(try capture())
        session.edit { $0.crop = CGRect(x: 8, y: 0, width: 8, height: 6); $0.background.preset = .paper; $0.background.padding = 4 }
        await session.waitForRendering(); session.inspectPixel(at: CGPoint(x: 12, y: 3))
        #expect(session.pixelHex == "#142846"); #expect(session.pixelLocation == CGPoint(x: 12, y: 3))
        let board = NSPasteboard(name: NSPasteboard.Name("editor-pixel-\(UUID().uuidString)"))
        session.copyHex(try #require(session.pixelHex), to: board); #expect(board.string(forType: .string) == "#142846")
        session.inspectPixel(at: nil); #expect(session.pixelHex == nil); session.stop()
    }
    @Test("Private cache rejects ancestor symlink and replacement-directory symlink")
    func temporaryAncestorAndReplacement() throws {
        let root = EditorTemporaryExports().directory.deletingLastPathComponent().appendingPathComponent("editor-link-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual"), child = actual.appendingPathComponent("child"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        #expect(throws: EditorError.self) { try EditorTemporaryExports(root: alias.appendingPathComponent("child")).write(Data([1])) }
        let cache = EditorTemporaryExports(root: root)
        let file = try cache.write(Data([2]))
        let displaced = root.appendingPathComponent("displaced")
        try FileManager.default.moveItem(at: cache.directory, to: displaced)
        try FileManager.default.createSymbolicLink(at: cache.directory, withDestinationURL: actual)
        let outside = actual.appendingPathComponent(file.lastPathComponent); try Data([7]).write(to: outside)
        cache.cleanup(); #expect(try Data(contentsOf: outside) == Data([7]))
        #expect(throws: EditorError.self) { try cache.write(Data([3])) }
    }
    @Test("Private cache count and byte caps evict only oldest owned files")
    func temporaryBudgets() throws {
        let cache = EditorTemporaryExports(maximumFiles: 2, maximumBytes: 10)
        defer { cache.cleanup() }
        let first = try cache.write(Data(repeating: 1, count: 6))
        let second = try cache.write(Data(repeating: 2, count: 6))
        #expect(!FileManager.default.fileExists(atPath: first.path)); #expect(FileManager.default.fileExists(atPath: second.path))
        let third = try cache.write(Data([3])), fourth = try cache.write(Data([4]))
        #expect(!FileManager.default.fileExists(atPath: second.path)); #expect(FileManager.default.fileExists(atPath: third.path)); #expect(FileManager.default.fileExists(atPath: fourth.path))
        #expect(throws: EditorError.self) { try cache.write(Data(repeating: 5, count: 11)) }
    }
    @Test("Private cache refuses symlink parent and preserves unknown files on cleanup")
    func temporarySafety() throws {
        let root = EditorTemporaryExports().directory.deletingLastPathComponent().appendingPathComponent("editor-cache-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let cache = EditorTemporaryExports(root: root)
        let output = try cache.write(Data([1, 2, 3])), unknown = cache.directory.appendingPathComponent("owner.txt")
        try Data([7]).write(to: unknown); cache.cleanup()
        #expect(!FileManager.default.fileExists(atPath: output.path)); #expect(try Data(contentsOf: unknown) == Data([7]))
        let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cache.directory)
        #expect(throws: EditorError.self) { try EditorTemporaryExports(root: link).write(Data([9])) }
    }
}

private actor EditorTestGate {
    private var didStart = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWork: CheckedContinuation<Void, Never>?
    func suspend() async {
        didStart = true
        for waiter in waiters { waiter.resume() }; waiters.removeAll()
        await withCheckedContinuation { resumeWork = $0 }
    }
    func waitForStart() async { if didStart { return }; await withCheckedContinuation { waiters.append($0) } }
    func resume() { resumeWork?.resume(); resumeWork = nil }
}

@Suite("Screenshot editor asynchronous identity guards") @MainActor
struct EditorIdentityTests {
    @Test("Default latest load leaves existing clean or dirty documents untouched and loses delayed decode races")
    func defaultEmptyOnly() async throws {
        let gate = EditorTestGate(), delayed = try EditorDocument(source: EditorRendererTests.image())
        let session = EditorSession(worker: EditorWorker(decoder: { _ in await gate.suspend(); return delayed }))
        let url = URL(fileURLWithPath: "/unused-latest.png")
        let loading = Task { await session.requestOpen(url: url, onlyIfEmpty: true) }
        await gate.waitForStart()
        let capture = CapturedScreenshot(id: UUID(), image: try EditorRendererTests.image(secret: 7), pointSize: CGSize(width: 8, height: 6), kind: .screenshot, saveToDiskRequested: false)
        session.open(capture)
        await gate.resume()
        #expect(await loading.value == .superseded)
        #expect(session.document?.id == capture.id)
        #expect(session.pendingURL == nil && session.error == nil && !session.hasUnsavedEdits)
        let revision = session.revision
        #expect(await session.requestOpen(url: url, onlyIfEmpty: true) == .superseded)
        #expect(session.revision == revision)
        session.add(tool: .rectangle, from: .zero, to: CGPoint(x: 4, y: 4))
        #expect(await session.requestOpen(url: url, onlyIfEmpty: true) == .superseded)
        #expect(session.hasUnsavedEdits && session.pendingURL == nil && session.error == nil)
        session.stop()
    }
    @Test("Library validation order across open and drop rejects stale callbacks and stale errors", arguments: [true, false])
    func libraryOpenOrder(olderValid: Bool) async throws {
        let suite = "editor-library-open-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = EditorTemporaryExports().directory.deletingLastPathComponent().appendingPathComponent("editor-library-" + UUID().uuidString)
        let older = root.appendingPathComponent("older.png"), newer = root.appendingPathComponent("newer.png"), gate = EditorTestGate()
        let store = LibraryStore(defaults: defaults, roots: [], cacheDirectory: root,
            validateOpen: { url, _ in if url == older { await gate.suspend(); return olderValid }; return true })
        var opened: [URL] = []
        store.onOpenScreenshot = { opened.append($0) }; store.issue = "existing fixture issue"
        let item = CaptureItem(id: "older", url: older, kind: .screenshot, origin: .savedFile, createdAt: Date(), byteSize: 1, pixelSize: nil, duration: nil)
        let oldRequest = Task { await store.open(item) }; await gate.waitForStart()
        await store.openDroppedImage(newer); await gate.resume(); await oldRequest.value
        #expect(opened == [newer]); #expect(store.issue == "existing fixture issue")
    }
    @Test("Late file decode cannot replace a newer capture")
    func lateDecode() async throws {
        let gate = EditorTestGate(), delayed = try EditorDocument(source: EditorRendererTests.image())
        let worker = EditorWorker(decoder: { _ in await gate.suspend(); return delayed })
        let session = EditorSession(worker: worker)
        let loading = Task { await session.open(url: URL(fileURLWithPath: "/unused-fixture.png")) }
        await gate.waitForStart()
        let capture = CapturedScreenshot(id: UUID(), image: try EditorRendererTests.image(secret: 7), pointSize: CGSize(width: 8, height: 6), kind: .screenshot, saveToDiskRequested: false)
        session.open(capture); await gate.resume(); _ = await loading.value
        #expect(session.document?.id == capture.id); session.stop()
    }
    @Test("Edits made during a decode require explicit discard before replacement")
    func editingDuringDecode() async throws {
        let gate = EditorTestGate(), delayed = try EditorDocument(source: EditorRendererTests.image())
        let worker = EditorWorker(decoder: { _ in await gate.suspend(); return delayed })
        let session = EditorSession(worker: worker)
        let capture = CapturedScreenshot(id: UUID(), image: try EditorRendererTests.image(), pointSize: CGSize(width: 8, height: 6), kind: .screenshot, saveToDiskRequested: false)
        session.open(capture)
        let url = URL(fileURLWithPath: "/unused-fixture.png")
        let loading = Task { await session.open(url: url) }; await gate.waitForStart()
        session.add(tool: .redact, from: .zero, to: CGPoint(x: 4, y: 4)); await gate.resume(); _ = await loading.value
        #expect(session.document?.id == capture.id); #expect(session.pendingURL == url); session.stop()
    }
    @Test("Late OCR suggestions are rejected after a document revision change")
    func lateOCR() async throws {
        let gate = EditorTestGate()
        let worker = EditorWorker(recognizer: { _ in await gate.suspend(); return [EditorSensitiveSuggestion(kind: .email, rect: CGRect(x: 1, y: 1, width: 4, height: 4))] })
        let session = EditorSession(worker: worker)
        session.open(CapturedScreenshot(id: UUID(), image: try EditorRendererTests.image(), pointSize: CGSize(width: 8, height: 6), kind: .screenshot, saveToDiskRequested: false))
        session.findSensitiveText(); await gate.waitForStart()
        session.add(tool: .rectangle, from: .zero, to: CGPoint(x: 4, y: 4)); await gate.resume()
        await session.waitForSensitiveText()
        #expect(session.suggestions.isEmpty); #expect(!session.isFindingText); session.stop()
    }
}

@Suite("Editor native interaction", .serialized) @MainActor
struct EditorNativeInteractionTests {
    @Test("Background radius rounds the padded card while original source alpha reveals its background")
    func backgroundCardRadius() throws {
        var doc = try source(alpha: 0.4)
        doc.edits.background = EditorBackground(preset: .paper, padding: 30, cornerRadius: 24, shadow: false, color: .paper)
        let output = try EditorRenderer.render(doc).image
        let bytes = try rgba(output)
        #expect(bytes[3] == 0)
        let sourceCorner = try #require(output.cropping(to: CGRect(x:30,y:30,width:1,height:1)))
        let reference = try EditorRenderer.context(width:1,height:1)
        reference.setFillColor(EditorColor.paper.cgColor); reference.fill(CGRect(x:0,y:0,width:1,height:1))
        reference.draw(try #require(doc.source.cropping(to:CGRect(x:0,y:0,width:1,height:1))), in:CGRect(x:0,y:0,width:1,height:1))
        #expect(try rgba(sourceCorner) == rgba(#require(reference.makeImage())))
    }
    @Test("Auto and Square preserve original alpha, Rounded uses twelve source points, and old background records default to Auto", arguments:[1,2])
    func sourceCornerPolicies(scale:Int) throws {
        var doc = try source(scale:scale,alpha:0.4)
        let original = try rgba(doc.source)
        #expect(try rgba(EditorRenderer.render(doc).image) == original)
        doc.edits.background.imageCorners = .square
        #expect(try rgba(EditorRenderer.render(doc).image) == original)
        doc.edits.background.imageCorners = .rounded
        let rounded = try EditorRenderer.render(doc).image
        #expect(try rgba(#require(rounded.cropping(to:CGRect(x:scale,y:scale,width:1,height:1))))[3] == 0)
        #expect(try rgba(#require(rounded.cropping(to:CGRect(x:12*scale,y:scale,width:1,height:1))))[3] == original[3])
        let renderer = EditorLiveRenderer(), base = try EditorRenderer.displayBase(doc)
        renderer.invalidate(baseGeneration:1,annotations:[])
        #expect(try rgba(renderer.compose(rect:doc.bounds,scale:1,base:base,document:doc,annotations:[])) == rgba(rounded))
        var object = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(doc.edits.background)) as? [String:Any])
        object.removeValue(forKey:"imageCorners")
        let legacy = try JSONDecoder().decode(EditorBackground.self,from:JSONSerialization.data(withJSONObject:object))
        #expect(legacy.imageCorners == .auto && legacy.padding == doc.edits.background.padding)
    }
    @Test("A source alpha shadow stays meaningful without a frame and agrees with bounded live patches", arguments:EditorBackground.ImageCorners.allCases)
    func sourceAlphaShadow(corners:EditorBackground.ImageCorners) throws {
        let context = try EditorRenderer.context(width:100,height:100)
        context.setFillColor(CGColor(gray:0.8,alpha:1)); context.fill(CGRect(x:15,y:15,width:70,height:70))
        var doc = try EditorDocument(source:#require(context.makeImage()))
        doc.edits.background = EditorBackground(preset:.paper,padding:40,cornerRadius:20,shadow:false,imageCorners:corners)
        let unshadowed = try EditorRenderer.render(doc).image
        doc.edits.background.shadow = true
        let shadowed = try EditorRenderer.render(doc).image
        #expect(try rgba(shadowed) != rgba(unshadowed))
        #expect(try EditorRenderer.sample(shadowed,at:CGPoint(x:90,y:149)) != EditorRenderer.sample(unshadowed,at:CGPoint(x:90,y:149)))
        doc.edits.annotations = [EditorAnnotation(kind:.highlight,rect:CGRect(x:0,y:0,width:80,height:50),style:EditorStyle(color:EditorRenderer.markerColor))]
        let full = try EditorRenderer.render(doc), base = try EditorRenderer.displayBase(doc)
        let renderer = EditorLiveRenderer(); renderer.invalidate(baseGeneration:1,annotations:doc.edits.annotations)
        let live = try renderer.compose(rect:doc.bounds,scale:1,base:base,document:doc,annotations:doc.edits.annotations)
        #expect(try rgba(live) == rgba(#require(full.image.cropping(to:CGRect(x:40,y:40,width:100,height:100)))))
    }
    private func source(scale: Int = 1, alpha: CGFloat = 1) throws -> EditorDocument {
        let context = try EditorRenderer.context(width: 320 * scale, height: 240 * scale)
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.85, blue: 0.9, alpha: alpha)); context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.setFillColor(CGColor(gray: 0.08, alpha: alpha))
        for x in stride(from: 40, to: 200, by: 20) { context.fill(CGRect(x: x * scale, y: 80 * scale, width: 8 * scale, height: 12 * scale)) }
        return try EditorDocument(source: #require(context.makeImage()), pointSize: CGSize(width: 320, height: 240))
    }
    @Test("Privacy jobs retain accepted base, ignore vector-only changes and refresh after stop without stale publication")
    func displayPrivacyLifecycle() async throws {
        let gate = EditorDisplayRenderGate()
        let session = EditorSession(worker: EditorWorker(displayRenderer: { try await gate.render($0) }))
        let first = try source()
        session.open(CapturedScreenshot(id:UUID(),image:first.source,pointSize:first.pointSize,kind:.screenshot,saveToDiskRequested:false)); await session.waitForRendering()
        let accepted = try #require(session.displayBase?.image)
        session.add(tool:.rectangle,from:.init(x:10,y:10),to:.init(x:80,y:80))
        #expect(session.displayRasterRequests == 1 && session.displayBase?.image === accepted)
        session.add(tool:.redact,from:.init(x:40,y:60),to:.init(x:90,y:90))
        #expect(session.displayBase?.image === accepted && session.isRendering)
        await gate.waitForStart()
        session.stop(); #expect(session.displayBase?.image === accepted)
        session.resume(); await session.waitForRendering()
        #expect(session.displayRasterRequests == 3 && !session.isRendering)
        #expect(try EditorRenderer.sample(#require(session.displayBase?.image), at:CGPoint(x:50,y:70)) == "#000000")
        let generation = session.displayBaseGeneration
        await gate.resume(); await Task.yield()
        #expect(session.displayBaseGeneration == generation)
        session.stop()
    }
    @Test("A moved blur or pixelate restores its old area and its live GPU patch matches full export", arguments:[EditorTool.blur,.pixelate])
    func livePrivacyMove(tool:EditorTool) throws {
        var original = try source()
        original.edits.annotations = [EditorAnnotation(kind:tool,rect:CGRect(x:30,y:135,width:120,height:50))]
        let base = try EditorRenderer.displayBase(original)
        #expect(base.privacySource != nil)
        let former = original.edits.annotations[0].rect
        #expect(try rgba(#require(base.image.cropping(to:former))) != rgba(#require(original.source.cropping(to:former))))
        var moved = original; moved.edits.annotations[0].rect = CGRect(x:175,y:135,width:120,height:50)
        let renderer = EditorLiveRenderer(); renderer.invalidate(baseGeneration:1,annotations:moved.edits.annotations,baseEdits:original.edits)
        let live = try renderer.compose(rect:moved.bounds,scale:1,base:base,document:moved,annotations:moved.edits.annotations)
        let expected = try EditorRenderer.render(moved)
        let actual = try rgba(live), full = try rgba(expected.image)
        #expect(zip(actual,full).map { abs(Int($0)-Int($1)) }.max() ?? 0 <= 1)
        #expect(try rgba(#require(live.cropping(to:former))) == rgba(#require(moved.source.cropping(to:former))))
        #expect(renderer.privacyPatchComputations == 1)
        _ = try renderer.compose(rect:former,scale:1,base:base,document:moved,annotations:moved.edits.annotations)
        #expect(renderer.privacyPatchComputations == 1)
    }
    @Test("Unfiltered display privacySource can never become flattened or copied pixels and is released on stop")
    func privateSourcePublication() async throws {
        let poisonContext = try EditorRenderer.context(width:320,height:240)
        poisonContext.setFillColor(CGColor(srgbRed:1,green:0,blue:1,alpha:1)); poisonContext.fill(CGRect(x:0,y:0,width:320,height:240))
        let poison = try #require(poisonContext.makeImage())
        var copied:Data?
        var clipboard = EditorSession.ClipboardOperations()
        clipboard.copyPNG = { image,size,_,allowed in
            guard allowed() else { return false }
            copied = try? EditorRendered(image:image,pointSize:size).png; return copied != nil
        }
        let session = EditorSession(worker:EditorWorker(displayRenderer:{ document in
            var base = try EditorRenderer.displayBase(document); base.privacySource = poison; return base
        }),clipboard:clipboard)
        let document = try source()
        session.open(CapturedScreenshot(id:UUID(),image:document.source,pointSize:document.pointSize,kind:.screenshot,saveToDiskRequested:false)); await session.waitForRendering()
        session.add(tool:.redact,from:CGPoint(x:30,y:70),to:CGPoint(x:150,y:110)); await session.waitForRendering()
        let expected = try EditorRenderer.render(#require(session.document))
        #expect(try rgba(await session.flattened().image) == rgba(expected.image))
        #expect(await session.copy())
        #expect(copied == (try expected.png))
        #expect(session.displayBase?.privacySource === poison)
        session.stop(); #expect(session.displayBase?.privacySource == nil)
        session.resume(); await session.waitForRendering(); #expect(session.displayBase?.privacySource === poison)
        session.stop()
    }
    @Test("Pending redact sanitizes live GPU effect input before any neighboring pixels can be derived")
    func pendingLiveDerivedPrivacy() throws {
        func patch(secret:CGFloat) throws -> CGImage {
            let c = try EditorRenderer.context(width:100,height:80)
            c.setFillColor(CGColor(gray:0.8,alpha:1)); c.fill(CGRect(x:0,y:0,width:100,height:80))
            c.setFillColor(CGColor(gray:secret,alpha:1)); c.fill(CGRect(x:35,y:30,width:20,height:20))
            var doc = try EditorDocument(source:#require(c.makeImage()))
            let clean = doc.edits, base = try EditorRenderer.displayBase(doc)
            doc.edits.annotations = [EditorAnnotation(kind:.redact,rect:CGRect(x:35,y:30,width:20,height:20)),EditorAnnotation(kind:.blur,rect:CGRect(x:15,y:15,width:70,height:50))]
            let renderer = EditorLiveRenderer(); renderer.invalidate(baseGeneration:1,annotations:doc.edits.annotations,baseEdits:clean)
            return try renderer.compose(rect:doc.bounds,scale:1,base:base,document:doc,annotations:doc.edits.annotations)
        }
        #expect(try rgba(patch(secret:0)) == rgba(patch(secret:1)))
    }
    @Test("Actual native drawing shows every tool before commit; privacy events coalesce to one display-frame GPU patch", arguments:[EditorTool.arrow,.rectangle,.text,.step,.highlight,.blur,.pixelate,.redact])
    func nativeLiveTools(tool:EditorTool) async throws {
        let doc = try source()
        let session = EditorSession(); session.open(CapturedScreenshot(id:UUID(),image:doc.source,pointSize:doc.pointSize,kind:.screenshot,saveToDiskRequested:false)); await session.waitForRendering()
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:600,height:480),styleMask:[.titled],backing:.buffered,defer:false); window.isReleasedWhenClosed = false
        let scroll = EditorScrollNSView(frame:CGRect(x:0,y:0,width:600,height:480)); scroll.allowsMagnification = true; scroll.minMagnification = 0.02; scroll.maxMagnification = 16
        let canvas = EditorCanvasNSView(); canvas.session = session; scroll.documentView = canvas; window.contentView = scroll
        session.fitZoom = false; session.zoom = session.actualPixelZoom; scroll.synchronize(viewport:scroll.contentSize)
        defer { session.stop(); window.close() }
        func mouse(_ type:NSEvent.EventType,_ p:CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with:type,location:canvas.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
        }
        let from = canvas.viewRect(CGRect(x:30,y:140,width:0,height:0)).origin
        let to = canvas.viewRect(CGRect(x:170,y:210,width:0,height:0)).origin
        session.tool = tool; canvas.mouseDown(with:try mouse(.leftMouseDown,from))
        for step in 1...20 {
            let t = CGFloat(step)/20
            canvas.mouseDragged(with:try mouse(.leftMouseDragged,CGPoint(x:from.x+(to.x-from.x)*t,y:from.y+(to.y-from.y)*t)))
        }
        #expect(session.document?.edits.annotations.isEmpty == true && session.displayRasterRequests == 1)
        let candidate = try #require(canvas.candidateAnnotation)
        if tool == .blur || tool == .pixelate {
            #expect(canvas.privacyPatchComputations == 0)
            canvas.renderPrivacyDisplayFrame(); #expect(canvas.privacyPatchComputations == 1)
            canvas.renderPrivacyDisplayFrame(); #expect(canvas.privacyPatchComputations == 1)
        }
        let layer = try #require(canvas.layer), delegate = layer.delegate; layer.delegate = nil
        defer { layer.delegate = delegate }
        let context = try EditorRenderer.context(width:Int(canvas.bounds.width),height:Int(canvas.bounds.height))
        context.translateBy(x:0,y:canvas.bounds.height); context.scaleBy(x:1,y:-1); layer.render(in:context)
        let region = candidate.rect
        let actual = try #require(context.makeImage()?.cropping(to:canvas.viewRect(region)))
        var expected = doc; expected.edits.annotations = [candidate]
        let full = try #require(EditorRenderer.render(expected).image.cropping(to:region))
        #expect(zip(try rgba(actual),try rgba(full)).map { abs(Int($0)-Int($1)) }.max() ?? 0 <= 1)
        #expect(try rgba(actual) != rgba(#require(doc.source.cropping(to:region))))
        canvas.mouseUp(with:try mouse(.leftMouseUp,to)); #expect(session.document?.edits.annotations.count == 1)
        if tool == .blur {
            session.tool = .redact
            let from = canvas.viewRect(CGRect(x:205,y:150,width:0,height:0)).origin
            let to = canvas.viewRect(CGRect(x:240,y:190,width:0,height:0)).origin
            canvas.mouseDown(with:try mouse(.leftMouseDown,from)); canvas.mouseDragged(with:try mouse(.leftMouseDragged,to))
            // A retained destination-bearing blur tile must never occlude new
            // opaque coverage while the next GPU patch is still queued.
            let protected = try EditorRenderer.context(width:Int(canvas.bounds.width),height:Int(canvas.bounds.height))
            protected.translateBy(x:0,y:canvas.bounds.height); protected.scaleBy(x:1,y:-1); layer.render(in:protected)
            let black = try #require(protected.makeImage()?.cropping(to:canvas.viewRect(CGRect(x:215,y:160,width:10,height:10))))
            let values = try rgba(black)
            for pixel in stride(from:0,to:400,by:4) {
                #expect(values[pixel] == 0 && values[pixel+1] == 0 && values[pixel+2] == 0 && values[pixel+3] == 255)
            }
            canvas.cancelGesture()
        }
        session.undo(); #expect(session.document?.edits.annotations.isEmpty == true && !session.canUndo)
    }
    @Test("Short text and capsule glyphs remain visible with shared live/export bounds at 1x and 2x", arguments:[1,2],[false,true])
    func shortTextGlyphs(density:Int,capsule:Bool) throws {
        let context = try EditorRenderer.context(width:960,height:600)
        context.setFillColor(CGColor(gray:0.15,alpha:1)); context.fill(CGRect(x:0,y:0,width:960,height:600))
        var document = try EditorDocument(source:#require(context.makeImage()),pointSize:CGSize(width:960/density,height:600/density))
        let base = try EditorRenderer.displayBase(document)
        var annotation = EditorAnnotation(kind:.text,rect:CGRect(x:80,y:350,width:190,height:50),text:"Review")
        annotation.style.textBackground = capsule
        document.edits.annotations = [annotation]
        let full = try EditorRenderer.render(document).image
        let live = EditorLiveRenderer(); live.invalidate(baseGeneration:1,annotations:document.edits.annotations,baseEdits:EditorEdits(crop:document.edits.crop))
        let patch = try live.compose(rect:EditorLiveRenderer.drawingBounds(annotation,document:document),scale:1,base:base,document:document,annotations:document.edits.annotations)
        func inkPixels(_ image:CGImage) throws -> Int {
            let bytes = try rgba(image)
            var count = 0
            for index in stride(from:0,to:bytes.count,by:4) {
                let r = bytes[index], g = bytes[index+1], b = bytes[index+2]
                if capsule ? (r > 220 && g > 220 && b > 220) : (r > 160 && g < 100 && b < 110) { count += 1 }
            }
            return count
        }
        #expect(try inkPixels(full) > 80)
        #expect(try inkPixels(patch) > 80)
        let paint = EditorLiveRenderer.drawingBounds(annotation,document:document).integral
        #expect(try rgba(patch) == rgba(#require(full.cropping(to:paint))))
        #expect(document.edits.annotations[0].rect == annotation.rect && annotation.rect.height == 50)
    }
    @Test("Native hover and drag route tool, hand and resize cursors without automatic pixel inspection")
    func nativeCursorRouting() async throws {
        let session = EditorSession(); let doc = try source()
        session.open(CapturedScreenshot(id:UUID(),image:doc.source,pointSize:doc.pointSize,kind:.screenshot,saveToDiskRequested:false)); await session.waitForRendering()
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:600,height:480),styleMask:[.titled],backing:.buffered,defer:false); window.isReleasedWhenClosed = false
        let canvas = EditorCanvasNSView(frame:CGRect(x:0,y:0,width:600,height:480)); canvas.session = session
        var published:[NSCursor] = []; canvas.cursorPublisher = { published.append($0) }
        window.contentView = canvas; canvas.refreshLayers()
        defer { session.stop(); window.close() }
        func event(_ type:NSEvent.EventType,_ point:CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
        }
        let empty = canvas.viewRect(CGRect(x:250,y:210,width:0,height:0)).origin
        for tool in [EditorTool.arrow,.rectangle,.highlight,.blur,.pixelate,.redact,.step,.crop] {
            session.tool = tool; canvas.mouseMoved(with:try event(.mouseMoved,empty))
            #expect(canvas.cursorKind == .crosshair)
        }
        session.tool = .text; canvas.mouseMoved(with:try event(.mouseMoved,empty))
        #expect(canvas.cursorKind == .iBeam && published.last === NSCursor.iBeam)
        #expect(session.pixelHex == nil)
        session.tool = .select; canvas.refreshLayers(); #expect(canvas.cursorKind == .arrow)
        session.tool = .text; canvas.refreshLayers(); #expect(canvas.cursorKind == .iBeam)
        canvas.isPixelInspectionEnabled = true; canvas.mouseMoved(with:try event(.mouseMoved,empty)); #expect(session.pixelHex != nil)
        canvas.isPixelInspectionEnabled = false; #expect(session.pixelHex == nil)
        session.tool = .rectangle
        canvas.mouseDown(with:try event(.leftMouseDown,empty)); #expect(canvas.cursorKind == .crosshair)
        canvas.mouseDragged(with:try event(.leftMouseDragged,CGPoint(x:empty.x+20,y:empty.y+10))); #expect(canvas.cursorKind == .crosshair)
        canvas.cancelGesture()
        session.add(tool:.rectangle,from:CGPoint(x:40,y:40),to:CGPoint(x:140,y:100)); canvas.refreshLayers()
        let middle = canvas.viewRect(CGRect(x:90,y:70,width:0,height:0)).origin
        canvas.mouseMoved(with:try event(.mouseMoved,middle)); #expect(canvas.cursorKind == .openHand)
        canvas.mouseDown(with:try event(.leftMouseDown,middle)); #expect(canvas.cursorKind == .closedHand)
        canvas.mouseDragged(with:try event(.leftMouseDragged,CGPoint(x:middle.x+10,y:middle.y+5))); #expect(canvas.cursorKind == .closedHand)
        canvas.mouseUp(with:try event(.leftMouseUp,CGPoint(x:middle.x+10,y:middle.y+5))); #expect(canvas.cursorKind == .openHand)
        let rect = try #require(session.selectedAnnotation)
        let positions:[NSCursor.FrameResizePosition] = [.topLeft,.top,.topRight,.right,.bottomRight,.bottom,.bottomLeft,.left]
        for (index,point) in canvas.handlePoints(for:rect).enumerated() {
            canvas.mouseMoved(with:try event(.mouseMoved,point)); #expect(canvas.cursorKind == .resize(positions[index]))
        }
        session.add(tool:.arrow,from:CGPoint(x:40,y:160),to:CGPoint(x:170,y:160)); canvas.refreshLayers()
        let arrow = try #require(session.selectedAnnotation), endpoints = canvas.handlePoints(for:arrow)
        canvas.mouseMoved(with:try event(.mouseMoved,endpoints[0])); #expect(canvas.cursorKind == .resize(.left))
        canvas.mouseDown(with:try event(.leftMouseDown,endpoints[1])); #expect(canvas.cursorKind == .resize(.right))
        canvas.mouseDragged(with:try event(.leftMouseDragged,CGPoint(x:endpoints[1].x,y:endpoints[1].y+70))); #expect(canvas.cursorKind == .resize(.bottomRight))
        canvas.cancelGesture()
        #expect(!window.isVisible)
    }
    @Test("Native short text hit area, handles and resize include its first line without migrating stored boxes")
    func nativeShortTextGeometry() async throws {
        let doc = try source(scale:2), session = EditorSession()
        session.open(CapturedScreenshot(id:UUID(),image:doc.source,pointSize:doc.pointSize,kind:.screenshot,saveToDiskRequested:false)); await session.waitForRendering()
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:800,height:640),styleMask:[.titled],backing:.buffered,defer:false); window.isReleasedWhenClosed = false
        let canvas = EditorCanvasNSView(frame:CGRect(x:0,y:0,width:800,height:640)); canvas.session = session; canvas.cursorPublisher = { _ in }
        window.contentView = canvas
        defer { session.stop(); window.close() }
        let stored = EditorAnnotation(kind:.text,rect:CGRect(x:100,y:120,width:190,height:50),text:"Review")
        session.edit { $0.annotations.append(stored) }; session.selectedID = stored.id; canvas.refreshLayers()
        let paint = EditorRenderer.textLayoutRect(stored,document:try #require(session.document))
        #expect(paint.minY == stored.rect.minY && paint.height > stored.rect.height)
        #expect(session.selectedAnnotation?.rect == stored.rect)
        #expect(canvas.handlePoints(for:stored)[5].y > canvas.viewRect(stored.rect).maxY)
        func event(_ type:NSEvent.EventType,_ location:CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with:type,location:canvas.convert(location,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
        }
        let lowerLine = canvas.viewRect(CGRect(x:paint.minX+25,y:paint.maxY-2,width:0,height:0)).origin
        canvas.mouseMoved(with:try event(.mouseMoved,lowerLine)); #expect(canvas.cursorKind == .openHand)
        canvas.mouseDown(with:try event(.leftMouseDown,lowerLine)); #expect(canvas.cursorKind == .closedHand)
        canvas.mouseUp(with:try event(.leftMouseUp,CGPoint(x:lowerLine.x+10,y:lowerLine.y+5)))
        #expect(session.selectedAnnotation?.rect == stored.rect.offsetBy(dx:10,dy:5))
        session.undo(); canvas.refreshLayers(); #expect(session.selectedAnnotation?.rect == stored.rect)
        let bottom = canvas.handlePoints(for:stored)[5]
        canvas.mouseDown(with:try event(.leftMouseDown,bottom))
        canvas.mouseUp(with:try event(.leftMouseUp,CGPoint(x:bottom.x,y:bottom.y-paint.height+1)))
        #expect(session.selectedAnnotation?.rect.height == paint.height)
        #expect(session.selectedAnnotation?.rect.minY == stored.rect.minY)
        session.undo(); #expect(session.selectedAnnotation?.rect == stored.rect)
        session.tool = .text; session.selectedID = nil; canvas.refreshLayers()
        let click = canvas.viewRect(CGRect(x:400,y:350,width:0,height:0)).origin
        canvas.mouseDown(with:try event(.leftMouseDown,click)); canvas.mouseUp(with:try event(.leftMouseUp,click))
        #expect(session.selectedAnnotation?.kind == .text && session.selectedAnnotation?.rect.height == paint.height)
        session.undo(); session.style.fontSize = 93; session.selectedID = nil; canvas.refreshLayers()
        let largeClick = canvas.viewRect(CGRect(x:30,y:20,width:0,height:0)).origin
        canvas.mouseDown(with:try event(.leftMouseDown,largeClick)); canvas.mouseUp(with:try event(.leftMouseUp,largeClick))
        let initial = try #require(session.selectedAnnotation)
        session.updateSelectedText("Review")
        let fitted = try #require(session.selectedAnnotation)
        #expect(fitted.style.fontSize == 93 && session.style.fontSize == 93)
        #expect(fitted.rect.width > initial.rect.width || fitted.rect.height > initial.rect.height)
        #expect(doc.bounds.contains(fitted.rect))
        session.undo(); #expect(session.selectedAnnotation?.text == initial.text && session.selectedAnnotation?.rect == initial.rect)
        #expect(!window.isVisible)
    }
    @Test("Fit stays fixed through native legacy gutter changes, annotation gestures and UndoRedo")
    func nativeFitScrollerStability() async throws {
        let c = try EditorRenderer.context(width:960,height:600)
        c.setFillColor(CGColor(gray:1,alpha:1)); c.fill(CGRect(x:0,y:0,width:960,height:600))
        let session = EditorSession(); session.open(CapturedScreenshot(id:UUID(),image:try #require(c.makeImage()),pointSize:CGSize(width:480,height:300),kind:.screenshot,saveToDiskRequested:false)); await session.waitForRendering()
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:1180,height:760),styleMask:[.titled],backing:.buffered,defer:false); window.isReleasedWhenClosed = false
        let scroll = EditorScrollNSView(frame:CGRect(x:0,y:0,width:1180,height:760)); scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .legacy; scroll.allowsMagnification = true; scroll.minMagnification = 0.02; scroll.maxMagnification = 16; scroll.fitTopClearance = 60
        let canvas = EditorCanvasNSView(); canvas.session = session; scroll.documentView = canvas; window.contentView = scroll
        defer { session.stop(); window.close() }
        func settle() async {
            for _ in 0..<5 { scroll.tile(); scroll.layoutSubtreeIfNeeded(); scroll.synchronize(viewport:scroll.contentSize); await Task.yield() }
        }
        await settle(); let fit = scroll.magnification
        for style in [NSScroller.Style.legacy,.overlay,.legacy] {
            for autohide in [false,true] {
                scroll.scrollerStyle = style; scroll.autohidesScrollers = autohide; await settle()
                #expect(abs(scroll.magnification-fit) < 0.0001)
                session.add(tool:.arrow,from:CGPoint(x:100,y:100),to:CGPoint(x:300,y:200)); canvas.refreshLayers(); await settle()
                #expect(abs(scroll.magnification-fit) < 0.0001)
                session.undo(); canvas.refreshLayers(); await settle(); #expect(abs(scroll.magnification-fit) < 0.0001)
                session.redo(); canvas.refreshLayers(); await settle(); #expect(abs(scroll.magnification-fit) < 0.0001)
                session.undo()
            }
        }
        session.fitZoom = false; session.zoom = 1.5; scroll.synchronize(viewport:scroll.contentSize)
        #expect(scroll.hasHorizontalScroller && scroll.hasVerticalScroller && scroll.magnification == 1.5)
        #expect(!window.isVisible)
    }
    @Test("Fractional physical zoom preserves source alpha and color across destination tile boundaries", arguments:[CGFloat(1.04),CGFloat(1.055),CGFloat(2.055)],[CGFloat(1),CGFloat(0.5)])
    func fractionalTileEdges(zoom:CGFloat,alpha:CGFloat) async throws {
        let doc = try source(alpha:alpha)
        let session = EditorSession(); session.open(CapturedScreenshot(id:UUID(),image:doc.source,pointSize:doc.pointSize,kind:.screenshot,saveToDiskRequested:false)); await session.waitForRendering()
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:600,height:480),styleMask:[.titled],backing:.buffered,defer:false); window.isReleasedWhenClosed = false
        let scroll = EditorScrollNSView(frame:CGRect(x:0,y:0,width:600,height:480)); scroll.allowsMagnification = true; scroll.minMagnification = 0.02; scroll.maxMagnification = 16
        let canvas = EditorCanvasNSView(); canvas.session = session; scroll.documentView = canvas; window.contentView = scroll
        defer { session.stop(); window.close() }
        session.fitZoom = false; session.zoom = zoom; scroll.synchronize(viewport:scroll.contentSize)
        canvas.refreshLayers()
        CATransaction.begin(); CATransaction.setDisableActions(true); canvas.canvasShadowLayer.shadowOpacity = 0; CATransaction.commit()
        let layer = try #require(canvas.layer), delegate = layer.delegate; layer.delegate = nil
        defer { layer.delegate = delegate }
        let scale = zoom*window.backingScaleFactor
        let region = canvas.viewRect(CGRect(x:10,y:205,width:300,height:20))
        func pixels() throws -> [UInt8] {
            let c = try EditorRenderer.context(width:Int(ceil(canvas.bounds.width*scale)),height:Int(ceil(canvas.bounds.height*scale)))
            c.translateBy(x:0,y:CGFloat(c.height)); c.scaleBy(x:scale,y:-scale); layer.render(in:c)
            return try rgba(#require(c.makeImage()?.cropping(to:CGRect(x:region.minX*scale,y:region.minY*scale,width:region.width*scale,height:region.height*scale).integral)))
        }
        let baseline = try pixels()
        session.add(tool:.arrow,from:CGPoint(x:30,y:30),to:CGPoint(x:270,y:160)); session.selectedID = nil; canvas.refreshLayers()
        canvas.canvasShadowLayer.shadowOpacity = 0
        let patched = try pixels()
        #expect(zip(baseline,patched).map { abs(Int($0)-Int($1)) }.max() == 0)
        #expect(stride(from:3,to:patched.count,by:4).map { patched[$0] }.min() == UInt8((alpha*255).rounded()))
        #expect(!window.isVisible)
    }
    @Test("Native padded and rounded tile edges match monolithic flat source strips at fractional zoom", arguments:[CGFloat(0.75),CGFloat(1.33),CGFloat(1.93),CGFloat(1855)/960])
    func nativePaddedTileEdges(physicalZoom:CGFloat) async throws {
        for alpha in [CGFloat(1),CGFloat(0.5)] {
            for preset in [EditorBackground.Preset.paper,.none] {
                try await nativePaddedTileEdges(physicalZoom:physicalZoom,alpha:alpha,preset:preset)
            }
        }
    }
    private func nativePaddedTileEdges(physicalZoom:CGFloat,alpha:CGFloat,preset:EditorBackground.Preset) async throws {
        let source = try EditorRenderer.context(width:960,height:600)
        source.setFillColor(CGColor(srgbRed:0.35,green:0.65,blue:0.48,alpha:alpha)); source.fill(CGRect(x:0,y:0,width:960,height:600))
        let session = EditorSession(); session.open(CapturedScreenshot(id:UUID(),image:try #require(source.makeImage()),pointSize:CGSize(width:960,height:600),kind:.screenshot,saveToDiskRequested:false)); await session.waitForRendering()
        session.edit { $0.background = EditorBackground(preset:preset,padding:32,cornerRadius:24,frameWidth:2,shadow:false,imageCorners:preset == .none ? .rounded : .square) }; await session.waitForRendering()
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:1315,height:792),styleMask:[.titled],backing:.buffered,defer:false); window.isReleasedWhenClosed = false
        let host = NSView(frame:CGRect(x:0,y:0,width:1315,height:792)); window.contentView = host
        let scroll = EditorScrollNSView(frame:CGRect(x:184.375,y:16.625,width:1127,height:735)); scroll.allowsMagnification = true; scroll.minMagnification = 0.02; scroll.maxMagnification = 16
        let canvas = EditorCanvasNSView(); canvas.session = session; scroll.documentView = canvas; host.addSubview(scroll)
        defer { session.stop(); window.close() }
        session.fitZoom = false; session.zoom = physicalZoom/window.backingScaleFactor; scroll.synchronize(viewport:scroll.contentSize); canvas.refreshLayers()
        let layer = try #require(canvas.layer), delegate = layer.delegate; layer.delegate = nil
        defer { layer.delegate = delegate }
        let scale = scroll.magnification*window.backingScaleFactor
        let origin = window.convertToBacking(CGRect(origin:canvas.convert(CGPoint.zero,to:nil),size:.zero)).origin
        let phase = CGPoint(x:origin.x-floor(origin.x),y:-origin.y-floor(-origin.y))
        #expect(abs(canvas.convert(CGSize(width:1,height:1),to:nil).width*window.backingScaleFactor-scale) < 0.0001)
        let sample = canvas.viewRect(CGRect(x:10,y:320,width:780,height:100))
        func pixels(_ renderedLayer:CALayer) throws -> [UInt8] {
            let c = try EditorRenderer.context(width:Int(ceil(canvas.bounds.width*scale))+2,height:Int(ceil(canvas.bounds.height*scale))+2)
            c.translateBy(x:phase.x,y:CGFloat(c.height)-phase.y); c.scaleBy(x:scale,y:-scale); renderedLayer.render(in:c)
            let rect = CGRect(x:phase.x+sample.minX*scale,y:phase.y+sample.minY*scale,width:sample.width*scale,height:sample.height*scale).integral
            return try rgba(#require(c.makeImage()?.cropping(to:rect)))
        }
        canvas.canvasShadowLayer.shadowOpacity = 0
        // The native tree currently contains one complete source bitmap. Its
        // flat band lies outside the arrow and crosses replacement tile edges.
        let monolithic = try pixels(layer)
        session.add(tool:.arrow,from:CGPoint(x:80,y:80),to:CGPoint(x:700,y:280)); session.selectedID = nil; canvas.refreshLayers(); canvas.canvasShadowLayer.shadowOpacity = 0
        let tiles = try #require(layer.sublayers?[2].sublayers)
        #expect(!tiles.isEmpty)
        for tile in tiles {
            let edge = window.convertToBacking(canvas.convert(tile.frame,to:nil))
            for value in [edge.minX,edge.minY,edge.maxX,edge.maxY] { #expect(abs(value-value.rounded()) < 0.0001) }
        }
        let patched = try pixels(layer)
        let monolithicDelta = zip(monolithic,patched).map { abs(Int($0)-Int($1)) }.max() ?? 0
        print("Tile reference: physical zoom \(physicalZoom), alpha \(alpha), background \(preset), maximum channel difference \(monolithicDelta)")
        #expect(monolithicDelta == 0)
        #expect(!window.isVisible)
    }
    @Test("True arrow points survive old records, all directions, zero-axis geometry and independent resize")
    func arrowEndpoints() throws {
        let starts: [CGPoint] = [.init(x: 10.25, y: 20.75), .init(x: 150, y: 10), .init(x: 20, y: 150), .init(x: 150, y: 150), .init(x: 10, y: 30), .init(x: 30, y: 10)]
        let ends: [CGPoint] = [.init(x: 130.5, y: 140.25), .init(x: 10, y: 130), .init(x: 150, y: 20), .init(x: 10, y: 20), .init(x: 150, y: 30), .init(x: 30, y: 150)]
        let session = EditorSession(); session.open(CapturedScreenshot(id: UUID(), image: try source().source, pointSize: CGSize(width: 320, height: 240), kind: .screenshot, saveToDiskRequested: false))
        for (start, end) in zip(starts, ends) {
            session.add(tool: .arrow, from: start, to: end)
            let arrow = try #require(session.selectedAnnotation)
            #expect(arrow.valid && arrow.resolvedArrowEndpoints.start == start && arrow.resolvedArrowEndpoints.end == end)
            let decoded = try JSONDecoder().decode(EditorAnnotation.self, from: JSONEncoder().encode(arrow))
            #expect(decoded == arrow)
            var moved = arrow; moved.setRect(arrow.rect.offsetBy(dx: 3, dy: 5))
            #expect(moved.resolvedArrowEndpoints.start == CGPoint(x: start.x + 3, y: start.y + 5))
            var endpoint = arrow; endpoint.setArrowEndpoints(start: start, end: CGPoint(x: 170, y: 180))
            #expect(endpoint.resolvedArrowEndpoints.start == start)
        }
        var legacy = EditorAnnotation(kind: .arrow, rect: CGRect(x: 20, y: 30, width: 40, height: 70), reversedX: true, reversedY: false)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "horizontalArrow"); object.removeValue(forKey: "verticalArrow")
        let decoded = try JSONDecoder().decode(EditorAnnotation.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.resolvedArrowEndpoints.start == CGPoint(x: 60, y: 30))
        #expect(decoded.resolvedArrowEndpoints.end == CGPoint(x: 20, y: 100))
        legacy.setRect(CGRect(x: 10, y: 10, width: 80, height: 140)); #expect(legacy.resolvedArrowEndpoints.start.x == 90)
        session.stop()
    }
    @Test("Viewport patches reproduce shared export pixels including overlapping multiply, prefix text and alpha", arguments: [1, 2, 5])
    func patchParity(scale: Int) throws {
        var doc = try source(scale: scale)
        let k = CGFloat(scale)
        doc.edits.annotations = [
            EditorAnnotation(kind: .rectangle, rect: CGRect(x: 28*k, y: 28*k, width: 160*k, height: 100*k), style: EditorStyle(lineWidth: 4)),
            EditorAnnotation(kind: .text, rect: CGRect(x: 30*k, y: 40*k, width: 200*k, height: 60*k), text: "Ready"),
            EditorAnnotation(kind: .highlight, rect: CGRect(x: 20*k, y: 50*k, width: 210*k, height: 80*k), style: EditorStyle(color: EditorRenderer.markerColor)),
            EditorAnnotation(kind: .arrow, rect: .zero, style: EditorStyle(lineWidth: 6), arrowStart: CGPoint(x: 70*k,y: 150*k), arrowEnd: CGPoint(x: 220*k,y: 170*k))]
        let base = try EditorRenderer.displayBase(doc), full = try EditorRenderer.render(doc)
        let renderer = EditorLiveRenderer(); renderer.invalidate(baseGeneration: 1, annotations: doc.edits.annotations)
        let patch = try renderer.compose(rect: doc.bounds, scale: 1, base: base, document: doc, annotations: doc.edits.annotations)
        #expect(try rgba(patch) == rgba(full.image))
        let computations = renderer.treatmentComputations
        _ = try renderer.compose(rect: CGRect(x: 80*k,y: 60*k,width: 20*k,height: 20*k), scale: 1, base: base, document: doc, annotations: doc.edits.annotations)
        #expect(renderer.treatmentComputations == computations)
        let transparent = try source(scale: scale, alpha: 0.4)
        let transparentBase = try EditorRenderer.displayBase(transparent)
        renderer.invalidate(baseGeneration: 2, annotations: [])
        let raw = try renderer.compose(rect: transparent.bounds, scale: 1, base: transparentBase, document: transparent, annotations: [])
        #expect(try rgba(raw) == rgba(transparentBase.image))
    }
    @Test("Independent card and image corners retain export parity and underlay statistics", arguments: [1, 2], [EditorBackground.Preset.paper, .graphite, .gradient])
    func backgroundPatchParity(scale: Int, preset: EditorBackground.Preset) throws {
        for alpha in [1.0, 0.4] { for corners in EditorBackground.ImageCorners.allCases {
        var doc = try source(scale: scale, alpha: alpha); doc.edits.background.preset = preset; doc.edits.background.padding = 20; doc.edits.background.frameWidth = 2; doc.edits.background.cornerRadius = 40; doc.edits.background.shadow = true
        doc.edits.background.imageCorners = corners
        doc.edits.annotations = [EditorAnnotation(kind:.highlight,rect:CGRect(x:0,y:0,width:150*scale,height:70*scale),style:EditorStyle(color:EditorRenderer.markerColor))]
        let base = try EditorRenderer.displayBase(doc), full = try EditorRenderer.render(doc)
        let renderer = EditorLiveRenderer(); renderer.invalidate(baseGeneration:1,annotations:doc.edits.annotations)
        let live = try renderer.compose(rect:doc.bounds,scale:1,base:base,document:doc,annotations:doc.edits.annotations)
        var rawDoc = doc; rawDoc.edits.background.preset = .none; rawDoc.edits.background.imageCorners = .auto
        let rawExpected = try EditorRenderer.render(rawDoc)
        let rawLive = try renderer.compose(rect:doc.bounds,scale:1,base:base,document:doc,annotations:doc.edits.annotations,samplingUnderlay:true)
        #expect(try rgba(rawLive) == rgba(rawExpected.image))
        let expected = try #require(full.image.cropping(to:CGRect(x:22,y:22,width:doc.bounds.width,height:doc.bounds.height)))
        let a = try rgba(live), b = try rgba(expected)
        let mismatch = zip(a,b).filter { $0 != $1 }.count
        if mismatch > 0 { print("Editor background parity", scale, preset.rawValue, "mismatch", mismatch, "samples", a.indices.filter { a[$0] != b[$0] }.prefix(12).map { "\($0):\(a[$0])/\(b[$0])" }) }
        #expect(mismatch == 0)
        for region in [CGRect(x: 0,y: 0,width: 64,height: 64), CGRect(x: doc.bounds.maxX-64,y:doc.bounds.maxY-64,width:64,height:64)] {
            let tile = try renderer.compose(rect:region,scale:1,base:base,document:doc,annotations:doc.edits.annotations)
            let tileExpected = try #require(full.image.cropping(to:region.offsetBy(dx:22,dy:22)))
            #expect(try rgba(tile) == rgba(tileExpected))
        } }
        }
    }
    @Test("A pending solid redact covers every live patch before highlight and does not expose old source")
    func pendingPrivacy() throws {
        var doc = try source(); let originalBase = try EditorRenderer.displayBase(doc)
        let rect = CGRect(x: 40, y: 80, width: 160, height: 30)
        doc.edits.annotations = [EditorAnnotation(kind: .highlight, rect: rect, style: EditorStyle(color: EditorRenderer.markerColor)), EditorAnnotation(kind: .redact, rect: rect)]
        let renderer = EditorLiveRenderer(); renderer.invalidate(baseGeneration: 1, annotations: doc.edits.annotations)
        let image = try renderer.compose(rect: rect, scale: 1, base: originalBase, document: doc, annotations: doc.edits.annotations)
        let bytes = try rgba(image)
        for i in stride(from: 0, to: bytes.count, by: 4) { #expect(bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 255) }
    }
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try EditorRenderer.context(width: image.width, height: image.height)
        context.setBlendMode(.copy); context.draw(image, in: CGRect(x:0,y:0,width:image.width,height:image.height))
        return Array(UnsafeBufferPointer(start: try #require(context.data?.assumingMemoryBound(to: UInt8.self)), count: context.bytesPerRow * context.height))
    }
    @Test("Persistent layer replacement composites semi-transparent destination only once at physical 100 percent")
    func nativeLayerAlpha() async throws {
        let doc = try source(alpha: 0.4)
        let session = EditorSession(); session.open(CapturedScreenshot(id: UUID(), image: doc.source, pointSize: doc.pointSize, kind: .screenshot, saveToDiskRequested: false)); await session.waitForRendering()
        let window = NSWindow(contentRect: CGRect(x:0,y:0,width:600,height:480),styleMask:[.titled],backing:.buffered,defer:false); window.isReleasedWhenClosed = false
        let scroll = EditorScrollNSView(frame: CGRect(x:0,y:0,width:600,height:480)); scroll.allowsMagnification = true; scroll.minMagnification = 0.02; scroll.maxMagnification = 16
        let canvas = EditorCanvasNSView(); canvas.session = session; scroll.documentView = canvas; window.contentView = scroll
        defer { session.stop(); window.close() }
        session.fitZoom = false; session.zoom = session.actualPixelZoom; scroll.synchronize(viewport:scroll.contentSize)
        for _ in 0..<20 { await Task.yield() }
        session.add(tool:.highlight,from:CGPoint(x:20,y:30),to:CGPoint(x:210,y:140)); session.selectedID = nil; canvas.refreshLayers(); window.displayIfNeeded(); canvas.layer?.displayIfNeeded()
        CATransaction.begin(); CATransaction.setDisableActions(true); canvas.canvasShadowLayer.shadowOpacity = 0; CATransaction.commit()
        let layer = try #require(canvas.layer)
        let delegate = layer.delegate; layer.delegate = nil
        defer { layer.delegate = delegate }
        let context = try EditorRenderer.context(width:Int(canvas.bounds.width),height:Int(canvas.bounds.height))
        context.translateBy(x:0,y:canvas.bounds.height); context.scaleBy(x:1,y:-1)
        layer.render(in:context)
        let image = try #require(context.makeImage()?.cropping(to:CGRect(origin:canvas.imageOrigin,size:canvas.imageSize)))
        let full = try EditorRenderer.render(#require(session.document))
        let actual = try rgba(image), expected = try rgba(full.image)
        let mismatch = zip(actual,expected).filter { $0 != $1 }.count
        #expect(mismatch == 0)
        #expect(session.canvasZoom * session.backingScale == 1)
        // Compare actual masked source + replacement tiles over the common UI
        // shadow/destination against one flattened layer over that same shadow.
        // The whole source rectangle is compared; only outside decoration is omitted.
        CATransaction.begin(); CATransaction.setDisableActions(true); canvas.canvasShadowLayer.shadowOpacity = 1; CATransaction.commit()
        func composite() throws -> [UInt8] {
            let c = try EditorRenderer.context(width:Int(canvas.bounds.width),height:Int(canvas.bounds.height))
            c.setFillColor(CGColor(srgbRed:0.3,green:0.4,blue:0.5,alpha:1)); c.fill(canvas.bounds)
            c.translateBy(x:0,y:canvas.bounds.height); c.scaleBy(x:1,y:-1); layer.render(in:c)
            return try rgba(#require(c.makeImage()?.cropping(to:CGRect(origin:canvas.imageOrigin,size:canvas.imageSize))))
        }
        let liveComposite = try composite()
        let reference = CALayer(); reference.frame = layer.bounds; reference.isGeometryFlipped = layer.isGeometryFlipped
        let shadow = CALayer(), imageLayer = CALayer()
        shadow.frame = canvas.canvasShadowLayer.frame; shadow.shadowColor = canvas.canvasShadowLayer.shadowColor
        shadow.shadowOpacity = canvas.canvasShadowLayer.shadowOpacity; shadow.shadowRadius = canvas.canvasShadowLayer.shadowRadius
        shadow.shadowOffset = canvas.canvasShadowLayer.shadowOffset; shadow.shadowPath = canvas.canvasShadowLayer.shadowPath
        imageLayer.frame = canvas.baseLayer.frame; imageLayer.contents = full.image; imageLayer.isGeometryFlipped = canvas.baseLayer.isGeometryFlipped
        if canvas.baseLayer.contentsAreFlipped() != imageLayer.contentsAreFlipped() { imageLayer.transform = CATransform3DMakeScale(1,-1,1) }
        imageLayer.contentsScale = canvas.baseLayer.contentsScale; imageLayer.minificationFilter = .trilinear; imageLayer.magnificationFilter = .nearest
        reference.addSublayer(shadow); reference.addSublayer(imageLayer)
        let c = try EditorRenderer.context(width:Int(canvas.bounds.width),height:Int(canvas.bounds.height))
        c.setFillColor(CGColor(srgbRed:0.3,green:0.4,blue:0.5,alpha:1)); c.fill(canvas.bounds)
        c.translateBy(x:0,y:canvas.bounds.height); c.scaleBy(x:1,y:-1); reference.render(in:c)
        let flatComposite = try rgba(#require(c.makeImage()?.cropping(to:CGRect(origin:canvas.imageOrigin,size:canvas.imageSize))))
        let compositeMismatch = zip(liveComposite,flatComposite).filter { $0 != $1 }.count
        if compositeMismatch > 0 { print("COMPOSITE",compositeMismatch,liveComposite.indices.filter { liveComposite[$0] != flatComposite[$0] }.prefix(16).map { "\($0):\(liveComposite[$0])/\(flatComposite[$0])" }) }
        #expect(compositeMismatch == 0)
    }
    @Test("Native mouse gestures draw actual transient arrows, move with every tool, resize outside handles and commit one undo")
    func nativeGesture() async throws {
        let session = EditorSession(); session.open(CapturedScreenshot(id: UUID(), image: try source().source, pointSize: CGSize(width:320,height:240), kind:.screenshot, saveToDiskRequested:false)); await session.waitForRendering()
        let window = NSWindow(contentRect: CGRect(x:0,y:0,width:600,height:480), styleMask:[.titled], backing:.buffered, defer:false); window.isReleasedWhenClosed = false
        let scroll = EditorScrollNSView(frame: CGRect(x:0,y:0,width:600,height:480)); scroll.allowsMagnification = true; scroll.minMagnification = 0.02; scroll.maxMagnification = 16
        let canvas = EditorCanvasNSView(); canvas.session = session; scroll.documentView = canvas; window.contentView = scroll
        session.fitZoom = false; session.zoom = 1; scroll.synchronize(viewport: scroll.contentSize)
        defer { session.stop(); window.close() }
        func event(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) throws -> NSEvent {
            let p = canvas.convert(point, to:nil)
            return try #require(NSEvent.mouseEvent(with:type, location:p, modifierFlags:[], timestamp:0, windowNumber:window.windowNumber, context:nil, eventNumber:0, clickCount:clicks, pressure:1))
        }
        func drag(_ from: CGPoint, _ to: CGPoint) throws {
            canvas.mouseDown(with:try event(.leftMouseDown,from)); canvas.mouseDragged(with:try event(.leftMouseDragged,to)); canvas.mouseUp(with:try event(.leftMouseUp,to))
        }
        let image = try #require(canvas.baseLayer.contents) as AnyObject
        session.tool = .arrow
        let from = canvas.viewRect(CGRect(x:20,y:20,width:0,height:0)).origin, to = canvas.viewRect(CGRect(x:160,y:120,width:0,height:0)).origin
        canvas.mouseDown(with:try event(.leftMouseDown,from)); canvas.mouseDragged(with:try event(.leftMouseDragged,to))
        #expect(session.document?.edits.annotations.isEmpty == true)
        #expect(canvas.candidateAnnotation?.kind == .arrow)
        #expect(canvas.candidateAnnotation?.resolvedArrowEndpoints.end == CGPoint(x:160,y:120))
        #expect(canvas.baseLayer.contents as AnyObject? === image)
        canvas.mouseUp(with:try event(.leftMouseUp,to)); #expect(session.document?.edits.annotations.count == 1 && session.selectedID != nil)
        let arrow = try #require(session.selectedAnnotation)
        #expect(canvas.handlePoints(for:arrow).count == 2)
        session.tool = .text
        let middle = canvas.viewRect(CGRect(x:90,y:70,width:0,height:0)).origin
        try drag(middle,CGPoint(x:middle.x+10,y:middle.y+8))
        #expect(session.document?.edits.annotations.count == 1)
        let movedStart = try #require(session.selectedAnnotation?.resolvedArrowEndpoints.start)
        #expect(abs(movedStart.x - 30) < 0.0001 && abs(movedStart.y - 28) < 0.0001)
        session.undo(); #expect(session.selectedAnnotation?.resolvedArrowEndpoints.start == arrow.resolvedArrowEndpoints.start)
        session.undo(); #expect(session.document?.edits.annotations.isEmpty == true && !session.canUndo)
        session.redo(); session.redo(); #expect(session.document?.edits.annotations.count == 1)
        for tool in EditorTool.allCases {
            session.tool = tool
            let arrow = try #require(session.selectedAnnotation), pair = arrow.resolvedArrowEndpoints
            let middle = canvas.viewRect(CGRect(origin:CGPoint(x:(pair.start.x+pair.end.x)/2,y:(pair.start.y+pair.end.y)/2),size:.zero)).origin
            try drag(middle,CGPoint(x:middle.x+2,y:middle.y+3))
            #expect(session.document?.edits.annotations.count == 1 && session.selectedAnnotation?.rect != arrow.rect)
            session.undo(); #expect(session.selectedAnnotation == arrow)
        }
        session.tool = .rectangle; session.add(tool:.rectangle,from:.init(x:0,y:0),to:.init(x:60,y:60)); canvas.refreshLayers()
        let rectangle = try #require(session.selectedAnnotation); let points = canvas.handlePoints(for:rectangle); #expect(points.count == 8)
        #expect(points[0].x < canvas.viewRect(rectangle.rect).minX && points[0].y < canvas.viewRect(rectangle.rect).minY)
        try drag(points[3],CGPoint(x:points[3].x+20,y:points[3].y)); #expect(session.selectedAnnotation?.rect.width == 80)
        #expect(session.displayRasterRequests == 1)
        let beforeEscape = session.document?.edits
        session.selectedID = nil; session.tool = .arrow
        let escapeStart = canvas.viewRect(CGRect(x:200,y:20,width:0,height:0)).origin
        canvas.mouseDown(with:try event(.leftMouseDown,escapeStart)); canvas.mouseDragged(with:try event(.leftMouseDragged,CGPoint(x:escapeStart.x+40,y:escapeStart.y+40)))
        let escape = try #require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53))
        canvas.keyDown(with:escape); #expect(canvas.candidateAnnotation == nil && session.document?.edits == beforeEscape)
        session.selectedID = rectangle.id
        let delete = try #require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\u{7f}",charactersIgnoringModifiers:"\u{7f}",isARepeat:false,keyCode:51))
        canvas.keyDown(with:delete); #expect(session.document?.edits.annotations.count == 1)
        session.tool = .text
        let textPoint = canvas.viewRect(CGRect(x:200,y:160,width:0,height:0)).origin
        try drag(textPoint,textPoint)
        #expect(session.showsAnnotationEditor && session.selectedAnnotation?.kind == .text)
        session.tool = .rectangle; #expect(!session.showsAnnotationEditor)
        let textMiddle = canvas.viewRect(CGRect(x:250,y:184,width:0,height:0)).origin
        let beforeDoubleClick = session.document?.edits
        canvas.mouseDown(with:try event(.leftMouseDown,textMiddle,clicks:2))
        canvas.mouseUp(with:try event(.leftMouseUp,textMiddle,clicks:2))
        #expect(session.showsAnnotationEditor && session.document?.edits == beforeDoubleClick)
        session.reportBackingScale(2); #expect(session.actualPixelZoom == 0.5)
    }
}

private actor EditorDisplayRenderGate {
    private var blocked = false
    private let gate = EditorTestGate()
    func render(_ document: EditorDocument) async throws -> EditorDisplayBase {
        if !blocked && document.edits.annotations.contains(where: { $0.kind == .redact }) { blocked = true; await gate.suspend() }
        return try EditorRenderer.displayBase(document)
    }
    func waitForStart() async { await gate.waitForStart() }
    func resume() async { await gate.resume() }
}
