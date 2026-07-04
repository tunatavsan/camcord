import AudioToolbox
import Foundation

/// Distinct, instant, non-blocking audio feedback — one recognizable sound per action.
///
/// Uses AudioServices (fire-and-forget, plays on a system thread) rather than
/// `NSSound`: `NSSound(named:)` hands back a SHARED cached instance whose `play()`
/// is a no-op while that instance is still playing, so two captures within a sound's
/// duration silently dropped the second cue. `AudioServicesPlaySystemSound` has no
/// such state — every call plays, even overlapping, which is exactly what a
/// rapid-fire screenshot workflow needs.
enum FeedbackSound {
    case regionShot
    case windowShot
    case fullScreenShot
    case textOCR
    case recordStart
    case recordStop
    case recordPause
    case recordResume
    case paste
    case error

    /// A built-in system sound (from `/System/Library/Sounds`) chosen to be
    /// distinguishable by ear from its neighbours. Zero bundled assets.
    fileprivate var systemSoundName: String {
        switch self {
        case .regionShot: "Pop"
        case .windowShot: "Bottle"
        case .fullScreenShot: "Funk"
        case .textOCR: "Morse"
        case .recordStart: "Hero"
        case .recordStop: "Glass"
        case .recordPause: "Tink"
        case .recordResume: "Purr"
        case .paste: "Frog"
        case .error: "Basso"
        }
    }

    /// The one preference: a master on/off for all feedback sounds (default on).
    /// Key kept stable across versions (was the v1 "capture sound" toggle).
    static let enabledDefaultsKey = "captureSoundEnabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledDefaultsKey) == nil ? true : defaults.bool(forKey: enabledDefaultsKey)
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledDefaultsKey)
    }

    /// Plays the cue immediately (no-op when feedback is disabled). Non-blocking.
    func play(in defaults: UserDefaults = .standard) {
        guard Self.isEnabled(in: defaults) else { return }
        FeedbackPlayer.shared.play(self)
    }

    /// Warm the SystemSoundID cache at launch so the first cue has zero setup latency.
    static func preloadAll() {
        for sound in [
            regionShot, windowShot, fullScreenShot, textOCR,
            recordStart, recordStop, recordPause, recordResume, paste, error,
        ] {
            FeedbackPlayer.shared.warm(sound.systemSoundName)
        }
    }
}

/// Preloads and caches `SystemSoundID`s. AudioServices IDs are process-global integer
/// handles that are safe to play from any thread; the only shared mutable state is the
/// name→id cache, guarded by a lock.
private final class FeedbackPlayer: @unchecked Sendable {
    static let shared = FeedbackPlayer()

    private let lock = NSLock()
    private var ids: [String: SystemSoundID] = [:]

    func play(_ sound: FeedbackSound) {
        let id = soundID(for: sound.systemSoundName)
        guard id != 0 else { return }
        AudioServicesPlaySystemSound(id)
    }

    func warm(_ name: String) {
        _ = soundID(for: name)
    }

    private func soundID(for name: String) -> SystemSoundID {
        lock.lock()
        defer { lock.unlock() }
        if let id = ids[name] { return id }
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff") as CFURL
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url, &id) == noErr else { return 0 }
        ids[name] = id
        return id
    }
}
