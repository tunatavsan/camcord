import AppKit
import ImageIO
import Testing
import Darwin
import UniformTypeIdentifiers
@testable import Camcord

@Suite("Typed screenshot card", .serialized)
@MainActor struct ScreenshotCardTests {
    private func capture(id: UUID = UUID(), image: CGImage? = nil) throws -> CapturedScreenshot {
        let context = try #require(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 1600,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let raster: CGImage
        if let image { raster = image } else { raster = try #require(context.makeImage()) }
        return CapturedScreenshot(id: id, image: raster, pointSize: CGSize(width: 200, height: 100), kind: .screenshot, saveToDiskRequested: true)
    }
    // Foundation may expose /var even after resolving a /private/var alias. This fixture
    // obtains an actual physical Darwin path before injecting the unnormalized test root.
    private func physicalTemporaryRoot() throws -> URL {
        let path = FileManager.default.temporaryDirectory.withUnsafeFileSystemRepresentation { raw -> String? in
            guard let raw, let resolved = Darwin.realpath(raw, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: try #require(path), isDirectory: true)
    }

    @Test("shared raster pointers never bind a later capture's save")
    func lateSaveIdentity() throws {
        let first = try capture(), next = try capture(image: first.image)
        let model = ScreenshotCardModel(capture: next)
        let oldURL = URL(fileURLWithPath: "/private/old.png"), currentURL = URL(fileURLWithPath: "/private/current.png")
        model.saved(id: first.id, to: oldURL)
        #expect(model.savedURL == nil)
        model.saved(id: next.id, to: currentURL)
        #expect(model.savedURL == currentURL)
        model.invalidate(); model.saved(id: next.id, to: oldURL)
        #expect(model.savedURL == currentURL)
    }
    @Test("real PNG copy and temporary export retain numeric Retina density")
    func realDensity() async throws {
        let manager = FileManager.default
        let fixture = try physicalTemporaryRoot().appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }
        var operations = ScreenshotCardModel.Operations()
        operations.exports = ScreenshotTemporaryExports(directory: fixture.appendingPathComponent("exports"))
        let model = ScreenshotCardModel(capture: try capture(), operations: operations)
        let board = NSPasteboard(name: .init("camcord.card." + UUID().uuidString))
        defer { board.releaseGlobally() }
        #expect(await model.copy(to: board))
        let copy = try #require(board.data(forType: .png))
        let url = try await model.exportedFileURL()
        let exported = try Data(contentsOf: url)
        #expect(exported == copy)
        let source = try #require(CGImageSourceCreateWithData(exported as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            let density = try #require(properties[key as String] as? NSNumber)
            #expect(abs(density.doubleValue - 144) < 0.1)
        }
        #expect(properties[kCGImagePropertyExifDictionary as String] == nil)
        #expect(model.capture.pointSize == CGSize(width: 200, height: 100))
    }
    @Test("an accepted drag exports its frozen capture after a replacement")
    func frozenDrag() async throws {
        let manager = FileManager.default
        let fixture = try physicalTemporaryRoot().appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }
        var operations = ScreenshotCardModel.Operations()
        operations.exports = ScreenshotTemporaryExports(directory: fixture.appendingPathComponent("exports"))
        let first = try capture(), model = ScreenshotCardModel(capture: first, operations: operations)
        let provider = model.dragProvider()
        model.invalidate()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.png.identifier) { url, error in
                if let error { continuation.resume(throwing: error); return }
                guard let url else { continuation.resume(throwing: CocoaError(.fileReadUnknown)); return }
                do { continuation.resume(returning: try Data(contentsOf: url)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        #expect(data == (try EditorRendered(image: first.image, pointSize: first.pointSize).png))
    }
    @Test("Copy claims the shared publication epoch before awaiting encode and rejects a later publisher")
    func staleCopy() async throws {
        let board = NSPasteboard(name: .init("camcord.card." + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("newer value", forType: .string)
        var suspended: CheckedContinuation<Void, Never>?
        var entered = false, claims = 0
        var shared = LatestRequestGate()
        var operations = ScreenshotCardModel.Operations()
        operations.copy = { _, board, mayPublish in
            entered = true
            await withCheckedContinuation { suspended = $0 }
            guard mayPublish() else { return false }
            board.clearContents(); return board.setString("stale value", forType: .string)
        }
        let model = ScreenshotCardModel(capture: try capture(), operations: operations)
        model.claimClipboardPublication = {
            claims += 1
            let token = shared.begin()
            return { shared.isCurrent(token) }
        }
        let copy = Task { await model.copy(to: board) }
        while !entered { await Task.yield() }
        #expect(claims == 1)
        _ = shared.begin()
        suspended?.resume()
        #expect(await copy.value == false)
        #expect(board.string(forType: .string) == "newer value")
        #expect(model.error == nil)
    }
    @Test("replacement invalidates suspended Copy before it can clear the board")
    func replacedCopy() async throws {
        let board = NSPasteboard(name: .init("camcord.card." + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("keep", forType: .string)
        var suspended: CheckedContinuation<Void, Never>?
        var entered = false
        var operations = ScreenshotCardModel.Operations()
        operations.copy = { _, board, mayPublish in
            entered = true
            await withCheckedContinuation { suspended = $0 }
            guard mayPublish() else { return false }
            board.clearContents(); return board.setString("old", forType: .string)
        }
        let model = ScreenshotCardModel(capture: try capture(), operations: operations)
        let request = Task { await model.copy(to: board) }
        while !entered { await Task.yield() }
        model.invalidate(); suspended?.resume()
        #expect(await request.value == false)
        #expect(board.string(forType: .string) == "keep")
    }
    @Test("the palette routes all five genuine capture kinds")
    func captureRouting() {
        var invoked: [CaptureKind] = []
        var actions = PanelActions()
        actions.captureRegion = { invoked.append(.region) }
        actions.captureWindow = { invoked.append(.window) }
        actions.captureScreen = { invoked.append(.screen) }
        actions.captureScroll = { invoked.append(.scroll) }
        actions.captureText = { invoked.append(.text) }
        for kind in CaptureKind.allCases { actions.perform(kind) }
        #expect(invoked == CaptureKind.allCases)
    }
}
