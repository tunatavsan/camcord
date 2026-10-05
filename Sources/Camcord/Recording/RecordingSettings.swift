import CoreGraphics
import Foundation

/// How the recording's pixel dimensions relate to the source's native (Retina) size.
enum ResolutionScale: String, Codable, CaseIterable, Sendable {
    /// Full native pixels (Retina) — sharpest, largest files.
    case native
    /// Downscaled to logical points (1x) — smaller files.
    case oneX
}

/// The dynamic range of the recording. HDR requires a 10-bit codec (HEVC/ProRes) and an HDR display.
enum DynamicRange: String, Codable, CaseIterable {
    case sdr
    case hdr
}

/// A one-tap quality preset spanning "smallest efficient file" to "production master".
/// Every profile except `.custom` fully determines the codec + bitrate; `.custom` hands
/// control to the user's manual codec / bitrate / container fields.
enum RecordingProfile: String, Codable, CaseIterable {
    case efficient      // small, storage/share-friendly
    case balanced       // the default: efficient AND high quality
    case highQuality    // upload/YouTube-grade
    case maximum        // highest-bitrate delivery
    case proRes         // near-lossless editing master
    case custom         // user-defined

    /// The codec this profile records with (nil = use the user's custom codec).
    var codec: VideoCodecChoice? {
        switch self {
        case .efficient, .balanced, .highQuality, .maximum: .hevc
        case .proRes: .proResHQ
        case .custom: nil
        }
    }

    /// Target average bitrate in Mbps (0 = quality-based / not applicable).
    var bitrateMbps: Int {
        switch self {
        case .efficient: 8
        case .balanced: 20
        case .highQuality: 45
        case .maximum: 90
        case .proRes, .custom: 0
        }
    }
}

/// User-configurable recording options plus the file-naming/output-location helpers.
/// Persisted as JSON in `UserDefaults` (injectable suite for tests). New fields decode
/// with defaults so settings saved by an older version keep working.
struct RecordingSettings: Codable, Equatable {
    var systemAudio: Bool
    var microphone: Bool
    /// The AVCaptureDevice.uniqueID of the mic to record; nil = system default input.
    var microphoneDeviceID: String?
    /// When both system audio AND microphone are recorded, they are always mixed into
    /// the file's first audio track at finalize: most players/platforms play only the
    /// first track, so a file led by system audio leaves the mic silently inaudible.
    /// On (default), the mix is the only audio track. Off also keeps the two source
    /// tracks for editing, disabled behind the mix.
    var mixAudioTracks: Bool
    /// Software gain is independent of the current microphone hardware.
    var systemAudioGainDB: Double
    var microphoneGainDB: Double
    var camera: CameraOptions

    // Safety limits
    /// Auto-stop after this many minutes (0 = unlimited). Guards against a forgotten
    /// recording filling the disk.
    var maxDurationMinutes: Int
    /// Auto-stop (and keep the file) when the output volume's free space runs low,
    /// instead of letting the writer fail and lose the whole recording.
    var stopWhenDiskLow: Bool

    // Do Not Disturb (best-effort via the Shortcuts CLI; no public Focus API exists)
    /// Run the on/off Shortcuts around a recording to silence notifications.
    var dndEnabled: Bool
    /// The name of a user-made Shortcut that turns Focus/DND ON (empty = skip).
    var dndShortcutOn: String
    /// The name of a user-made Shortcut that turns Focus/DND OFF (empty = skip).
    var dndShortcutOff: String

    // Quality
    /// The active quality preset. Non-`.custom` profiles override `codec`/`bitrateMbps`.
    var profile: RecordingProfile
    /// Custom codec — used only when `profile == .custom`.
    var codec: VideoCodecChoice
    var container: VideoContainer
    /// Custom average video bitrate in Mbps (used only when `profile == .custom`); 0 =
    /// let the encoder choose. Ignored for ProRes (quality-based).
    var bitrateMbps: Int
    var fps: Int
    var resolutionScale: ResolutionScale
    /// Halve the resolution of a game-context display recording (1080p on a Retina
    /// display) so the encoder does not compete with the game for GPU and thermal
    /// budget. Applies to game-like targets ONLY; fps and codec are untouched.
    var gameModeScale: Bool
    var dynamicRange: DynamicRange
    /// Whether the pointer is drawn into the recording.
    var showsCursor: Bool
    /// 3-2-1 countdown before a full-screen recording starts. Opt-in (CleanShot's is
    /// too): a mandatory delay would tax the quick-capture use, but staged demo
    /// recordings genuinely want the beat.
    var countdownEnabled: Bool

    // Output
    /// Custom output folder; nil = `~/Movies/camcord`.
    var outputDirectoryPath: String?
    /// Filename stem before the timestamp (e.g. "camcord" → "camcord 2026-… .mov").
    var filenamePrefix: String

    /// A subtle glow border around a recorded window while recording (window target
    /// only; never full-screen). Not captured in the recording.
    var windowGlowEnabled: Bool

    /// Where the recording hub rests on the display. Persisted so it comes back where the
    /// owner last threw it, instead of guessing from the target's geometry.
    var hubDock: RecordingHubDock

    /// The canvas of a window recording (region and display targets ignore it).
    var canvasAspect: CanvasAspect

    init(
        systemAudio: Bool = true,
        microphone: Bool = true,
        microphoneDeviceID: String? = nil,
        mixAudioTracks: Bool = true,
        systemAudioGainDB: Double = -6,
        microphoneGainDB: Double = 0,
        camera: CameraOptions = CameraOptions(),
        maxDurationMinutes: Int = 0,
        stopWhenDiskLow: Bool = true,
        dndEnabled: Bool = true,
        dndShortcutOn: String = "",
        dndShortcutOff: String = "",
        profile: RecordingProfile = .balanced,
        codec: VideoCodecChoice = .hevc,
        container: VideoContainer = .mp4,
        bitrateMbps: Int = 20,
        fps: Int = 60,
        resolutionScale: ResolutionScale = .native,
        gameModeScale: Bool = true,
        dynamicRange: DynamicRange = .sdr,
        showsCursor: Bool = true,
        countdownEnabled: Bool = false,
        outputDirectoryPath: String? = nil,
        filenamePrefix: String = "camcord",
        windowGlowEnabled: Bool = true,
        hubDock: RecordingHubDock = .topCenter,
        canvasAspect: CanvasAspect = .matchWindow
    ) {
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.microphoneDeviceID = microphoneDeviceID
        self.mixAudioTracks = mixAudioTracks
        self.systemAudioGainDB = systemAudioGainDB
        self.microphoneGainDB = microphoneGainDB
        self.camera = camera
        self.maxDurationMinutes = maxDurationMinutes
        self.stopWhenDiskLow = stopWhenDiskLow
        self.dndEnabled = dndEnabled
        self.dndShortcutOn = dndShortcutOn
        self.dndShortcutOff = dndShortcutOff
        self.profile = profile
        self.codec = codec
        self.container = container
        self.bitrateMbps = bitrateMbps
        self.fps = fps
        self.resolutionScale = resolutionScale
        self.gameModeScale = gameModeScale
        self.dynamicRange = dynamicRange
        self.showsCursor = showsCursor
        self.countdownEnabled = countdownEnabled
        self.outputDirectoryPath = outputDirectoryPath
        self.filenamePrefix = filenamePrefix
        self.windowGlowEnabled = windowGlowEnabled
        self.hubDock = hubDock
        self.canvasAspect = canvasAspect
    }

    /// True when a recording will produce two separate audio tracks, which are always
    /// mixed into one at finalize.
    var shouldMixAudioTracks: Bool { systemAudio && microphone }

    /// True when the mixed file also keeps the two source tracks, for editing.
    var keepsSeparateAudioTracks: Bool { shouldMixAudioTracks && !mixAudioTracks }

    var resolvedSystemAudioGainDB: Double {
        systemAudioGainDB.isFinite ? min(12, max(-60, systemAudioGainDB)) : 0
    }

    var resolvedMicrophoneGainDB: Double {
        microphoneGainDB.isFinite ? min(24, max(-24, microphoneGainDB)) : 0
    }

    /// The codec actually used: the profile's codec, or the custom one.
    var resolvedCodec: VideoCodecChoice { profile.codec ?? codec }

    /// The bitrate actually used (Mbps; 0 = auto / quality-based).
    var resolvedBitrateMbps: Int { profile == .custom ? bitrateMbps : profile.bitrateMbps }

    /// The scale a DISPLAY target is captured at. `SCDisplay.frame` is in logical points,
    /// so the display's backing scale means native Retina pixels and 1 means points —
    /// exactly the half-resolution "Oyunda 1080p kaydet" wants for a game-like target.
    func captureScale(displayScale: CGFloat, gameLike: Bool) -> CGFloat {
        gameLike && gameModeScale ? 1 : displayScale
    }

    /// ProRes only lives in a `.mov`; otherwise the chosen container.
    var effectiveContainer: VideoContainer {
        resolvedCodec.isProRes ? .mov : container
    }

    // Backward-compatible decode: any field missing from older persisted JSON falls
    // back to its default instead of failing the whole decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecordingSettings()
        systemAudio = try c.decodeIfPresent(Bool.self, forKey: .systemAudio) ?? d.systemAudio
        microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? d.microphone
        microphoneDeviceID = try c.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
        mixAudioTracks = try c.decodeIfPresent(Bool.self, forKey: .mixAudioTracks) ?? d.mixAudioTracks
        systemAudioGainDB = try c.decodeIfPresent(Double.self, forKey: .systemAudioGainDB) ?? d.systemAudioGainDB
        microphoneGainDB = try c.decodeIfPresent(Double.self, forKey: .microphoneGainDB) ?? d.microphoneGainDB
        camera = try c.decodeIfPresent(CameraOptions.self, forKey: .camera) ?? d.camera
        maxDurationMinutes = try c.decodeIfPresent(Int.self, forKey: .maxDurationMinutes) ?? d.maxDurationMinutes
        stopWhenDiskLow = try c.decodeIfPresent(Bool.self, forKey: .stopWhenDiskLow) ?? d.stopWhenDiskLow
        dndEnabled = try c.decodeIfPresent(Bool.self, forKey: .dndEnabled) ?? d.dndEnabled
        dndShortcutOn = try c.decodeIfPresent(String.self, forKey: .dndShortcutOn) ?? d.dndShortcutOn
        dndShortcutOff = try c.decodeIfPresent(String.self, forKey: .dndShortcutOff) ?? d.dndShortcutOff
        // A blob predating the profile system has `codec`/`bitrateMbps` but no `profile`.
        // Default those to `.custom` (not `.balanced`) so the user's explicitly-chosen
        // codec/bitrate keep being honored instead of being silently overridden.
        let legacyQualityKeys = c.contains(.codec) || c.contains(.bitrateMbps)
        profile = try c.decodeIfPresent(RecordingProfile.self, forKey: .profile)
            ?? (legacyQualityKeys ? .custom : d.profile)
        codec = try c.decodeIfPresent(VideoCodecChoice.self, forKey: .codec) ?? d.codec
        container = try c.decodeIfPresent(VideoContainer.self, forKey: .container) ?? d.container
        bitrateMbps = try c.decodeIfPresent(Int.self, forKey: .bitrateMbps) ?? d.bitrateMbps
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
        resolutionScale = try c.decodeIfPresent(ResolutionScale.self, forKey: .resolutionScale) ?? d.resolutionScale
        gameModeScale = try c.decodeIfPresent(Bool.self, forKey: .gameModeScale) ?? d.gameModeScale
        dynamicRange = try c.decodeIfPresent(DynamicRange.self, forKey: .dynamicRange) ?? d.dynamicRange
        showsCursor = try c.decodeIfPresent(Bool.self, forKey: .showsCursor) ?? d.showsCursor
        countdownEnabled = try c.decodeIfPresent(Bool.self, forKey: .countdownEnabled) ?? d.countdownEnabled
        outputDirectoryPath = try c.decodeIfPresent(String.self, forKey: .outputDirectoryPath)
        filenamePrefix = try c.decodeIfPresent(String.self, forKey: .filenamePrefix) ?? d.filenamePrefix
        windowGlowEnabled = try c.decodeIfPresent(Bool.self, forKey: .windowGlowEnabled) ?? d.windowGlowEnabled
        hubDock = (try? c.decodeIfPresent(RecordingHubDock.self, forKey: .hubDock)) ?? d.hubDock
        canvasAspect = (try? c.decodeIfPresent(CanvasAspect.self, forKey: .canvasAspect)) ?? d.canvasAspect
    }

    /// Applies onto `base` only the fields where `self` differs from `old` — so a whole-
    /// struct write from one editing surface (the Settings window) can't clobber fields
    /// another surface (the menu-bar panel) changed meanwhile. `base` is the freshly
    /// persisted value; `old` is this editor's previous snapshot.
    func merging(from old: RecordingSettings, into base: RecordingSettings) -> RecordingSettings {
        var r = base
        if systemAudio != old.systemAudio { r.systemAudio = systemAudio }
        if microphone != old.microphone { r.microphone = microphone }
        if microphoneDeviceID != old.microphoneDeviceID { r.microphoneDeviceID = microphoneDeviceID }
        if mixAudioTracks != old.mixAudioTracks { r.mixAudioTracks = mixAudioTracks }
        if systemAudioGainDB != old.systemAudioGainDB { r.systemAudioGainDB = systemAudioGainDB }
        if microphoneGainDB != old.microphoneGainDB { r.microphoneGainDB = microphoneGainDB }
        if camera != old.camera { r.camera = camera }
        if maxDurationMinutes != old.maxDurationMinutes { r.maxDurationMinutes = maxDurationMinutes }
        if stopWhenDiskLow != old.stopWhenDiskLow { r.stopWhenDiskLow = stopWhenDiskLow }
        if dndEnabled != old.dndEnabled { r.dndEnabled = dndEnabled }
        if dndShortcutOn != old.dndShortcutOn { r.dndShortcutOn = dndShortcutOn }
        if dndShortcutOff != old.dndShortcutOff { r.dndShortcutOff = dndShortcutOff }
        if profile != old.profile { r.profile = profile }
        if codec != old.codec { r.codec = codec }
        if container != old.container { r.container = container }
        if bitrateMbps != old.bitrateMbps { r.bitrateMbps = bitrateMbps }
        if fps != old.fps { r.fps = fps }
        if resolutionScale != old.resolutionScale { r.resolutionScale = resolutionScale }
        if gameModeScale != old.gameModeScale { r.gameModeScale = gameModeScale }
        if dynamicRange != old.dynamicRange { r.dynamicRange = dynamicRange }
        if showsCursor != old.showsCursor { r.showsCursor = showsCursor }
        if countdownEnabled != old.countdownEnabled { r.countdownEnabled = countdownEnabled }
        if outputDirectoryPath != old.outputDirectoryPath { r.outputDirectoryPath = outputDirectoryPath }
        if filenamePrefix != old.filenamePrefix { r.filenamePrefix = filenamePrefix }
        if windowGlowEnabled != old.windowGlowEnabled { r.windowGlowEnabled = windowGlowEnabled }
        if hubDock != old.hubDock { r.hubDock = hubDock }
        if canvasAspect != old.canvasAspect { r.canvasAspect = canvasAspect }
        return r
    }

    static let defaultsKey = "recordingSettings"
    static let didChangeNotification = Notification.Name("dev.tavsan.camcord.recordingSettingsChanged")

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
        NotificationCenter.default.post(name: Self.didChangeNotification, object: defaults)
    }

    // MARK: - Output location & naming

    /// `<prefix> 2026-07-03 at 21.15.30.mov` -- dots in the time part because colons
    /// are path-hostile on macOS. Extension follows the effective container.
    func filename(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // The prefix is user-entered — strip path separators / control chars so it can
        // never break out of the output directory or produce an invalid path.
        let cleaned = filenamePrefix
            .components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters))
            .joined()
            .trimmingCharacters(in: .whitespaces)
        let stem = cleaned.isEmpty ? "camcord" : cleaned
        return "\(stem) \(formatter.string(from: date)).\(effectiveContainer.ext)"
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
        let ext = (base as NSString).pathExtension
        var candidate = directory.appendingPathComponent(base)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path), counter < 100 {
            candidate = directory.appendingPathComponent("\(stem) (\(counter)).\(ext)")
            counter += 1
        }
        // Pathological bound (99 same-second collisions): never return a path that
        // still exists — fall back to a unique suffix.
        if fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) \(UUID().uuidString.prefix(8)).\(ext)")
        }
        return candidate
    }
}

/// What every screenshot does by itself; the screenshot card offers whatever is left.
enum ScreenshotDestination: String, CaseIterable, Identifiable, Sendable {
    case libraryAndClipboard, clipboard, library
    var id: Self { self }
    init(copies: Bool, keeps: Bool) { self = copies ? (keeps ? .libraryAndClipboard : .clipboard) : .library }
    var copies: Bool { self != .library }
    var keeps: Bool { self != .clipboard }
}

/// Screenshot preferences (separate from recording): quality, and optionally saving a
/// copy of every screenshot to a folder (distinct from where videos go).
struct ScreenshotSettings: Codable, Equatable, Sendable {
    var resolutionScale: ResolutionScale
    /// When true, every screenshot is also written to `saveDirectory` (in addition to
    /// the clipboard).
    var saveToDisk: Bool
    /// Custom screenshot folder; nil = `~/Pictures/camcord`.
    var saveDirectoryPath: String?
    /// False keeps screenshots in the Library only; the card then offers Copy.
    var copyToClipboard: Bool

    init(
        resolutionScale: ResolutionScale = .native,
        saveToDisk: Bool = false,
        saveDirectoryPath: String? = nil,
        copyToClipboard: Bool = true
    ) {
        self.resolutionScale = resolutionScale
        self.saveToDisk = saveToDisk
        self.saveDirectoryPath = saveDirectoryPath
        self.copyToClipboard = copyToClipboard
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScreenshotSettings()
        resolutionScale = try c.decodeIfPresent(ResolutionScale.self, forKey: .resolutionScale) ?? d.resolutionScale
        saveToDisk = try c.decodeIfPresent(Bool.self, forKey: .saveToDisk) ?? d.saveToDisk
        saveDirectoryPath = try c.decodeIfPresent(String.self, forKey: .saveDirectoryPath)
        copyToClipboard = try c.decodeIfPresent(Bool.self, forKey: .copyToClipboard) ?? d.copyToClipboard
    }

    /// See `RecordingSettings.merging(from:into:)` — preserves fields another surface
    /// changed while this editor held a stale cached copy.
    func merging(from old: ScreenshotSettings, into base: ScreenshotSettings) -> ScreenshotSettings {
        var r = base
        if resolutionScale != old.resolutionScale { r.resolutionScale = resolutionScale }
        if saveToDisk != old.saveToDisk { r.saveToDisk = saveToDisk }
        if saveDirectoryPath != old.saveDirectoryPath { r.saveDirectoryPath = saveDirectoryPath }
        if copyToClipboard != old.copyToClipboard { r.copyToClipboard = copyToClipboard }
        return r
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

    // MARK: - Save location & naming (default ~/Pictures/camcord)

    static func defaultDirectoryPath() -> String {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return pictures.appendingPathComponent("camcord", isDirectory: true).path
    }

    /// The chosen screenshot folder (created on first use), or nil if it can't be made.
    func saveDirectory() -> URL? {
        let path = (saveDirectoryPath?.isEmpty == false) ? saveDirectoryPath! : Self.defaultDirectoryPath()
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    /// A guaranteed-fresh `.png` URL in the save folder, or nil when saving is off /
    /// the folder can't be created.
    func uniqueSaveURL(date: Date, fileManager: FileManager = .default) -> URL? {
        guard saveToDisk, let dir = saveDirectory() else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stem = "camcord \(formatter.string(from: date))"
        var candidate = dir.appendingPathComponent("\(stem).png")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path), counter < 100 {
            candidate = dir.appendingPathComponent("\(stem) (\(counter)).png")
            counter += 1
        }
        if fileManager.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem) \(UUID().uuidString.prefix(8)).png")
        }
        return candidate
    }
}
