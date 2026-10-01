import CoreGraphics
import Foundation
import Testing
@testable import Camcord

@Suite("Typed screenshot delivery routing")
@MainActor struct ScreenshotDeliveryFanoutTests {
    private func capture(id: UUID = UUID(), originDisplayID: CGDirectDisplayID? = nil) throws -> CapturedScreenshot {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return CapturedScreenshot(id: id, image: try #require(context.makeImage()), pointSize: CGSize(width: 1, height: 1), kind: .screenshot, saveToDiskRequested: true, originDisplayID: originDisplayID)
    }
    @Test("Library observes every event before the corresponding card action and early save replays after ready")
    func orderAndReplay() throws {
        let capture = try capture(originDisplayID: 47), url = URL(fileURLWithPath: "/private/shot.png")
        var log: [String] = []
        var imageIdentity: CGImage?
        var libraryOrigins: [CGDirectDisplayID?] = []
        var cardOrigin: CGDirectDisplayID?
        let fanout = ScreenshotDeliveryFanout(ingest: { event in
            switch event {
            case .ready(let value), .saved(let value, _), .saveFailed(let value): libraryOrigins.append(value.originDisplayID)
            }
            switch event { case .ready: log.append("library ready"); case .saved: log.append("library saved"); case .saveFailed: log.append("library failed") }
        }, ready: { value in imageIdentity = value.image; cardOrigin = value.originDisplayID; log.append("card ready") },
        saved: { id, value in #expect(id == capture.id); #expect(value == url); log.append("card saved") },
        saveFailed: { _ in log.append("card failed") })
        fanout.receive(.saved(capture, url))
        #expect(fanout.pendingSaveCount == 1)
        fanout.receive(.ready(capture))
        #expect(imageIdentity === capture.image)
        #expect(cardOrigin == 47)
        #expect(fanout.pendingSaveCount == 0)
        fanout.receive(.saveFailed(capture))
        #expect(libraryOrigins == [47, 47, 47])
        #expect(log == ["library saved", "card saved", "library ready", "card ready", "card saved", "library failed", "card failed"])
    }
    @Test("older screenshot construction leaves origin unknown without deriving a display from point size")
    func legacyOriginIsUnknown() throws {
        let value = try capture()
        let legacy = CapturedScreenshot(id: value.id, image: value.image, pointSize: value.pointSize,
                                        kind: value.kind, saveToDiskRequested: value.saveToDiskRequested)
        #expect(legacy.originDisplayID == nil)
    }
    @Test("the insertion-order limit evicts only replay state and never drops Library saves")
    func boundedReplay() throws {
        let captures = try (0..<18).map { _ in try capture() }
        let urls = (0..<18).map { URL(fileURLWithPath: "/private/shot-\($0).png") }
        var ingestedSaves = 0, deliveredSaves: [UUID] = []
        let fanout = ScreenshotDeliveryFanout(ingest: { if case .saved = $0 { ingestedSaves += 1 } }, ready: { _ in },
            saved: { id, _ in deliveredSaves.append(id) }, saveFailed: { _ in })
        for (capture, url) in zip(captures, urls) { fanout.receive(.saved(capture, url)) }
        #expect(ingestedSaves == 18)
        #expect(deliveredSaves == captures.map(\.id))
        #expect(fanout.pendingSaveCount == 16)
        deliveredSaves.removeAll()
        fanout.receive(.ready(captures[0])); fanout.receive(.ready(captures[1]))
        #expect(deliveredSaves.isEmpty)
        fanout.receive(.ready(captures[2]))
        #expect(deliveredSaves == [captures[2].id])
        #expect(fanout.pendingSaveCount == 15)
    }
    @Test("same-ID URL replacement keeps insertion order; failure removes only its matching replay")
    func replacementAndFailure() throws {
        let first = try capture(), second = try capture()
        let original = URL(fileURLWithPath: "/private/original.png"), final = URL(fileURLWithPath: "/private/final.png")
        var savedURLs: [URL] = [], failures: [UUID] = []
        let fanout = ScreenshotDeliveryFanout(ingest: { _ in }, ready: { _ in }, saved: { _, url in savedURLs.append(url) }, saveFailed: { failures.append($0.id) })
        fanout.receive(.saved(first, original)); fanout.receive(.saved(first, final)); fanout.receive(.saved(second, original))
        #expect(fanout.pendingSaveCount == 2)
        fanout.receive(.saveFailed(second))
        #expect(failures == [second.id]); #expect(fanout.pendingSaveCount == 1)
        savedURLs.removeAll()
        fanout.receive(.ready(second)); #expect(savedURLs.isEmpty)
        fanout.receive(.ready(first)); #expect(savedURLs == [final]); #expect(fanout.pendingSaveCount == 0)
    }
    @Test("ordinary late saves reach the matching card without building replay state")
    func lateSave() throws {
        let capture = try capture(), url = URL(fileURLWithPath: "/private/saved.png")
        var savedIDs: [UUID] = []
        let fanout = ScreenshotDeliveryFanout(ingest: { _ in }, ready: { _ in }, saved: { id, _ in savedIDs.append(id) }, saveFailed: { _ in })
        fanout.receive(.ready(capture)); fanout.receive(.saved(capture, url))
        #expect(savedIDs == [capture.id]); #expect(fanout.pendingSaveCount == 0)
    }
}
