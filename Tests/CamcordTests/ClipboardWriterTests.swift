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
    @Test("save completion publishes a fully written PNG without delaying clipboard delivery")
    @MainActor
    func asynchronousSavePublishesCompleteFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: .init("dev.tavsan.camcord.tests.save.\(UUID().uuidString)"))
        let image = try #require(makeTestImage(width: 16, height: 12))
        let settings = ScreenshotSettings(saveToDisk: true, saveDirectoryPath: directory.path)
        var result: Result<URL, Error>?
        #expect(await ClipboardWriter.copyPNG(image, to: pasteboard, saveSettings: settings, onSaveComplete: { result = $0 }))
        let copied = try #require(pasteboard.data(forType: .png))
        await ClipboardWriter.waitForPendingSaves()
        let saved = try #require(result).get()
        #expect(try Data(contentsOf: saved) == copied)
        #expect(try #require(NSBitmapImageRep(data: Data(contentsOf: saved))).pixelsWide == 16)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasSuffix(".pending") })
    }

    @Test("failed save preserves an existing file and the successful clipboard copy")
    @MainActor
    func failedSavePreservesClipboardAndExistingFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-save-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.png")
        let sentinel = Data("previous user file".utf8)
        try sentinel.write(to: destination)
        let pasteboard = NSPasteboard(name: .init("dev.tavsan.camcord.tests.save-failure.\(UUID().uuidString)"))
        let image = try #require(makeTestImage())
        var failed = false
        #expect(await ClipboardWriter.copyPNG(image, to: pasteboard, saveTo: destination, onSaveComplete: {
            if case .failure = $0 { failed = true }
        }))
        await ClipboardWriter.waitForPendingSaves()
        #expect(failed)
        #expect(try Data(contentsOf: destination) == sentinel)
        #expect(pasteboard.data(forType: .png) != nil)
    }

    @Test("superseded image encoding preserves the newer clipboard result but still saves the screenshot")
    @MainActor
    func supersededPublicationStillSaves() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-superseded-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: .init("dev.tavsan.camcord.tests.superseded.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("newer OCR result", forType: .string)
        let originalChange = pasteboard.changeCount
        let image = try #require(makeTestImage(width: 64, height: 48))
        var saved: Result<URL, Error>?
        let copied = await ClipboardWriter.copyPNG(
            image, to: pasteboard,
            saveSettings: ScreenshotSettings(saveToDisk: true, saveDirectoryPath: directory.path),
            shouldPublish: { false }, onSaveComplete: { saved = $0 }
        )
        #expect(!copied)
        #expect(pasteboard.changeCount == originalChange)
        #expect(pasteboard.string(forType: .string) == "newer OCR result")
        await ClipboardWriter.waitForPendingSaves()
        let file = try #require(saved).get()
        #expect(try #require(NSBitmapImageRep(data: Data(contentsOf: file))).pixelsWide == 64)
    }

}
