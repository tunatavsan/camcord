import AVFoundation
import Foundation

/// Distinct, instant, non-blocking audio feedback — one recognizable sound per action.
///
/// Plays IN-PROCESS via `AVAudioPlayer` (a fresh instance per cue). Two reasons:
///  • Rapid-fire safe — unlike `NSSound(named:)`, which hands back a SHARED instance
///    whose `play()` is a no-op while it's still sounding (so a second capture within a
///    cue's duration silently dropped), each cue here is its own player and always sounds.
///  • Recording-clean — because the audio originates from THIS process, a recording's
///    `SCStreamConfiguration.excludesCurrentProcessAudio` filters it out, so the beeps
///    the user hears never bleed into the captured video. (System-sound APIs play from a
///    system process and would leak into the recording.)
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
        FeedbackPlayer.shared.play(systemSoundName)
    }

    /// Warm the sound-data cache at launch so the first cue has zero disk latency.
    static func preloadAll() {
        for sound in [
            regionShot, windowShot, fullScreenShot, textOCR,
            recordStart, recordStop, recordPause, recordResume, paste, error,
        ] {
            FeedbackPlayer.shared.warm(sound.systemSoundName)
        }
    }
}

/// Caches decoded sound data and plays each cue on a fresh `AVAudioPlayer`, retained
/// until playback finishes. All playback is marshalled to the main run loop so the
/// player's completion delegate fires (and the instance is released) reliably, no matter
/// which thread — event tap, capture task, main — triggered the cue.
private final class FeedbackPlayer: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    static let shared = FeedbackPlayer()

    private let lock = NSLock()
    private var data: [String: Data] = [:]
    /// Players are held here for the lifetime of their playback so ARC doesn't reclaim
    /// them mid-sound; the completion delegate removes them.
    private var active: Set<AVAudioPlayer> = []

    func play(_ name: String) {
        guard let payload = soundData(for: name) else { return }
        DispatchQueue.main.async { [self] in
            guard let player = try? AVAudioPlayer(data: payload) else { return }
            player.delegate = self
            lock.lock()
            active.insert(player)
            lock.unlock()
            player.prepareToPlay()
            // If playback can't even start, the finish delegate never fires — release the
            // retained player now so it can't linger in `active`.
            if !player.play() {
                lock.lock()
                active.remove(player)
                lock.unlock()
            }
        }
    }

    func warm(_ name: String) {
        _ = soundData(for: name)
    }

    private func soundData(for name: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = data[name] { return cached }
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        // Cache the miss as empty too so a missing file can't retry on every call.
        let loaded = (try? Data(contentsOf: url)) ?? Data()
        data[name] = loaded
        return loaded.isEmpty ? nil : loaded
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        lock.lock()
        active.remove(player)
        lock.unlock()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        lock.lock()
        active.remove(player)
        lock.unlock()
    }
}
