import AppKit
import Testing

@testable import Camcord

@MainActor
@Suite("Camcord brand artwork")
struct CamcordBrandTests {
    private static let resource = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/MenuBarIcon.svg")

    @Test("the delivered vector loads as a visible 18-point monochrome template")
    func templateLoadsAndRenders() throws {
        let image = try #require(CamcordBrandAssets.loadTemplateImage(at: Self.resource))
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.isTemplate)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        let bytes = try #require(bitmap.bitmapData)
        var opaquePixels = 0
        var clearPixels = 0
        for y in 0..<36 {
            for x in 0..<36 {
                let offset = y * bitmap.bytesPerRow + x * 4
                if bytes[offset + 3] == 0 {
                    clearPixels += 1
                } else {
                    opaquePixels += 1
                    #expect(bytes[offset] == 0 && bytes[offset + 1] == 0 && bytes[offset + 2] == 0)
                }
            }
        }
        #expect(opaquePixels > 100)
        #expect(clearPixels > 100)
    }

    @Test("shared artwork keeps one image identity and rejects an unreadable source")
    func cacheAndMissingSource() {
        #expect(CamcordBrandAssets.templateImage === CamcordBrandAssets.templateImage)
        #expect(CamcordBrandAssets.templateImage.isTemplate)
        #expect(CamcordBrandAssets.templateImage.size == NSSize(width: 18, height: 18))
        #expect(CamcordBrandAssets.loadTemplateImage(at: Self.resource.deletingLastPathComponent()) == nil)
    }
}
