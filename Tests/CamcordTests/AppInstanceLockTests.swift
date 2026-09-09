import Foundation
import Testing
@testable import Camcord

@Suite("App instance ownership")
struct AppInstanceLockTests {
    @Test("a second process owner is rejected and ownership is reusable after release")
    func exclusiveOwnership() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")
        var owner: AppInstanceLock? = try AppInstanceLock(url: url)
        _ = withExtendedLifetime(owner) {
            #expect(throws: AppInstanceLock.LockError.self) { try AppInstanceLock(url: url) }
        }
        owner = nil
        let replacement = try AppInstanceLock(url: url)
        withExtendedLifetime(replacement) {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("an old lock file without a living owner never blocks launching")
    func staleFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("instance.lock")
        try Data("old owner".utf8).write(to: url)
        let owner = try AppInstanceLock(url: url)
        withExtendedLifetime(owner) { #expect(FileManager.default.fileExists(atPath: url.path)) }
    }
}
