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
}
