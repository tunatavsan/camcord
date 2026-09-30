import CryptoKit
import Foundation

// The Library's data model (docs/RUN-UI-2.md K4 — a seam: these types are plan-owned).

struct CaptureItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case screenshot, scrollCapture, recording }
    enum Origin: String, Codable, Sendable { case savedFile, clipboardCache }
    let id: String            // stable: file path hash (savedFile) or cache UUID
    let url: URL
    let kind: Kind
    let origin: Origin
    let createdAt: Date
    let byteSize: Int64
    let pixelSize: CGSize?    // images
    let duration: Double?     // recordings
    var displayName: String? = nil

    var title: String { displayName ?? url.deletingPathExtension().lastPathComponent }
}

@MainActor protocol CaptureLibraryStore: AnyObject, Observable {
    var items: [CaptureItem] { get }       // newest first
    func refresh() async
    func delete(_ ids: Set<String>) async throws   // to the Trash, never unlink
    func rename(_ id: String, to name: String) async throws
}

/// How a file on disk becomes a `CaptureItem` (SPEC §6): the kind from the extension and
/// Camcord's own tag, the id from the path or the cache file's UUID.
enum CaptureFileRules {
    /// The extended attribute Camcord writes on every scroll-capture PNG it saves or caches.
    static let kindAttribute = "dev.tavsan.camcord.kind"
    static let scrollCaptureTag = "scrollCapture"

    static let recordingExtensions: Set<String> = CaptureLibrary.recordingExtensions
    static let imageExtensions: Set<String> = CaptureLibrary.screenshotExtensions

    /// The kind of a file, or nil when it is not a capture.
    static func kind(of url: URL, tag: String?) -> CaptureItem.Kind? {
        let ext = url.pathExtension.lowercased()
        if recordingExtensions.contains(ext) { return .recording }
        guard imageExtensions.contains(ext) else { return nil }
        return tag == scrollCaptureTag ? .scrollCapture : .screenshot
    }

    /// A saved file's id: the first 16 bytes of the SHA-256 of its standardized path, in hex.
    /// A cache file's id: its UUID stem.
    static func id(for url: URL, origin: CaptureItem.Origin) -> String {
        switch origin {
        case .clipboardCache:
            return url.deletingPathExtension().lastPathComponent
        case .savedFile:
            let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Reads Camcord's kind tag from a file (nil when absent).
    static func readTag(_ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, kindAttribute, nil, 0, 0, 0)
            guard size > 0, size <= 64 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            let read = getxattr(path, kindAttribute, &buffer, size, 0, 0)
            guard read == size else { return nil }
            return String(decoding: buffer, as: UTF8.self)
        }
    }

    /// Tags a file as a scroll capture. Best effort: a volume without extended attributes
    /// leaves the file a plain screenshot in the Library.
    @discardableResult
    static func tagScrollCapture(_ url: URL) -> Bool {
        let value = Array(scrollCaptureTag.utf8)
        return url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return setxattr(path, kindAttribute, value, value.count, 0, 0) == 0
        }
    }
}

/// Which copied captures the cache keeps (K4): nothing older than `keepDays`, and within
/// `capBytes`, dropping the oldest first. Pure, so every edge is testable.
enum CacheRetention {
    struct Entry: Equatable, Sendable {
        let id: String
        let createdAt: Date
        let byteSize: Int64
    }

    /// The ids to remove, oldest first.
    static func expired(_ entries: [Entry], now: Date, keepDays: Int, capBytes: Int64) -> [String] {
        let cutoff = now.addingTimeInterval(-Double(min(max(keepDays, 0), 3650)) * 86_400)
        let cap = max(capBytes, 0)
        let newestFirst = entries.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
        var kept: Int64 = 0
        var removed: [Entry] = []
        for entry in newestFirst {
            let bytes = max(entry.byteSize, 0)
            let (sum, overflow) = kept.addingReportingOverflow(bytes)
            if entry.createdAt < cutoff || overflow || sum > cap {
                removed.append(entry)
            } else {
                kept = sum
            }
        }
        return removed.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }.map(\.id)
    }
}
