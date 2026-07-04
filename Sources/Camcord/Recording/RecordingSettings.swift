import Foundation

/// How the recording's pixel dimensions relate to the source's native (Retina) size.
enum ResolutionScale: String, Codable, CaseIterable {
    /// Full native pixels (Retina) — sharpest, largest files.
    case native
    /// Downscaled to logical points (1x) — smaller files.
    case oneX
}

/// User-configurable recording options plus the file-naming/output-location helpers.
/// Persisted as JSON in `UserDefaults` (injectable suite for tests). New fields decode
/// with defaults so settings saved by an older version keep working.
struct RecordingSettings: Codable, Equatable {
    var systemAudio: Bool
    var microphone: Bool
    /// The AVCaptureDevice.uniqueID of the mic to record; nil = system default input.
    var microphoneDeviceID: String?

    // Quality
    var codec: VideoCodecChoice
    /// Average video bitrate in Mbps for HEVC/H.264; 0 = let the encoder choose.
    /// Ignored for ProRes (quality-based).
    var bitrateMbps: Int
    var fps: Int
    var resolutionScale: ResolutionScale

    // Output
    /// Custom output folder; nil = `~/Movies/camcord`.
    var outputDirectoryPath: String?
    /// Filename stem before the timestamp (e.g. "camcord" → "camcord 2026-… .mov").
    var filenamePrefix: String

    /// A subtle glow border around a recorded window while recording (window target
    /// only; never full-screen). Not captured in the recording.
    var windowGlowEnabled: Bool

    init(
        systemAudio: Bool = true,
        microphone: Bool = true,
        microphoneDeviceID: String? = nil,
        codec: VideoCodecChoice = .hevc,
        bitrateMbps: Int = 0,
        fps: Int = 60,
        resolutionScale: ResolutionScale = .native,
        outputDirectoryPath: String? = nil,
        filenamePrefix: String = "camcord",
        windowGlowEnabled: Bool = true
    ) {
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.microphoneDeviceID = microphoneDeviceID
        self.codec = codec
        self.bitrateMbps = bitrateMbps
        self.fps = fps
        self.resolutionScale = resolutionScale
        self.outputDirectoryPath = outputDirectoryPath
        self.filenamePrefix = filenamePrefix
        self.windowGlowEnabled = windowGlowEnabled
    }

    // Backward-compatible decode: any field missing from older persisted JSON falls
    // back to its default instead of failing the whole decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecordingSettings()
        systemAudio = try c.decodeIfPresent(Bool.self, forKey: .systemAudio) ?? d.systemAudio
        microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? d.microphone
        microphoneDeviceID = try c.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
        codec = try c.decodeIfPresent(VideoCodecChoice.self, forKey: .codec) ?? d.codec
        bitrateMbps = try c.decodeIfPresent(Int.self, forKey: .bitrateMbps) ?? d.bitrateMbps
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
        resolutionScale = try c.decodeIfPresent(ResolutionScale.self, forKey: .resolutionScale) ?? d.resolutionScale
        outputDirectoryPath = try c.decodeIfPresent(String.self, forKey: .outputDirectoryPath)
        filenamePrefix = try c.decodeIfPresent(String.self, forKey: .filenamePrefix) ?? d.filenamePrefix
        windowGlowEnabled = try c.decodeIfPresent(Bool.self, forKey: .windowGlowEnabled) ?? d.windowGlowEnabled
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

    /// `<prefix> 2026-07-03 at 21.15.30.mov` -- dots in the time part because colons
    /// are path-hostile on macOS.
    func filename(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stem = filenamePrefix.isEmpty ? "camcord" : filenamePrefix
        return "\(stem) \(formatter.string(from: date)).mov"
    }

    /// The user's chosen folder, or `~/Movies/camcord`, created on first use.
    func outputDirectory() throws -> URL {
        let directory: URL
        if let outputDirectoryPath, !outputDirectoryPath.isEmpty {
            directory = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
        } else {
            let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            directory = movies.appendingPathComponent("camcord", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The default folder path (`~/Movies/camcord`) for display when none is chosen.
    static func defaultDirectoryPath() -> String {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return movies.appendingPathComponent("camcord", isDirectory: true).path
    }

    /// A guaranteed-fresh output URL. The filename has one-second resolution, so two
    /// recordings started within the same second would collide — and a collision is
    /// catastrophic: AVAssetWriter refuses existing files, and the codec fallback's
    /// cleanup would delete the PREVIOUS, finished recording. Uniquifying here makes
    /// every downstream `removeItem(at: outputURL)` provably safe.
    func uniqueOutputURL(in directory: URL, date: Date, fileManager: FileManager = .default) -> URL {
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

/// Screenshot quality preference (separate from recording).
struct ScreenshotSettings: Codable, Equatable {
    var resolutionScale: ResolutionScale

    init(resolutionScale: ResolutionScale = .native) {
        self.resolutionScale = resolutionScale
    }

    static let defaultsKey = "screenshotSettings"

    static func load(from defaults: UserDefaults) -> ScreenshotSettings {
        guard
            let data = defaults.data(forKey: defaultsKey),
            let settings = try? JSONDecoder().decode(ScreenshotSettings.self, from: data)
        else {
            return ScreenshotSettings()
        }
        return settings
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
