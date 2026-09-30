import AVFoundation
import ImageIO

/// LRU bounded by decoded bytes and count. A shared revision key prevents stale thumbnails;
/// a request cancelled by a disappearing tile never publishes a result into that tile.
actor LibraryThumbnails {
    struct Key: Hashable, Sendable {
        let url: URL
        let bytes: Int64
        let modified: Date
        let edge: Int
    }
    private struct Entry { let image: CGImage; let cost: Int; var used: UInt64 }
    private var entries = [Key: Entry]()
    private struct Flight { let id: UUID; let task: Task<CGImage?, Never> }
    private var inFlight = [Key: Flight]()
    private var revision: UInt64 = 0
    private let decoder: @Sendable (CaptureItem, Int) async -> CGImage?
    private var tick: UInt64 = 0
    private var bytes = 0
    private var active = 0
    private var waiters = [CheckedContinuation<Void, Never>]()
    let byteLimit: Int
    let countLimit: Int
    init(byteLimit: Int = 32 << 20, countLimit: Int = 96,
         decoder: @escaping @Sendable (CaptureItem, Int) async -> CGImage? = LibraryThumbnails.decode) {
        self.decoder = decoder
        self.byteLimit = max(0, byteLimit); self.countLimit = max(0, countLimit)
    }
    var cachedCount: Int { entries.count }
    var waitingRequestCount: Int { waiters.count }
    var cachedBytes: Int { bytes }
    func image(for item: CaptureItem, edge: Int = 384) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let edge = min(max(edge, 32), 1024)
        let key = Key(url: item.url, bytes: item.byteSize, modified: item.createdAt, edge: edge)
        tick &+= 1
        if var entry = entries[key] { entry.used = tick; entries[key] = entry; return entry.image }
        if let flight = inFlight[key] { let result = await flight.task.value; return Task.isCancelled || flight.task.isCancelled ? nil : result }
        // Reject thumbnail work on unsupported or oversized input before native decoders see it.
        guard item.byteSize > 0, (item.kind == .recording || item.byteSize <= LibraryFiles.maxSourceBytes),
              item.kind == .recording || item.pixelSize != nil else { return nil }
        let requestedRevision = revision
        if active >= 4 && waiters.count >= 128 { return nil }
        if active >= 4 { await withCheckedContinuation { waiters.append($0) } } else { active += 1 }
        guard !Task.isCancelled, requestedRevision == revision else { releasePermit(); return nil }
        // Reentrancy: another waiter for this key may have filled the cache or started work.
        if var entry = entries[key] { releasePermit(); tick &+= 1; entry.used = tick; entries[key] = entry; return entry.image }
        if let flight = inFlight[key] {
            releasePermit()
            let result = await flight.task.value
            return Task.isCancelled || flight.task.isCancelled || requestedRevision != revision ? nil : result
        }
        let decoder = decoder
        let task = Task.detached(priority: .utility) { await decoder(item, edge) }
        let flightID = UUID()
        inFlight[key] = Flight(id: flightID, task: task)
        let result = await task.value
        if inFlight[key]?.id == flightID { inFlight.removeValue(forKey: key) }
        releasePermit()
        guard requestedRevision == revision, !task.isCancelled else { return nil }
        if let result {
            let (cost, overflow) = result.bytesPerRow.multipliedReportingOverflow(by: result.height)
            if !overflow, cost <= byteLimit, countLimit > 0 {
                // Remove an earlier revision for the same URL and thumbnail resolution.
                for old in Array(entries.keys) where old.url == key.url && old.edge == key.edge {
                    if let entry = entries.removeValue(forKey: old) { bytes -= entry.cost }
                }
                while entries.count >= countLimit || cost > byteLimit - bytes {
                    guard let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key,
                          let entry = entries.removeValue(forKey: oldest) else { break }
                    bytes -= entry.cost
                }
                tick &+= 1
                entries[key] = Entry(image: result, cost: cost, used: tick); bytes += cost
            }
        }
        return Task.isCancelled ? nil : result
    }
    private static func decode(_ item: CaptureItem, _ edge: Int) async -> CGImage? {
            guard (try? LibraryFiles.regularFile(item.url, in: item.url.deletingLastPathComponent())) == true,
                  !Task.isCancelled else { return nil }
            if item.kind == .recording {
                let request = MovieThumbnailRequest(url: item.url, edge: edge)
                let deadline = Task {
                    do { try await Task.sleep(for: .seconds(2)); request.cancel() } catch { }
                }
                defer { deadline.cancel() }
                let result = await withTaskCancellationHandler { await request.image() }
                    onCancel: { request.cancel() }
                return result
            }
            guard let bytes = try? LibraryFiles.byteSize(item.url),
                  bytes > 0, Int64(bytes) <= LibraryFiles.maxSourceBytes,
                  LibraryFiles.imageSize(item.url) != nil,
                  let source = CGImageSourceCreateWithURL(item.url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
            return Task.isCancelled ? nil : image
    }
    private func releasePermit() {
        if !waiters.isEmpty { waiters.removeFirst().resume() } else { active -= 1 }
    }
    func removeAll() {
        revision &+= 1
        for flight in inFlight.values { flight.task.cancel() }
        inFlight.removeAll()
        entries.removeAll(); bytes = 0
    }
}

/// AVAssetImageGenerator is mutable and therefore not Sendable. This boundary freezes all
/// configuration before publication, has exactly one image request, and exposes only native
/// cancellation to other tasks; no task can mutate its configuration or start a second request.
private final class MovieThumbnailRequest: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    init(url: URL, edge: Int) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: edge, height: edge)
    }
    func image() async -> CGImage? { (try? await generator.image(at: .zero))?.image }
    func cancel() { generator.cancelAllCGImageGeneration() }
}
