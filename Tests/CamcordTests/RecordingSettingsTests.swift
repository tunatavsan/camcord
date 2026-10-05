import Foundation
import Testing

@testable import Camcord

@Suite("RecordingSettings")
struct RecordingSettingsTests {

    @Test("camera defaults stay off for old preferences and options survive round-trip")
    func cameraSettingsCompatibility() throws {
        let old = try JSONDecoder().decode(RecordingSettings.self, from: Data("{\"microphone\":true}".utf8))
        #expect(!old.camera.enabled)
        var changed = old
        changed.camera = CameraOptions(enabled: true, deviceID: "usb-camera", corner: .topLeft, widthFraction: 0.3, mirrored: false)
        let decoded = try JSONDecoder().decode(RecordingSettings.self, from: JSONEncoder().encode(changed))
        #expect(decoded.camera == changed.camera)
        var otherEditor = old
        otherEditor.microphoneGainDB = 9
        let merged = changed.merging(from: old, into: otherEditor)
        #expect(merged.camera == changed.camera)
        #expect(merged.microphoneGainDB == 9)
    }

    @Test("system audio with the microphone is always mixed; the switch only keeps the source tracks too")
    func microphoneAlwaysReachesTheMix() {
        let kept = RecordingSettings(systemAudio: true, microphone: true, mixAudioTracks: false)
        #expect(kept.shouldMixAudioTracks)
        #expect(kept.keepsSeparateAudioTracks)
        let mixed = RecordingSettings(systemAudio: true, microphone: true, mixAudioTracks: true)
        #expect(mixed.shouldMixAudioTracks)
        #expect(!mixed.keepsSeparateAudioTracks)
        let microphoneOnly = RecordingSettings(systemAudio: false, microphone: true, mixAudioTracks: false)
        #expect(!microphoneOnly.shouldMixAudioTracks)
        #expect(!microphoneOnly.keepsSeparateAudioTracks)
    }

    @Test("game mode halves a game display only, and defaults on for settings saved before it existed")
    func gameModeScale() throws {
        let old = try JSONDecoder().decode(RecordingSettings.self, from: Data("{\"fps\":30}".utf8))
        #expect(old.gameModeScale)
        // A Retina display: native = the backing scale, game mode = logical points (half).
        #expect(old.captureScale(displayScale: 2, gameLike: true) == 1)
        #expect(old.captureScale(displayScale: 2, gameLike: false) == 2)
        var off = old
        off.gameModeScale = false
        #expect(off.captureScale(displayScale: 2, gameLike: true) == 2)
        let decoded = try JSONDecoder().decode(RecordingSettings.self, from: JSONEncoder().encode(off))
        #expect(!decoded.gameModeScale)
        var otherEditor = old
        otherEditor.fps = 60
        let merged = off.merging(from: old, into: otherEditor)
        #expect(!merged.gameModeScale)
        #expect(merged.fps == 60)
    }

    @Test("settings that still carry the retired arming key decode without loss")
    func retiredArmingKeyIsIgnored() throws {
        let stored = Data("{\"windowGlowEnabled\":false,\"armBeforeWindowRecording\":true}".utf8)
        let decoded = try JSONDecoder().decode(RecordingSettings.self, from: stored)
        #expect(!decoded.windowGlowEnabled)
    }

    @Test("legacy settings use the balanced system gain while explicit gains round-trip independently")
    func audioGainCompatibility() throws {
        let legacy = try JSONDecoder().decode(RecordingSettings.self, from: Data("{\"microphone\":true,\"mixAudioTracks\":false}".utf8))
        #expect(legacy.resolvedMicrophoneGainDB == 0)
        #expect(legacy.resolvedSystemAudioGainDB == -6)
        #expect(!legacy.mixAudioTracks)
        let explicitUnity = try JSONDecoder().decode(RecordingSettings.self, from: Data("{\"systemAudioGainDB\":0}".utf8))
        #expect(explicitUnity.resolvedSystemAudioGainDB == 0)
        var adjusted = legacy
        adjusted.microphoneGainDB = 9
        adjusted.systemAudioGainDB = -12
        let encoded = try JSONEncoder().encode(adjusted)
        let decoded = try JSONDecoder().decode(RecordingSettings.self, from: encoded)
        #expect(decoded == adjusted)
        var otherEditor = legacy
        otherEditor.systemAudio = false
        let merged = adjusted.merging(from: legacy, into: otherEditor)
        #expect(!merged.systemAudio)
        #expect(merged.microphoneGainDB == 9 && merged.systemAudioGainDB == -12)
    }

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
        let expected = "camcord \(expectedFormatter.string(from: date)).\(defaultSettings.effectiveContainer.ext)"

        #expect(defaultSettings.filename(date: date) == expected)
    }

    // MARK: - Quality profiles

    @Test("a non-custom profile determines the codec + bitrate; ProRes forces a .mov container")
    func profileResolvesCodecAndContainer() {
        var s = RecordingSettings(profile: .balanced, codec: .h264, container: .mp4, bitrateMbps: 5)
        // Balanced overrides the stale custom codec/bitrate with its own.
        #expect(s.resolvedCodec == .hevc)
        #expect(s.resolvedBitrateMbps == 20)
        #expect(s.effectiveContainer == .mp4)   // HEVC honours the chosen container

        s.profile = .highQuality
        #expect(s.resolvedBitrateMbps == 45)

        s.profile = .proRes
        #expect(s.resolvedCodec == .proResHQ)
        #expect(s.effectiveContainer == .mov)    // ProRes is always .mov, container ignored
        #expect(s.resolvedBitrateMbps == 0)      // quality-based
    }

    @Test("the custom profile uses the user's own codec and bitrate")
    func customProfileUsesManualFields() {
        let s = RecordingSettings(profile: .custom, codec: .proRes4444, container: .mp4, bitrateMbps: 120)
        #expect(s.resolvedCodec == .proRes4444)
        #expect(s.resolvedBitrateMbps == 120)
        #expect(s.effectiveContainer == .mov)    // ProRes 4444 still forces .mov
    }

    @Test("a pre-profile-system blob (codec/bitrate, no profile key) decodes as .custom, preserving them")
    func legacyBlobPreservesCodecAndBitrate() throws {
        // Exactly what an older version persisted: codec/bitrateMbps present, no `profile`.
        let json = Data("""
        {"systemAudio":true,"microphone":true,"codec":"h264","container":"mov",\
        "bitrateMbps":10,"fps":30,"resolutionScale":"native","showsCursor":true,\
        "filenamePrefix":"camcord","windowGlowEnabled":true}
        """.utf8)
        let decoded = try JSONDecoder().decode(RecordingSettings.self, from: json)
        #expect(decoded.profile == .custom)          // NOT silently promoted to .balanced
        #expect(decoded.resolvedCodec == .h264)      // the user's choice is honored
        #expect(decoded.resolvedBitrateMbps == 10)
    }

    @Test("merging preserves a field another surface changed while this editor was stale")
    func mergePreservesConcurrentEdit() {
        let old = RecordingSettings(systemAudio: true, fps: 60)     // editor's snapshot
        var edited = old
        edited.fps = 30                                            // this editor changed fps
        var persisted = old
        persisted.systemAudio = false                              // the panel changed audio meanwhile
        let result = edited.merging(from: old, into: persisted)
        #expect(result.fps == 30)             // this editor's change is applied
        #expect(result.systemAudio == false)  // the other surface's change is NOT clobbered
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

    /// Default settings — the naming helpers are instance methods (prefix + folder).
    private let defaultSettings = RecordingSettings()

    /// The extension the default settings produce (tracks the default container).
    private var ext: String { defaultSettings.effectiveContainer.ext }

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

        let url = defaultSettings.uniqueOutputURL(in: directory, date: fixedDate)
        #expect(url.lastPathComponent == defaultSettings.filename(date: fixedDate))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a same-second collision gets a ' (2)' suffix; a second collision gets ' (3)'")
    func uniqueURLWithCollisions() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = defaultSettings.filename(date: fixedDate)
        let stem = (base as NSString).deletingPathExtension
        FileManager.default.createFile(atPath: directory.appendingPathComponent(base).path, contents: Data())

        let second = defaultSettings.uniqueOutputURL(in: directory, date: fixedDate)
        #expect(second.lastPathComponent == "\(stem) (2).\(ext)")

        FileManager.default.createFile(atPath: second.path, contents: Data())
        let third = defaultSettings.uniqueOutputURL(in: directory, date: fixedDate)
        #expect(third.lastPathComponent == "\(stem) (3).\(ext)")
    }

    @Test("the returned URL never points at an existing file, even past the counter bound")
    func uniqueURLNeverReturnsExistingPath() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Exhaust the whole counter range: base + (2)...(99).
        let base = defaultSettings.filename(date: fixedDate)
        let stem = (base as NSString).deletingPathExtension
        FileManager.default.createFile(atPath: directory.appendingPathComponent(base).path, contents: Data())
        for counter in 2..<100 {
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent("\(stem) (\(counter)).\(ext)").path,
                contents: Data()
            )
        }

        let url = defaultSettings.uniqueOutputURL(in: directory, date: fixedDate)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == ext)
    }
}
