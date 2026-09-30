import Foundation

/// The Library's settings (docs/RUN-UI-2.md K4): screenshots and scroll captures that were only
/// copied are kept in Camcord's own folder so the Library can show them — on by default, for 30
/// days, within 2 GB, oldest first out.
struct LibrarySettings: Equatable, Sendable {
    static let keepCopiedKey = "library.keepCopied"
    static let keepDaysKey = "library.keepDays"
    static let capBytesKey = "library.capBytes"

    static let dayChoices = [7, 30, 90, 365]
    static let capChoices: [Int64] = [512 << 20, 1 << 30, 2 << 30, 5 << 30, 10 << 30]

    var keepCopied = true
    var keepDays = 30
    var capBytes: Int64 = 2 << 30

    static func load(from defaults: UserDefaults) -> LibrarySettings {
        var settings = LibrarySettings()
        if defaults.object(forKey: keepCopiedKey) != nil { settings.keepCopied = defaults.bool(forKey: keepCopiedKey) }
        let days = defaults.integer(forKey: keepDaysKey)
        if days > 0 { settings.keepDays = days }
        let cap = (defaults.object(forKey: capBytesKey) as? NSNumber)?.int64Value ?? 0
        if cap > 0 { settings.capBytes = cap }
        return settings
    }

    func save(to defaults: UserDefaults) {
        defaults.set(keepCopied, forKey: Self.keepCopiedKey)
        defaults.set(keepDays, forKey: Self.keepDaysKey)
        defaults.set(NSNumber(value: capBytes), forKey: Self.capBytesKey)
    }

    /// Camcord's own folder for copied captures (K4).
    static func cacheDirectory(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Camcord/Captures", isDirectory: true)
    }
}
