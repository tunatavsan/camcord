import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Disk boundaries shared by indexing, cache retention and explicit mutations.
/// Only immediate children are considered; a symlink at any ancestor is refused.
enum LibraryFiles {
    struct Root: Hashable, Sendable {
        let url: URL
        let origin: CaptureItem.Origin
    }
    enum Failure: LocalizedError {
        case unsafePath, invalidName, alreadyExists, writeFailed, unsupportedImage
        var errorDescription: String? {
            switch self {
            case .unsafePath: String(localized: "This file location is unsafe or no longer available.")
            case .invalidName: String(localized: "Use 1–120 characters without a leading period, slashes or control characters.")
            case .alreadyExists: String(localized: "A file with that name already exists.")
            case .writeFailed: String(localized: "Couldn't keep this capture in the Library. The clipboard copy is still available.")
            case .unsupportedImage: String(localized: "This image is damaged or exceeds the supported size.")
            }
        }
    }
    static let nameAttribute = "dev.tavsan.camcord.name"
    static let maxSourceBytes: Int64 = 1 << 30
    static let maxPixels = 100_000_000
    static let maxFullImagePixels = 50_000_000

    static func physicalPath(_ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
    static func validateDirectory(_ url: URL) throws {
        let path = URL(fileURLWithPath: url.path)
        let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              path.path == physicalPath(path) else { throw Failure.unsafePath }
    }
    static func regularFile(_ url: URL, in root: URL) throws -> Bool {
        try validateDirectory(root)
        guard url.standardizedFileURL.deletingLastPathComponent().path == root.standardizedFileURL.path else { return false }
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
    static func isOwnedCacheFile(_ url: URL, in root: URL) throws -> Bool {
        guard url.pathExtension.lowercased() == "png",
              UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { return false }
        return try regularFile(url, in: root)
    }
    static func ownedCacheFiles(in root: URL) throws -> [URL] {
        do {
            try validateDirectory(root)
            return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]).filter { try isOwnedCacheFile($0, in: root) }
        } catch CocoaError.fileReadNoSuchFile { return [] }
    }
    static func readName(_ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            let size = getxattr(path, nameAttribute, nil, 0, 0, 0)
            guard size > 0, size <= 480 else { return nil }
            var data = [UInt8](repeating: 0, count: size)
            guard getxattr(path, nameAttribute, &data, size, 0, 0) == size,
                  let name = String(bytes: data, encoding: .utf8), validName(name) else { return nil }
            return name
        }
    }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 120 && name.utf8.count <= 480 && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func writeName(_ name: String, to url: URL) throws {
        guard validName(name) else { throw Failure.invalidName }
        let bytes = Array(name.utf8)
        let success = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return setxattr(path, nameAttribute, bytes, bytes.count, 0, 0) == 0
        }
        guard success else { throw CocoaError(.fileWriteUnknown) }
    }
    static func byteSize(_ url: URL) throws -> Int64 {
        Int64(try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    static func imageSize(_ url: URL, pixelLimit: Int = maxPixels) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= pixelLimit / height else { return nil }
        return CGSize(width: width, height: height)
    }
    static func duration(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(2)); asset.cancelLoading() } catch { }
        }
        defer { deadline.cancel() }
        let time = await withTaskCancellationHandler { try? await asset.load(.duration) } onCancel: { asset.cancelLoading() }
        guard let time, !Task.isCancelled, time.seconds.isFinite, time.seconds >= 0 else { return nil }
        return time.seconds
    }
    static func scan(_ roots: [Root],
                     fileSize: @Sendable (URL) throws -> Int64 = byteSize,
                     recordingDuration: @Sendable (URL) async -> Double? = duration) async throws -> [CaptureItem] {
        var result = [CaptureItem]()
        var seen = Set<String>()
        for root in roots {
            try Task.checkCancellation()
            do { try validateDirectory(root.url) } catch CocoaError.fileReadNoSuchFile { continue }
            let files = try FileManager.default.contentsOfDirectory(at: root.url,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
            for url in files {
                try Task.checkCancellation()
                do {
                guard !seen.contains(url.standardizedFileURL.path),
                      try regularFile(url, in: root.url),
                      (try (root.origin != .clipboardCache || isOwnedCacheFile(url, in: root.url))),
                      let kind = CaptureFileRules.kind(of: url, tag: CaptureFileRules.readTag(url)) else { continue }
                seen.insert(url.standardizedFileURL.path)
                let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
                let bytes = try fileSize(url)
                var duration: Double?
                if kind == .recording, bytes > 0 { duration = await recordingDuration(url) }
                result.append(CaptureItem(id: CaptureFileRules.id(for: url, origin: root.origin), url: url,
                    kind: kind, origin: root.origin, createdAt: values.contentModificationDate ?? values.creationDate ?? .distantPast,
                    byteSize: bytes, pixelSize: kind != .recording && bytes <= maxSourceBytes ? imageSize(url) : nil,
                    duration: duration, displayName: root.origin == .clipboardCache ? readName(url) : nil))
                } catch CocoaError.fileReadNoSuchFile { continue }
            }
        }
        return result.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
    }
}

/// Serializes cache writes/retention and user mutations. The main actor never decodes or scans.
actor LibraryDisk {
    struct Operations: Sendable {
        var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        var move: @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
        var remove: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    }
    let operations: Operations
    init(operations: Operations = Operations()) { self.operations = operations }

    func cache(id: UUID, image: CGImage, pointSize: CGSize, kind: CaptureItem.Kind, directory: URL,
               settings: LibrarySettings, now: Date) throws -> URL {
        // Check existing ancestors before creating anything, including a missing cache root.
        var ancestor = directory
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let next = ancestor.deletingLastPathComponent()
            guard next != ancestor else { throw LibraryFiles.Failure.unsafePath }
            ancestor = next
        }
        try LibraryFiles.validateDirectory(ancestor)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try LibraryFiles.validateDirectory(directory)
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0, image.width <= LibraryFiles.maxFullImagePixels / image.height else {
            throw LibraryFiles.Failure.unsupportedImage
        }
        let url = directory.appendingPathComponent(id.uuidString + ".png")
        if FileManager.default.fileExists(atPath: url.path) {
            guard try LibraryFiles.isOwnedCacheFile(url, in: directory) else { throw LibraryFiles.Failure.unsafePath }
            return url
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw LibraryFiles.Failure.writeFailed
        }
        let dpiX = pointSize.width > 0 && pointSize.width.isFinite ? Double(image.width) / pointSize.width * 72 : 72
        let dpiY = pointSize.height > 0 && pointSize.height.isFinite ? Double(image.height) / pointSize.height * 72 : 72
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpiX, kCGImagePropertyDPIHeight: dpiY] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LibraryFiles.Failure.writeFailed }
        let temporary = directory.appendingPathComponent(".capture-" + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try (data as Data).write(to: temporary, options: [.withoutOverwriting])
        if kind == .scrollCapture, !CaptureFileRules.tagScrollCapture(temporary) { throw LibraryFiles.Failure.writeFailed }
        try Task.checkCancellation()
        try LibraryFiles.validateDirectory(directory)
        try FileManager.default.moveItem(at: temporary, to: url)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        try retain(directory: directory, settings: settings, now: now)
        return url
    }
    func retain(directory: URL, settings: LibrarySettings, now: Date) throws {
        let urls = try LibraryFiles.ownedCacheFiles(in: directory)
        let entries = try urls.map { url in
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return CacheRetention.Entry(id: url.lastPathComponent, createdAt: values.contentModificationDate ?? .distantPast,
                                        byteSize: Int64(values.fileSize ?? 0))
        }
        let expired = Set(CacheRetention.expired(entries, now: now, keepDays: settings.keepDays, capBytes: settings.capBytes))
        for url in urls where expired.contains(url.lastPathComponent) {
            try Task.checkCancellation()
            guard try LibraryFiles.isOwnedCacheFile(url, in: directory) else { continue }
            try operations.remove(url)
        }
    }
    func delete(_ item: CaptureItem, roots: [LibraryFiles.Root]) throws {
        try validate(item, roots: roots)
        try operations.trash(item.url)
    }
    func rename(_ item: CaptureItem, name: String, roots: [LibraryFiles.Root]) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LibraryFiles.validName(trimmed) else { throw LibraryFiles.Failure.invalidName }
        try validate(item, roots: roots)
        if item.origin == .clipboardCache {
            try LibraryFiles.writeName(trimmed, to: item.url)
            return item.url
        }
        let suffix = "." + item.url.pathExtension
        let stem = trimmed.hasSuffix(suffix) ? String(trimmed.dropLast(suffix.count)) : trimmed
        guard LibraryFiles.validName(stem) else { throw LibraryFiles.Failure.invalidName }
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(stem + suffix)
        if destination == item.url { return item.url }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw LibraryFiles.Failure.alreadyExists }
        try operations.move(item.url, destination)
        return destination
    }
    private func validate(_ item: CaptureItem, roots: [LibraryFiles.Root]) throws {
        guard let root = roots.first(where: { $0.origin == item.origin && $0.url.standardizedFileURL.path == item.url.standardizedFileURL.deletingLastPathComponent().path }),
              try LibraryFiles.regularFile(item.url, in: root.url),
              (try (item.origin != .clipboardCache || LibraryFiles.isOwnedCacheFile(item.url, in: root.url))) else {
            throw LibraryFiles.Failure.unsafePath
        }
    }
}
