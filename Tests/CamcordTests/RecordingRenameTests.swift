import Foundation
import Testing

@testable import Camcord

@Suite("Recording rename")
struct RecordingRenameTests {
    @Test("moves a recording to an unused name without changing its bytes")
    func successfulRename() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Before.mov")
        let target = directory.appendingPathComponent("After.mov")
        let payload = Data("recording-payload".utf8)
        try payload.write(to: source)

        let outcome = await RecordingRename.move(from: source, to: target)

        #expect(outcome == .success)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: target) == payload)
    }

    @Test("refuses an occupied target and preserves both files")
    func collisionPreservesBothFiles() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Source.mov")
        let target = directory.appendingPathComponent("Existing.mov")
        let sourcePayload = Data("source".utf8)
        let targetPayload = Data("target".utf8)
        try sourcePayload.write(to: source)
        try targetPayload.write(to: target)

        let outcome = await RecordingRename.move(from: source, to: target)

        #expect(outcome == .collision)
        #expect(try Data(contentsOf: source) == sourcePayload)
        #expect(try Data(contentsOf: target) == targetPayload)
    }

    @Test("changes capitalization in place on a case-insensitive volume")
    func capitalizationOnlyRename() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let supportsCaseSensitiveNames = try directory.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames
        guard supportsCaseSensitiveNames == false else { return }

        let source = directory.appendingPathComponent("Capture.mov")
        let target = directory.appendingPathComponent("capture.mov")
        let payload = Data("case-only".utf8)
        try payload.write(to: source)

        let outcome = await RecordingRename.move(from: source, to: target)
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )

        #expect(outcome == .success)
        #expect(entries.map(\.lastPathComponent) == [target.lastPathComponent])
        #expect(try Data(contentsOf: target) == payload)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("camcord-recording-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
