import Foundation
import Testing
import Darwin

@testable import Camcord

@Suite("Private screenshot exports")
struct ScreenshotTemporaryExportsTests {
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

    @Test("cleanup touches only expired owned PNGs in the private directory")
    func cleanupOwnership() throws {
        let manager = FileManager.default
        let fixture = try physicalTemporaryRoot().appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }
        let exports = ScreenshotTemporaryExports(directory: fixture.appendingPathComponent("private"))
        let old = try exports.write(Data([1]))
        let recent = try exports.write(Data([2]))
        let unrelated = fixture.appendingPathComponent("Ekran Görüntüsü unrelated.png")
        try Data([3]).write(to: unrelated)
        let unknown = exports.directory.appendingPathComponent("Ekran Görüntüsü unknown.png")
        try Data([4]).write(to: unknown)
        let directory = exports.directory.appendingPathComponent(UUID().uuidString + ".png")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        let link = exports.directory.appendingPathComponent(UUID().uuidString + ".png")
        try manager.createSymbolicLink(at: link, withDestinationURL: unrelated)
        let now = Date()
        for url in [old, unrelated, unknown, directory] {
            try manager.setAttributes([.modificationDate: now.addingTimeInterval(-25 * 3600)], ofItemAtPath: url.path)
        }
        #expect(exports.owns(old))
        #expect(!exports.owns(link))
        #expect(!exports.owns(directory))
        exports.cleanup(now: now)
        #expect(!manager.fileExists(atPath: old.path))
        for url in [recent, unrelated, unknown, directory, link] { #expect(manager.fileExists(atPath: url.path)) }
        #expect(try Data(contentsOf: unrelated) == Data([3]))
        #expect(UUID(uuidString: recent.deletingPathExtension().lastPathComponent) != nil)
        let permissions = try manager.attributesOfItem(atPath: exports.directory.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
    }

    @Test("a symlink root or parent cannot redirect export writes or cleanup")
    func redirectedRoot() throws {
        let manager = FileManager.default
        let fixture = try physicalTemporaryRoot().appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }
        let target = fixture.appendingPathComponent("target")
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        let ownedLooking = target.appendingPathComponent(UUID().uuidString + ".png")
        try Data([7]).write(to: ownedLooking)
        try manager.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: ownedLooking.path)
        let link = fixture.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: target)
        for directory in [link, link.appendingPathComponent("nested")] {
            let exports = ScreenshotTemporaryExports(directory: directory)
            #expect(throws: (any Error).self) { try exports.write(Data([8])) }
            exports.cleanup()
        }
        #expect(try Data(contentsOf: ownedLooking) == Data([7]))
        #expect(!manager.fileExists(atPath: target.appendingPathComponent("nested").path))
    }
    @Test("cleanup preserves unrelated regular files even when their names look owned")
    func unknownUUIDFile() throws {
        let manager = FileManager.default
        let fixture = try physicalTemporaryRoot().appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }
        let exports = ScreenshotTemporaryExports(directory: fixture.appendingPathComponent("exports"))
        _ = try exports.write(Data([1]))
        let unknown = exports.directory.appendingPathComponent(UUID().uuidString + ".png")
        try Data([9]).write(to: unknown)
        try manager.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: unknown.path)
        #expect(!exports.owns(unknown))
        exports.cleanup()
        #expect(try Data(contentsOf: unknown) == Data([9]))
    }

    @Test("raw injected ancestor aliases are rejected before creating the export directory")
    func rawAncestorAlias() throws {
        let manager = FileManager.default
        let fixture = try physicalTemporaryRoot().appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }
        let child = fixture.appendingPathComponent("child")
        try manager.createDirectory(at: child, withIntermediateDirectories: false)
        let alias = fixture.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: fixture)
        let exports = ScreenshotTemporaryExports(directory: alias.appendingPathComponent("child/exports"))
        #expect(throws: (any Error).self) { try exports.write(Data([7])) }
        #expect(!manager.fileExists(atPath: child.appendingPathComponent("exports").path))
        exports.cleanup()
    }

    @Test("replacing a previously accepted root with a regular directory invalidates its ownership")
    func replacedRoot() throws {
        let manager = FileManager.default
        let fixture = try physicalTemporaryRoot().appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }
        let directory = fixture.appendingPathComponent("exports"), moved = fixture.appendingPathComponent("moved")
        let exports = ScreenshotTemporaryExports(directory: directory)
        let old = try exports.write(Data([1]))
        try manager.moveItem(at: directory, to: moved)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        let unknown = directory.appendingPathComponent(UUID().uuidString + ".png")
        try Data([8]).write(to: unknown)
        #expect(throws: (any Error).self) { try exports.write(Data([7])) }
        exports.cleanup()
        #expect(try Data(contentsOf: unknown) == Data([8]))
        #expect(manager.fileExists(atPath: moved.appendingPathComponent(old.lastPathComponent).path))
    }

    @Test("a physical private Darwin root and the trusted system default accept genuine exports")
    func physicalRoot() throws {
        let manager = FileManager.default
        let fixture = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }
        let exports = ScreenshotTemporaryExports(directory: fixture.appendingPathComponent("exports"))
        let url = try exports.write(Data([5]))
        #expect(exports.owns(url))
        #expect(try Data(contentsOf: url) == Data([5]))
        // Default-root construction is exercised without writing shared production temp data.
        #expect(ScreenshotTemporaryExports().directory.path.hasPrefix("/private/"))
    }

}
