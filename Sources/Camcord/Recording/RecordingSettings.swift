import Foundation

/// User-configurable recording options plus the file-naming/output-location helpers.
/// Persisted as JSON in `UserDefaults` (injectable suite for tests).
struct RecordingSettings: Codable, Equatable {
    var systemAudio: Bool
    var microphone: Bool

    init(systemAudio: Bool = true, microphone: Bool = true) {
        self.systemAudio = systemAudio
        self.microphone = microphone
    }

    static let defaultsKey = "recordingSettings"

    static func load(from defaults: UserDefaults) -> RecordingSettings {
        guard
            let data = defaults.data(forKey: defaultsKey),
            let settings = try? JSONDecoder().decode(RecordingSettings.self, from: data)
        else {
            return RecordingSettings()
        }
        return settings
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    // MARK: - Output location & naming

    /// `camcord 2026-07-03 at 21.15.30.mov` -- dots in the time part because colons
    /// are path-hostile on macOS.
    static func filename(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "camcord \(formatter.string(from: date)).mov"
    }

    /// `~/Movies/camcord`, created on first use.
    static func outputDirectory() throws -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let directory = movies.appendingPathComponent("camcord", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A guaranteed-fresh output URL. The filename has one-second resolution, so two
    /// recordings started within the same second would collide — and a collision is
    /// catastrophic: AVAssetWriter refuses existing files, and the HEVC→H.264
    /// fallback's cleanup would delete the PREVIOUS, finished recording. Uniquifying
    /// here makes every downstream `removeItem(at: outputURL)` provably safe.
    static func uniqueOutputURL(in directory: URL, date: Date, fileManager: FileManager = .default) -> URL {
        let base = filename(date: date)
        let stem = (base as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(base)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path), counter < 100 {
            candidate = directory.appendingPathComponent("\(stem) (\(counter)).mov")
            counter += 1
        }
        // Pathological bound (99 same-second collisions): never return a path that
        // still exists — fall back to a unique suffix.
        if fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) \(UUID().uuidString.prefix(8)).mov")
        }
        return candidate
    }
}
