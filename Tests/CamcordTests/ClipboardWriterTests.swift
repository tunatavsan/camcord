import AppKit
import CoreGraphics
import Testing

@testable import Camcord

@Suite("ClipboardWriter")
struct ClipboardWriterTests {

    /// A named (non-`.general`) pasteboard so tests never touch the user's real clipboard.
    private static let testPasteboardName = NSPasteboard.Name("dev.tavsan.camcord.tests")

    private func makeTestImage(width: Int = 4, height: Int = 4) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    @Test("copies a synthetic image to a named pasteboard as PNG")
    @MainActor
    func copiesPNGToNamedPasteboard() async throws {
        let pasteboard = NSPasteboard(name: Self.testPasteboardName)
        guard let image = makeTestImage(width: 4, height: 4) else {
            Issue.record("Failed to synthesize a test CGImage")
            return
        }

        let succeeded = await ClipboardWriter.copyPNG(image, to: pasteboard)
        #expect(succeeded)

        guard let data = pasteboard.data(forType: .png) else {
            Issue.record("Pasteboard has no PNG data after copyPNG -- headless pasteboard may be unavailable in this environment")
            return
        }
        #expect(!data.isEmpty)

        guard let rep = NSBitmapImageRep(data: data) else {
            Issue.record("PNG data did not decode into an NSBitmapImageRep")
            return
        }
        #expect(rep.pixelsWide == 4)
        #expect(rep.pixelsHigh == 4)
    }

    @Test("pointSize is embedded as the PNG's density: the decoded rep reports points, not pixels")
    @MainActor
    func pointSizeEmbedsDensity() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.tavsan.camcord.tests.dpi"))
        // A "Retina" capture: 8x8 pixels representing a 4x4-point on-screen area.
        guard let image = makeTestImage(width: 8, height: 8) else {
            Issue.record("Failed to synthesize a test CGImage")
            return
        }

        let succeeded = await ClipboardWriter.copyPNG(image, pointSize: CGSize(width: 4, height: 4), to: pasteboard)
        #expect(succeeded)

        guard let data = pasteboard.data(forType: .png) else {
            Issue.record("Pasteboard has no PNG data after copyPNG -- headless pasteboard may be unavailable in this environment")
            return
        }
        guard let rep = NSBitmapImageRep(data: data) else {
            Issue.record("PNG data did not decode into an NSBitmapImageRep")
            return
        }
        // Without the density tag this would read 8x8 (72dpi) and Retina captures
        // would paste at 2x their physical size in DPI-aware apps.
        #expect(rep.pixelsWide == 8)
        #expect(rep.pixelsHigh == 8)
        #expect(rep.size == CGSize(width: 4, height: 4))
    }
}
