import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Camcord

private struct LibraryFixture {
    let root: URL
    let saved: URL
    let cache: URL
    let defaults: UserDefaults
    let suite: String
    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: try #require(LibraryFiles.physicalPath(directory)))
        saved = root.appendingPathComponent("saved", isDirectory: true)
        cache = root.appendingPathComponent("cache", isDirectory: true)
        suite = "library-fixture-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    func image(width: Int = 8, height: Int = 4, red: UInt8 = 220) throws -> CGImage {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: data.count, by: 4) { data[index] = red; data[index + 2] = 255 - red; data[index + 3] = 255 }
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    func png(_ name: String, in directory: URL? = nil, red: UInt8 = 220) throws -> URL {
        let url = (directory ?? saved).appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(red: red), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
    @MainActor func store(operations: LibraryDisk.Operations = .init()) -> LibraryStore {
        LibraryStore(defaults: defaults, roots: [.init(url: saved, origin: .savedFile)], cacheDirectory: cache, operations: operations)
    }
}

@Suite("Library actual file paths", .timeLimit(.minutes(1))) @MainActor
struct LibraryStoreTests {
    @Test("scan deduplicates path spelling and excludes nested, symlink, foreign cache children")
    func scanBoundary() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let saved = try f.png("capture.png")
        let owned = try f.png(UUID().uuidString + ".png", in: f.cache)
        _ = try f.png("foreign.png", in: f.cache)
        let nested = f.saved.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try f.png("nested.png", in: nested)
        try FileManager.default.createSymbolicLink(at: f.saved.appendingPathComponent("link.png"), withDestinationURL: saved)
        let store = LibraryStore(defaults: f.defaults, roots: [.init(url: f.saved, origin: .savedFile),
            .init(url: URL(fileURLWithPath: f.saved.path), origin: .savedFile)], cacheDirectory: f.cache)
        await store.refresh()
        #expect(Set(store.items.map(\.url.path)) == Set([saved.path, owned.path]))
        #expect(store.items.count == 2)
        #expect(store.roots.count == 2)
    }
    @Test("cache writes PNG pixels, DPI and scroll tag once, retains UUID during rename")
    func cacheAndRename() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let disk = LibraryDisk()
        let id = UUID(), now = Date()
        let url = try await disk.cache(id: id, image: f.image(), pointSize: CGSize(width: 4, height: 2), kind: .scrollCapture,
            directory: f.cache, settings: LibrarySettings(), now: now)
        let before = try Data(contentsOf: url)
        _ = try await disk.cache(id: id, image: f.image(red: 0), pointSize: CGSize(width: 4, height: 2), kind: .scrollCapture,
            directory: f.cache, settings: LibrarySettings(), now: now)
        #expect(try Data(contentsOf: url) == before)
        #expect(CaptureFileRules.readTag(url) == CaptureFileRules.scrollCaptureTag)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let dpi = try #require(properties[kCGImagePropertyDPIWidth] as? Double)
        #expect(abs(dpi - 144) < 1)
        let store = f.store(); await store.refresh()
        let item = try #require(store.items.first); store.selection = [item.id]
        try await store.rename(item.id, to: "A useful title")
        #expect(store.items.first?.displayName == "A useful title")
        #expect(store.items.first?.url == url)
        #expect(store.selection == [item.id])
        #expect(try Data(contentsOf: url) == before)
    }
    @Test("rename refuses traversal/overwrite and reconciles selected saved-path identity")
    func savedRename() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let source = try f.png("before.png"), existing = try f.png("already.png", red: 0)
        let bytes = try Data(contentsOf: existing)
        let store = f.store(); await store.refresh()
        let item = try #require(store.items.first(where: { $0.url.path == source.path }))
        await #expect(throws: LibraryFiles.Failure.self) { try await store.rename(item.id, to: "../escape") }
        await #expect(throws: LibraryFiles.Failure.self) { try await store.rename(item.id, to: "already") }
        #expect(try Data(contentsOf: existing) == bytes)
        store.selection = [item.id]
        try await store.rename(item.id, to: "after")
        let next = try #require(store.items.first(where: { $0.title == "after" }))
        #expect(next.id != item.id)
        #expect(store.selection == [next.id])
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }
    @Test("injected Trash failure surfaces error and preserves the selected source")
    func trashFailure() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let source = try f.png("safe.png")
        var operations = LibraryDisk.Operations()
        operations.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
        let store = f.store(operations: operations); await store.refresh()
        let item = try #require(store.items.first)
        await #expect(throws: LibraryStore.ActionFailure.self) { try await store.delete([item.id]) }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(store.items.count == 1)
    }
    @Test("replacement symlink is refused at explicit mutation time")
    func changedFileSafety() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let source = try f.png("selected.png"), outside = try f.png("outside.png", in: f.root)
        let store = f.store(); await store.refresh(); let item = try #require(store.items.first)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        await #expect(throws: LibraryFiles.Failure.self) { try await store.rename(item.id, to: "stolen") }
        await #expect(throws: LibraryStore.ActionFailure.self) { try await store.delete([item.id]) }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
    @Test("retention removes owned old PNG only, never foreign/saved/symlink files")
    func safeRetention() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let now = Date(), old = try f.png(UUID().uuidString + ".png", in: f.cache)
        let fresh = try f.png(UUID().uuidString + ".png", in: f.cache)
        let foreign = try f.png("foreign.png", in: f.cache), saved = try f.png(UUID().uuidString + ".png")
        let symlink = f.cache.appendingPathComponent(UUID().uuidString + ".png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: saved)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-31 * 86400)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-40 * 86400)], ofItemAtPath: foreign.path)
        try await LibraryDisk().retain(directory: f.cache, settings: LibrarySettings(), now: now)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        for url in [fresh, foreign, saved, symlink] { #expect(FileManager.default.fileExists(atPath: url.path)) }
        let linkedRoot = f.root.appendingPathComponent("cache-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: f.cache)
        try FileManager.default.createDirectory(at: f.cache.appendingPathComponent("existing-child"), withIntermediateDirectories: true)
        await #expect(throws: LibraryFiles.Failure.self) {
            try await LibraryDisk().retain(directory: linkedRoot.appendingPathComponent("existing-child"), settings: LibrarySettings(), now: now)
        }
        await #expect(throws: LibraryFiles.Failure.self) { try await LibraryDisk().retain(directory: linkedRoot, settings: LibrarySettings(), now: now) }
        await #expect(throws: LibraryFiles.Failure.self) {
            _ = try await LibraryDisk().cache(id: UUID(), image: f.image(), pointSize: CGSize(width: 8, height: 4),
                kind: .screenshot, directory: linkedRoot.appendingPathComponent("child"), settings: LibrarySettings(), now: now)
        }
        #expect(!FileManager.default.fileExists(atPath: f.cache.appendingPathComponent("child").path))
    }
    @Test("damaged files remain honest metadata entries and bounded thumbnails fail safely")
    func damagedAndThumbnails() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let damaged = f.saved.appendingPathComponent("damaged.png")
        try Data("invalid PNG".utf8).write(to: damaged)
        let valid = try f.png("valid.png")
        let store = f.store(); await store.refresh()
        #expect(store.items.count == 2)
        let bad = try #require(store.items.first(where: { $0.url.path == damaged.path }))
        let good = try #require(store.items.first(where: { $0.url.path == valid.path }))
        #expect(bad.pixelSize == nil)
        #expect(await store.thumbnails.image(for: bad) == nil)
        let bounded = LibraryThumbnails(byteLimit: 10, countLimit: 1)
        #expect(await bounded.image(for: good) != nil)
        #expect(await bounded.cachedCount == 0)
        #expect(await bounded.cachedBytes == 0)
        let cache = LibraryThumbnails(byteLimit: 4096, countLimit: 1)
        #expect(await cache.image(for: good) != nil)
        #expect(await cache.cachedCount == 1)
        #expect(await cache.cachedBytes <= 4096)
    }
    @Test("copied image uses private pasteboard and never mutates the source")
    func privateCopy() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let source = try f.png("copy.png"), bytes = try Data(contentsOf: source)
        let store = f.store(); await store.refresh(); store.selection = Set(store.items.map(\.id))
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        await store.copySelection(to: pasteboard)
        #expect(pasteboard.data(forType: .png) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
    }
    @Test("unconnected editor never claims to open and validates drops")
    func honestEditor() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let image = try f.png("edit.png")
        let store = f.store(); await store.refresh(); await store.openDroppedImage(image)
        #expect(store.issue != nil)
        store.issue = nil
        var opened = [URL]()
        store.onOpenScreenshot = { opened.append($0) }
        await store.openDroppedImage(image)
        #expect(opened == [image]); #expect(store.issue == nil)
        let damaged = f.saved.appendingPathComponent("bad.png"); try Data("no".utf8).write(to: damaged)
        await store.openDroppedImage(damaged)
        #expect(opened == [image]); #expect(store.issue != nil)
    }
    @Test("watch subscriptions exist only while visibility tokens are held")
    func watchers() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let store = f.store(); #expect(store.watcherCount == 0)
        let first = store.acquireVisibility(), second = store.acquireVisibility()
        #expect(store.watcherCount == 2)
        store.releaseVisibility(first); #expect(store.watcherCount == 2)
        store.releaseVisibility(second); #expect(store.watcherCount == 0)
    }
    @Test("late scan cannot replace the latest snapshot")
    func lateScan() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let a = try f.png("a.png"), b = try f.png("b.png")
        let snapshot = try await LibraryFiles.scan([.init(url: f.saved, origin: .savedFile)])
        let gate = ScanGate(first: snapshot.filter { $0.url.path == a.path }, second: snapshot.filter { $0.url.path == b.path })
        let store = LibraryStore(defaults: f.defaults, roots: [], cacheDirectory: f.cache, scanner: { _ in await gate.scan() })
        let first = Task { await store.refresh() }
        await gate.waitForFirst()
        await store.refresh()
        await gate.release()
        await first.value
        #expect(store.items.map(\.url.path) == [b.path])
        #expect(!store.isLoading)
    }
    @Test("saved-before-ready and failed-before-ready delivery persist exactly one correct origin")
    func captureOrdering() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let store = f.store(), image = try f.image()
        let first = CapturedScreenshot(id: UUID(), image: image, pointSize: CGSize(width: 4, height: 2), kind: .screenshot, saveToDiskRequested: true)
        let saved = try f.png("saved-capture.png")
        store.ingest(.saved(first, saved)); store.ingest(.ready(first))
        await store.waitForPendingCacheWrites(); await store.refresh()
        #expect(store.items.count == 1)
        #expect(store.items.first?.origin == .savedFile)
        #expect(try LibraryFiles.ownedCacheFiles(in: f.cache).isEmpty)
        let second = CapturedScreenshot(id: UUID(), image: image, pointSize: CGSize(width: 4, height: 2), kind: .scrollCapture, saveToDiskRequested: true)
        store.ingest(.saveFailed(second)); store.ingest(.ready(second)); store.ingest(.ready(second))
        await store.waitForPendingCacheWrites(); await store.refresh()
        #expect(store.items.count == 2)
        #expect(try LibraryFiles.ownedCacheFiles(in: f.cache).count == 1)
        #expect(store.items.first(where: { $0.origin == .clipboardCache })?.kind == .scrollCapture)
        #expect(store.issue != nil)
    }
    @Test("ready event for a requested disk save does not create a duplicate cache while saving")
    func pendingDiskSave() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let store = f.store()
        let capture = CapturedScreenshot(id: UUID(), image: try f.image(), pointSize: CGSize(width: 8, height: 4), kind: .screenshot, saveToDiskRequested: true)
        store.ingest(.ready(capture))
        await store.waitForPendingCacheWrites()
        #expect(try LibraryFiles.ownedCacheFiles(in: f.cache).isEmpty)
        let saved = try f.png("delivered.png")
        store.ingest(.saved(capture, saved)); await store.refresh()
        #expect(store.items.count == 1)
        #expect(store.items.first?.origin == .savedFile)
    }
    @Test("capture cache backpressure is bounded and keeps clipboard success independent")
    func cacheBackpressure() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let store = f.store(), image = try f.image()
        for _ in 0..<5 {
            store.ingest(.ready(CapturedScreenshot(id: UUID(), image: image, pointSize: CGSize(width: 8, height: 4), kind: .screenshot, saveToDiskRequested: false)))
        }
        #expect(store.pendingCacheWriteCount == 4)
        #expect(store.issue != nil)
        await store.waitForPendingCacheWrites(); await store.refresh()
        #expect(try LibraryFiles.ownedCacheFiles(in: f.cache).count == 4)
    }
    @Test("unrelated defaults updates do not scan, configured destination updates do")
    func defaultsFiltering() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        ScreenshotSettings(saveDirectoryPath: f.saved.path).save(to: f.defaults)
        RecordingSettings(outputDirectoryPath: f.saved.path).save(to: f.defaults)
        let counter = ScanCounter()
        let store = LibraryStore(defaults: f.defaults, cacheDirectory: f.cache, scanner: { roots in await counter.scan(roots) })
        await store.refresh()
        #expect(await counter.count == 1)
        f.defaults.set(0.25, forKey: "unrelated.gain")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: f.defaults)
        try await Task.sleep(for: .milliseconds(250))
        #expect(await counter.count == 1)
        let next = f.root.appendingPathComponent("next")
        ScreenshotSettings(saveDirectoryPath: next.path).save(to: f.defaults)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: f.defaults)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let scans = await counter.count
            let destinationScanned = await counter.paths.contains(next.path)
            if scans >= 2, destinationScanned { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await counter.count == 2)
        #expect(await counter.paths.contains(next.path))
    }
    @Test("large recordings still receive duration metadata without reading the full file")
    func largeRecordingMetadata() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let movie = f.saved.appendingPathComponent("long.mov")
        try Data("fixture".utf8).write(to: movie)
        let items = try await LibraryFiles.scan([.init(url: f.saved, origin: .savedFile)],
            fileSize: { _ in 3 << 30 }, recordingDuration: { _ in 600 })
        #expect(items.count == 1)
        #expect(items.first?.byteSize == 3 << 30)
        #expect(items.first?.duration == 600)
    }
    @Test("failed scan remains distinct from empty after dismissing its action alert")
    func loadFailureState() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let store = LibraryStore(defaults: f.defaults, roots: [], cacheDirectory: f.cache,
            scanner: { _ in throw CocoaError(.fileReadNoPermission) })
        await store.refresh()
        #expect(store.loadingIssue != nil); #expect(!store.isLoading); #expect(store.items.isEmpty)
        store.issue = nil
        #expect(store.loadingIssue != nil)
    }
    @Test("cache cap evicts oldest owned bytes and damaged owned artifacts safely")
    func actualCacheCap() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let old = try f.png(UUID().uuidString + ".png", in: f.cache)
        let fresh = try f.png(UUID().uuidString + ".png", in: f.cache)
        let damaged = f.cache.appendingPathComponent(UUID().uuidString + ".png")
        try Data("damaged".utf8).write(to: damaged)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-40 * 86400)], ofItemAtPath: damaged.path)
        var settings = LibrarySettings(); settings.capBytes = try LibraryFiles.byteSize(fresh)
        try await LibraryDisk().retain(directory: f.cache, settings: settings, now: now)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: damaged.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }
    @Test("thumbnail revision replacement invalidates pixels and cancelled requests don't publish")
    func thumbnailRevision() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        let url = try f.png("revision.png")
        let store = f.store(); await store.refresh()
        let item = try #require(store.items.first)
        let old = try #require(await store.thumbnails.image(for: item))
        _ = try f.png("revision.png", red: 0)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: url.path)
        await store.refresh()
        let revision = try #require(store.items.first)
        let fresh = try #require(await store.thumbnails.image(for: revision))
        #expect(old.dataProvider?.data != fresh.dataProvider?.data)
        #expect(await store.thumbnails.cachedCount == 1)
        let cancelled = Task { await store.thumbnails.image(for: revision) }
        cancelled.cancel()
        #expect(await cancelled.value == nil)
    }
    @Test("same-key permit waiters share one bounded decoder request")
    func sameKeyWaiters() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        for number in 0..<5 { _ = try f.png("queued-\(number).png") }
        let items = try await LibraryFiles.scan([.init(url: f.saved, origin: .savedFile)])
        let gate = ThumbnailGate(image: try f.image())
        let thumbnails = LibraryThumbnails(decoder: { item, _ in await gate.decode(item.url) })
        let primed = Array(items.prefix(4))
        let tasks = primed.map { item in Task { await thumbnails.image(for: item) } }
        await gate.waitForCount(4)
        let fifth = items[4]
        let one = Task { await thumbnails.image(for: fifth) }, two = Task { await thumbnails.image(for: fifth) }
        while await thumbnails.waitingRequestCount < 2 { await Task.yield() }
        await gate.release(primed[0].url); await gate.release(primed[1].url)
        await gate.waitForCount(5)
        await gate.openAll()
        for task in tasks { #expect(await task.value != nil) }
        #expect(await one.value != nil); #expect(await two.value != nil)
        #expect(await gate.requests(for: fifth.url) == 1)
        #expect(await gate.count == 5)
    }
    @Test("hidden-cache cancellation rejects a late noncooperative decoder result")
    func cancelledDecoder() async throws {
        let f = try LibraryFixture(); defer { f.cleanup() }
        _ = try f.png("late-thumbnail.png")
        let items = try await LibraryFiles.scan([.init(url: f.saved, origin: .savedFile)])
        let item = try #require(items.first), gate = ThumbnailGate(image: try f.image())
        let thumbnails = LibraryThumbnails(decoder: { item, _ in await gate.decode(item.url) })
        let request = Task { await thumbnails.image(for: item) }
        await gate.waitForCount(1)
        await thumbnails.removeAll()
        await gate.openAll()
        #expect(await request.value == nil)
        #expect(await thumbnails.cachedCount == 0)
        #expect(await thumbnails.cachedBytes == 0)
    }
    @Test("retention checked arithmetic rejects overflow and handles negative input")
    func retentionArithmetic() {
        let now = Date()
        let entries = [CacheRetention.Entry(id: "first", createdAt: now, byteSize: .max),
                       CacheRetention.Entry(id: "second", createdAt: now.addingTimeInterval(-1), byteSize: 1)]
        #expect(CacheRetention.expired(entries, now: now, keepDays: Int.max, capBytes: .max) == ["second"])
        #expect(CacheRetention.expired(entries, now: now, keepDays: 30, capBytes: -1).count == 2)
    }
}

private actor ScanGate {
    let first: [CaptureItem], second: [CaptureItem]
    var count = 0
    var continuation: CheckedContinuation<Void, Never>?
    init(first: [CaptureItem], second: [CaptureItem]) { self.first = first; self.second = second }
    func scan() async -> [CaptureItem] {
        count += 1
        if count == 1 { await withCheckedContinuation { continuation = $0 }; return first }
        return second
    }
    func waitForFirst() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor ScanCounter {
    var count = 0
    var paths = [String]()
    func scan(_ roots: [LibraryFiles.Root]) -> [CaptureItem] { count += 1; paths = roots.map(\.url.path); return [] }
}

private actor ThumbnailGate {
    let image: CGImage
    var count = 0
    var counts = [URL: Int]()
    var continuations = [URL: [CheckedContinuation<Void, Never>]]()
    var isOpen = false
    init(image: CGImage) { self.image = image }
    func decode(_ url: URL) async -> CGImage? {
        count += 1; counts[url, default: 0] += 1
        if !isOpen { await withCheckedContinuation { continuations[url, default: []].append($0) } }
        return image
    }
    func requests(for url: URL) -> Int { counts[url, default: 0] }
    func waitForCount(_ target: Int) async { while count < target { await Task.yield() } }
    func release(_ url: URL) { for continuation in continuations.removeValue(forKey: url) ?? [] { continuation.resume() } }
    func openAll() { isOpen = true; for url in Array(continuations.keys) { release(url) } }
}
