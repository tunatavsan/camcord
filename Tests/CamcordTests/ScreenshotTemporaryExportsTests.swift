import Foundation
import Testing

@testable import Camcord

@Suite("Private screenshot exports")
struct ScreenshotTemporaryExportsTests {
    @Test("cleanup touches only expired owned PNGs in the private directory")
    func cleanupOwnership() throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
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
        let fixture = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
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
}
