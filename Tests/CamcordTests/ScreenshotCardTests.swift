import AppKit
import ImageIO
import Testing
import Darwin
import UniformTypeIdentifiers
@testable import Camcord

@Suite("Typed screenshot card", .serialized)
@MainActor struct ScreenshotCardTests {
    @Test("portrait, landscape, long and small captures fit wholly inside the fixed well", arguments: [
        CGSize(width: 960, height: 540), CGSize(width: 540, height: 960),
        CGSize(width: 300, height: 6_000), CGSize(width: 960, height: 25), CGSize(width: 120, height: 60)
    ])
    func wholeCaptureGeometry(size: CGSize) {
        let well = CGRect(origin: .zero, size: ScreenshotCardGeometry.well)
        let rect = ScreenshotCardGeometry(sourceSize: size).imageRect
        #expect(well.insetBy(dx: -0.001, dy: -0.001).contains(rect))
        #expect(abs(rect.width / size.width - rect.height / size.height) < 0.000_001)
        #expect(abs(rect.midX - well.midX) < 0.001 && abs(rect.midY - well.midY) < 0.001)
        // Large captures reach the well on one axis; small ones keep their own size.
        let fills = abs(rect.width - well.width) < 0.001 || abs(rect.height - well.height) < 0.001
        #expect(fills || rect.size == size)
    }

    @Test("invalid preview bounds remain finite and never divide by zero")
    func invalidPreviewGeometry() {
        for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 1), CGSize(width: 1, height: -2)] {
            #expect(ScreenshotCardGeometry(sourceSize: size).imageRect == .zero)
        }
    }

    @Test("explicit Save writes the complete Retina PNG and publishes only its own destination")
    func explicitSave() async throws {
        let root = try physicalTemporaryRoot().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("saved.png"), shot = try capture()
        let model = ScreenshotCardModel(capture: shot)
        #expect(await model.save(to: destination))
        #expect(model.savedURL == destination)
        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == 400)
        #expect(properties[kCGImagePropertyPixelHeight as String] as? Int == 200)
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            let density = try #require(properties[key as String] as? NSNumber)
            #expect(abs(density.doubleValue - 144) < 0.1)
        }
        #expect(!model.isBusy && model.error == nil)
    }

    @Test("a dismissed card cannot finish an encoding Save into the user's destination")
    func staleSave() async throws {
        let root = try physicalTemporaryRoot().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let barrier = CardSaveEncodingBarrier()
        var operations = ScreenshotCardModel.Operations()
        operations.encode = { _ in await barrier.encode() }
        let model = ScreenshotCardModel(capture: try capture(), operations: operations)
        let destination = root.appendingPathComponent("stale.png")
        let save = Task { await model.save(to: destination) }
        while !(await barrier.started) { await Task.yield() }
        #expect(model.isBusy)
        model.invalidate()
        await barrier.release()
        #expect(!(await save.value))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(model.savedURL == nil && !model.isBusy)
    }

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
    @Test("concurrent Quick Look and share requests coalesce the immutable PNG export")
    func coalescedExport() async throws {
        let manager = FileManager.default
        let fixture = try physicalTemporaryRoot().appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }
        let counter = CardEncodeCounter()
        var operations = ScreenshotCardModel.Operations()
        operations.exports = ScreenshotTemporaryExports(directory: fixture.appendingPathComponent("exports"))
        operations.encode = { capture in
            await counter.record()
            try await Task.sleep(for: .milliseconds(40))
            return try EditorRendered(image: capture.image, pointSize: capture.pointSize).png
        }
        let shot = try capture(), model = ScreenshotCardModel(capture: shot, operations: operations)
        let provider = model.dragProvider()
        let quickLook = Task { @MainActor in try await model.exportedFileURL() }
        let share = Task { @MainActor in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.png.identifier) { url, error in
                if let error { continuation.resume(throwing: error); return }
                guard let url else { continuation.resume(throwing: CocoaError(.fileReadUnknown)); return }
                do { continuation.resume(returning: try Data(contentsOf: url)) }
                catch { continuation.resume(throwing: error) }
            }
            }
        }
        let url = try await quickLook.value, bytes = try await share.value
        #expect(bytes == (try Data(contentsOf: url)))
        #expect(bytes == (try EditorRendered(image: shot.image, pointSize: shot.pointSize).png))
        #expect(await counter.count == 1)
        #expect(try await model.exportedFileURL() == url)
        #expect(await counter.count == 1)
    }
    @Test("failed immutable export can retry; a stale model completion cannot publish its URL")
    func failedExportRetry() async throws {
        let manager = FileManager.default
        let fixture = try physicalTemporaryRoot().appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }
        let counter = CardEncodeCounter()
        var operations = ScreenshotCardModel.Operations()
        operations.exports = ScreenshotTemporaryExports(directory: fixture.appendingPathComponent("exports"))
        operations.encode = { capture in
            if await counter.record() == 1 { throw CocoaError(.fileWriteUnknown) }
            try await Task.sleep(for: .milliseconds(30))
            return try EditorRendered(image: capture.image, pointSize: capture.pointSize).png
        }
        let model = ScreenshotCardModel(capture: try capture(), operations: operations)
        await #expect(throws: CocoaError.self) { try await model.exportedFileURL() }
        let request = Task { try await model.exportedFileURL() }
        while await counter.count < 2 { await Task.yield() }
        model.invalidate()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(model.preparedExportURL == nil)
        let acceptedExport = try await model.export.fileURL()
        #expect(operations.exports.owns(acceptedExport))
        #expect(await counter.count == 2)
    }
    @Test("native accepted file promise writes the frozen PNG after the source card is invalidated")
    func nativeFilePromise() async throws {
        let manager = FileManager.default
        let fixture = try physicalTemporaryRoot().appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }
        var operations = ScreenshotCardModel.Operations()
        operations.exports = ScreenshotTemporaryExports(directory: fixture.appendingPathComponent("exports"))
        let shot = try capture(), model = ScreenshotCardModel(capture: shot, operations: operations)
        let delegate = ScreenshotCardPromiseDelegate(export: model.export)
        let provider = ScreenshotCardPromiseWriter(fileType: UTType.png.identifier, delegate: delegate)
        provider.userInfo = delegate
        model.invalidate()
        let destination = fixture.appendingPathComponent("accepted.png")
        let error: Error? = await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(provider, writePromiseTo: destination) { continuation.resume(returning: $0) }
        }
        #expect(error == nil)
        #expect(try Data(contentsOf: destination) == (try EditorRendered(image: shot.image, pointSize: shot.pointSize).png))
        let existing = try Data(contentsOf: destination)
        let conflict: Error? = await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(provider, writePromiseTo: destination) { continuation.resume(returning: $0) }
        }
        #expect(conflict != nil)
        #expect(try Data(contentsOf: destination) == existing)
    }
    @Test("native promise writer preserves prepared PNG and URL payload through its actual constructor")
    func nativePreparedPromiseWriter() async throws {
        let manager = FileManager.default
        let fixture = try physicalTemporaryRoot().appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }
        var operations = ScreenshotCardModel.Operations()
        operations.exports = ScreenshotTemporaryExports(directory: fixture.appendingPathComponent("exports"))
        let shot = try capture(), model = ScreenshotCardModel(capture: shot, operations: operations)
        let url = try await model.exportedFileURL()
        let png = try #require(model.preparedExportPNG)
        let delegate = ScreenshotCardPromiseDelegate(export: model.export)
        let writer = ScreenshotCardPromiseWriter(fileType: UTType.png.identifier, delegate: delegate, preparedURL: url, preparedPNG: png)
        writer.userInfo = delegate
        let board = NSPasteboard(name: .init("camcord.promise-writer." + UUID().uuidString))
        defer { board.releaseGlobally() }
        #expect(writer.fileType == UTType.png.identifier)
        #expect(writer.delegate === delegate)
        let types = writer.writableTypes(for: board)
        #expect(types.contains(.png))
        #expect(types.contains(.fileURL))
        let base = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: delegate)
        #expect(Set(base.writableTypes(for: board)).isSubset(of: Set(types)))
        #expect(writer.pasteboardPropertyList(forType: .png) as? Data == png)
        #expect(writer.pasteboardPropertyList(forType: .fileURL) as? String == url.absoluteString)
        board.clearContents()
        #expect(board.writeObjects([writer]))
        #expect(board.data(forType: .png) == png)
        #expect(board.string(forType: .fileURL) == url.absoluteString)
        model.invalidate()
        let destination = fixture.appendingPathComponent("native-prepared.png")
        let error: Error? = await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(writer, writePromiseTo: destination) { continuation.resume(returning: $0) }
        }
        #expect(error == nil)
        #expect(try Data(contentsOf: destination) == png)
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

private actor CardEncodeCounter {
    private(set) var count = 0
    @discardableResult func record() -> Int { count += 1; return count }
}

private actor CardSaveEncodingBarrier {
    private(set) var started = false
    private var continuation: CheckedContinuation<Data, Never>?
    func encode() async -> Data {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: Data([1, 2, 3])); continuation = nil }
}
