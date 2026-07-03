import Foundation
import Testing

@testable import Camcord

@Suite("RecordingSettings")
struct RecordingSettingsTests {

    /// A uniquely-named suite per test so tests never see each other's state or the
    /// user's real defaults.
    private func makeTestDefaults() -> UserDefaults {
        let suiteName = "dev.tavsan.camcord.tests.recordingsettings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create a UserDefaults test suite")
        }
        return defaults
    }

    @Test("defaults to both system audio and microphone enabled when the key is absent")
    func defaultsWhenKeyAbsent() {
        let defaults = makeTestDefaults()
        let loaded = RecordingSettings.load(from: defaults)
        #expect(loaded == RecordingSettings(systemAudio: true, microphone: true))
    }

    @Test("round-trips through UserDefaults as JSON under the recordingSettings key")
    func codableRoundTrip() {
        let defaults = makeTestDefaults()
        let settings = RecordingSettings(systemAudio: false, microphone: true)
        settings.save(to: defaults)

        #expect(defaults.data(forKey: "recordingSettings") != nil)
        #expect(RecordingSettings.load(from: defaults) == settings)
    }

    @Test("filename formatter matches the 'camcord yyyy-MM-dd at HH.mm.ss.mov' pattern for a fixed date")
    func filenameFormatterMatchesPattern() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 3
        components.hour = 21
        components.minute = 15
        components.second = 30
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components) else {
            Issue.record("Failed to construct a fixed test Date")
            return
        }

        let expectedFormatter = DateFormatter()
        expectedFormatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        expectedFormatter.locale = Locale(identifier: "en_US_POSIX")
        expectedFormatter.calendar = calendar
        let expected = "camcord \(expectedFormatter.string(from: date)).mov"

        #expect(RecordingSettings.filename(date: date) == expected)
    }

    // MARK: - uniqueOutputURL (collision avoidance is safety-critical: downstream
    // failure paths delete the returned URL, so returning an EXISTING path would
    // delete a previous, finished recording)

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("camcord-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var fixedDate: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 3
        components.hour = 21
        components.minute = 15
        components.second = 30
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test("uniqueOutputURL returns the plain filename when nothing collides")
    func uniqueURLWithoutCollision() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = RecordingSettings.uniqueOutputURL(in: directory, date: fixedDate)
        #expect(url.lastPathComponent == RecordingSettings.filename(date: fixedDate))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a same-second collision gets a ' (2)' suffix; a second collision gets ' (3)'")
    func uniqueURLWithCollisions() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = RecordingSettings.filename(date: fixedDate)
        let stem = (base as NSString).deletingPathExtension
        FileManager.default.createFile(atPath: directory.appendingPathComponent(base).path, contents: Data())

        let second = RecordingSettings.uniqueOutputURL(in: directory, date: fixedDate)
        #expect(second.lastPathComponent == "\(stem) (2).mov")

        FileManager.default.createFile(atPath: second.path, contents: Data())
        let third = RecordingSettings.uniqueOutputURL(in: directory, date: fixedDate)
        #expect(third.lastPathComponent == "\(stem) (3).mov")
    }

    @Test("the returned URL never points at an existing file, even past the counter bound")
    func uniqueURLNeverReturnsExistingPath() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Exhaust the whole counter range: base + (2)...(99).
        let base = RecordingSettings.filename(date: fixedDate)
        let stem = (base as NSString).deletingPathExtension
        FileManager.default.createFile(atPath: directory.appendingPathComponent(base).path, contents: Data())
        for counter in 2..<100 {
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent("\(stem) (\(counter)).mov").path,
                contents: Data()
            )
        }

        let url = RecordingSettings.uniqueOutputURL(in: directory, date: fixedDate)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == "mov")
    }
}
