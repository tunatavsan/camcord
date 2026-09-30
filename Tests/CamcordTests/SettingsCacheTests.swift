import Foundation
import Testing

@testable import Camcord

@Suite("Settings cache safety")
struct SettingsCacheTests {
    @Test("cache accounting ignores foreign files, directories and symlinks")
    func onlyOwnedRegularFilesCount() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owned = directory.appendingPathComponent("\(UUID().uuidString).png")
        try Data(repeating: 1, count: 23).write(to: owned)
        try Data(repeating: 2, count: 51).write(to: directory.appendingPathComponent("personal.png"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("\(UUID().uuidString).png"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("\(UUID().uuidString).png"),
                                                   withDestinationURL: owned)
        let bytes = try await LibraryCache.usedBytes(directory: directory)
        #expect(bytes == 23)
    }

    @Test("clear rejects linked folders and reports failed Trash operations without touching foreign files")
    func clearIsBoundedAndReportsFailures() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = cache.appendingPathComponent("\(UUID().uuidString).png")
        let foreign = cache.appendingPathComponent("personal.png")
        try Data([1, 2, 3]).write(to: owned)
        try Data([4, 5]).write(to: foreign)
        let link = root.appendingPathComponent("cache-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cache)
        await #expect(throws: LibraryCache.CacheError.self) {
            try await LibraryCache.clear(directory: link, trash: { _ in Issue.record("A linked directory must never reach Trash") })
        }
        enum Denied: Error { case denied }
        await #expect(throws: LibraryCache.CacheError.self) {
            try await LibraryCache.clear(directory: cache, trash: { _ in throw Denied.denied })
        }
        #expect(FileManager.default.fileExists(atPath: owned.path))
        try await LibraryCache.clear(directory: cache, trash: { url in
            #expect(url.lastPathComponent == owned.lastPathComponent)
            // Test substitute moves our fixture to a fixture Trash; it never invokes macOS Trash.
            try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("trashed.png"))
        })
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(try Data(contentsOf: foreign) == Data([4, 5]))
        #expect(try await LibraryCache.usedBytes(directory: cache) == 0)
    }
}
