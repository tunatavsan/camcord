import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Camcord

@Suite("Screenshot editor pixels and privacy")
struct EditorRendererTests {
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
        session.stop(); second.stop()
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
