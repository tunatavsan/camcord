import AppKit

/// The optional "capture succeeded" sound. A user preference (default on) because a
/// clipboard-only workflow has no other visible confirmation that the shot landed.
/// Deliberately nonisolated: `UserDefaults` is thread-safe and `NSSound.play` is
/// callable from any thread, and `SettingsView.init` (nonisolated) reads `isEnabled`.
enum CaptureFeedback {
    static let defaultsKey = "captureSoundEnabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil ? true : defaults.bool(forKey: defaultsKey)
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }

    /// Short, unobtrusive system sound ("Pop") -- the classic shutter sound is a
    /// private asset, and anything longer gets annoying at screenshot frequency.
    static func playCaptureSound(in defaults: UserDefaults = .standard) {
        guard isEnabled(in: defaults) else { return }
        NSSound(named: "Pop")?.play()
    }

    /// A recording finishing is a different event than a screenshot landing -- give
    /// it a distinct sound so the two clipboard writes are distinguishable by ear.
    static func playRecordingStopSound(in defaults: UserDefaults = .standard) {
        guard isEnabled(in: defaults) else { return }
        NSSound(named: "Glass")?.play()
    }
}
