import Foundation
import Darwin

/// Only the private instance directory and explicitly recorded files are owned.
final class EditorTemporaryExports: @unchecked Sendable {
    let directory: URL
    private let rootPath: String
    private let lock = NSLock()
    private var owned: [URL] = []
    private let maximumFiles: Int
    private let maximumBytes: Int
    /// Explicit roots preserve their spelling so a symlink ancestor cannot disappear in normalization.
    init(root: URL? = nil, maximumFiles: Int = 12, maximumBytes: Int = 256_000_000) {
        self.maximumFiles = min(12, max(1, maximumFiles)); self.maximumBytes = min(256_000_000, max(1, maximumBytes))
        let original = root?.path ?? FileManager.default.temporaryDirectory.path
        let selected = root == nil ? (Self.physicalPath(original) ?? original) : original
        rootPath = selected.hasSuffix("/") && selected != "/" ? String(selected.dropLast()) : selected
        directory = URL(fileURLWithPath: rootPath, isDirectory: true).appendingPathComponent("camcord-edited-\(UUID().uuidString)", isDirectory: true)
    }
    private static func physicalPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }; return String(cString: pointer)
    }
    private var safeRoot: Bool { Self.physicalPath(rootPath) == rootPath }
    private var safeDirectory: Bool { safeRoot && Self.physicalPath(directory.path) == directory.path }
    func write(_ data: Data) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard data.count <= maximumBytes else { throw EditorError.limit }
        guard safeRoot else { throw EditorError.unsafeTemporaryDirectory }
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard safeDirectory, (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw EditorError.unsafeTemporaryDirectory }
        // Stat current regular owned files. Unknown files and symlink replacements are never removed.
        owned = owned.filter { isRegularOwned($0) }
        var sizes: [URL: Int] = [:]
        var bytes = 0
        for file in owned {
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= 0 else { throw EditorError.unsafeTemporaryDirectory }
            sizes[file] = size
            let sum = bytes.addingReportingOverflow(size); bytes = sum.overflow ? Int.max : sum.partialValue
        }
        while !owned.isEmpty && (owned.count >= maximumFiles || bytes > maximumBytes - data.count) {
            let old = owned.removeFirst()
            if isRegularOwned(old) { try fm.removeItem(at: old) }
            // Recompute with checked arithmetic after every eviction to handle saturated totals.
            bytes = owned.reduce(0) { result, url in let sum = result.addingReportingOverflow(sizes[url] ?? 0); return sum.overflow ? Int.max : sum.partialValue }
        }
        let url = directory.appendingPathComponent(UUID().uuidString + ".png")
        let pending = directory.appendingPathComponent(".\(UUID().uuidString).pending")
        defer { if safeDirectory { try? fm.removeItem(at: pending) } }
        try data.write(to: pending, options: .withoutOverwriting)
        guard safeDirectory else { throw EditorError.unsafeTemporaryDirectory }
        try fm.moveItem(at: pending, to: url)
        owned.append(url); return url
    }
    private func isRegularOwned(_ url: URL) -> Bool {
        guard safeDirectory, url.deletingLastPathComponent().path == directory.path,
              url.pathExtension == "png", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
              let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]), values.isSymbolicLink != true, values.isRegularFile == true else { return false }
        return true
    }
    func cleanup() {
        lock.lock(); defer { lock.unlock() }
        for url in owned where isRegularOwned(url) { try? FileManager.default.removeItem(at: url) }
        owned.removeAll()
        if safeDirectory, (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true { try? FileManager.default.removeItem(at: directory) }
    }
    deinit { cleanup() }
}
