import AVFoundation
import Foundation

/// Distinct in-process audio feedback using the original macOS system cues.
///
/// A fresh `AVAudioPlayer` is used for every cue so rapid actions can overlap. The
/// decoded AIFF bytes stay cached, and the bounded player pool retains each player
/// only until it finishes. In-process playback also preserves ScreenCaptureKit's
/// ability to exclude Camcord from the system-audio feed.
enum FeedbackSound: CaseIterable, Sendable {
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

    /// Exact pre-overhaul action-to-cue mapping. These are the familiar files in
    /// `/System/Library/Sounds`; playback uses their original content and volume.
    var systemSoundName: String {
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

    var systemSoundURL: URL {
        URL(fileURLWithPath: "/System/Library/Sounds/\(systemSoundName).aiff")
    }

    /// All legacy cues on the supported macOS release are shorter than this. The
    /// timeout prevents a broken route or missing completion callback from holding a
    /// start/resume gate indefinitely.
    static let maximumAwaitedPlaybackSeconds: TimeInterval = 2.5
    private static let recordingGateTail: Duration = .milliseconds(75)

    /// The one preference: a master on/off for all feedback sounds (default on).
    /// Key kept stable across versions (was the v1 "capture sound" toggle).
    static let enabledDefaultsKey = "captureSoundEnabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledDefaultsKey) == nil ? true : defaults.bool(forKey: enabledDefaultsKey)
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledDefaultsKey)
    }

    /// Plays immediately and returns. Callers are main-actor UX flows.
    @MainActor
    func play(in defaults: UserDefaults = .standard) {
        guard Self.isEnabled(in: defaults) else { return }
        FeedbackPlayer.shared.play(systemSoundName)
    }

    /// Plays one recording-boundary cue and waits for it to finish. Cancellation
    /// stops the player and returns promptly; failure to load/play is fail-open so a
    /// missing optional cue can never prevent recording.
    @MainActor
    func playAndWait(in defaults: UserDefaults = .standard) async {
        guard Self.isEnabled(in: defaults) else { return }
        let played = await FeedbackPlayer.shared.playAndWait(
            systemSoundName,
            maximumDuration: .seconds(Self.maximumAwaitedPlaybackSeconds)
        )
        guard played, !Task.isCancelled else { return }
        try? await Task.sleep(for: Self.recordingGateTail)
    }

    /// Warm the sound-data cache at launch so the first cue has no disk latency.
    @MainActor
    static func preloadAll() {
        for sound in Self.allCases {
            FeedbackPlayer.shared.warm(sound.systemSoundName)
        }
    }

    /// Internal media seam for exact asset/decode regression tests.
    @MainActor
    var audioData: Data {
        FeedbackPlayer.shared.data(for: systemSoundName) ?? Data()
    }
}

/// Main-actor ownership matches `AVAudioPlayer`'s delegate lifecycle. Each action
/// gets a fresh player; a strict cap prevents rapid-fire input retaining an
/// unbounded number of overlapping cues.
@MainActor
private final class FeedbackPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = FeedbackPlayer()
    private static let maximumActivePlayers = 8

    private var payloads: [String: Data] = [:]
    private var active: [AVAudioPlayer] = []
    private var waiters: [ObjectIdentifier: CheckedContinuation<Bool, Never>] = [:]
    private var timeouts: [ObjectIdentifier: Task<Void, Never>] = [:]

    func data(for name: String) -> Data? {
        if let cached = payloads[name] { return cached.isEmpty ? nil : cached }
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        // Cache misses as empty so a missing system file is not retried on every cue.
        let loaded = (try? Data(contentsOf: url)) ?? Data()
        payloads[name] = loaded
        return loaded.isEmpty ? nil : loaded
    }

    func warm(_ name: String) {
        _ = data(for: name)
    }

    func play(_ name: String) {
        guard let player = makePlayer(name) else { return }
        retain(player)
        guard player.play() else { finish(player, stopping: false, played: false); return }
    }

    func playAndWait(_ name: String, maximumDuration: Duration) async -> Bool {
        guard let player = makePlayer(name) else { return false }
        let wrapper = SendablePlayerWrapper(player: player)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                retain(player)
                let id = ObjectIdentifier(player)
                waiters[id] = continuation
                guard player.play() else {
                    finish(player, stopping: false, played: false)
                    return
                }
                timeouts[id] = Task { @MainActor [weak self, weak player] in
                    do {
                        try await Task.sleep(for: maximumDuration)
                    } catch {
                        return
                    }
                    guard let self, let player else { return }
                    self.finish(player, stopping: true, played: true)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(wrapper.player, stopping: true, played: false)
            }
        }
    }

    private func makePlayer(_ name: String) -> AVAudioPlayer? {
        guard let payload = data(for: name), let player = try? AVAudioPlayer(data: payload) else { return nil }
        player.delegate = self
        player.volume = 1
        player.prepareToPlay()
        return player
    }

    private func retain(_ player: AVAudioPlayer) {
        for stale in active.filter({ !$0.isPlaying }) {
            finish(stale, stopping: false, played: true)
        }
        while active.count >= Self.maximumActivePlayers, let oldest = active.first {
            finish(oldest, stopping: true, played: true)
        }
        active.append(player)
    }

    private func finish(_ player: AVAudioPlayer, stopping: Bool, played: Bool) {
        let id = ObjectIdentifier(player)
        if stopping { player.stop() }
        timeouts.removeValue(forKey: id)?.cancel()
        active.removeAll { $0 === player }
        waiters.removeValue(forKey: id)?.resume(returning: played)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let wrapper = SendablePlayerWrapper(player: player)
        Task { @MainActor [weak self] in
            self?.finish(wrapper.player, stopping: false, played: true)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let wrapper = SendablePlayerWrapper(player: player)
        Task { @MainActor [weak self] in
            self?.finish(wrapper.player, stopping: true, played: true)
        }
    }
}

private struct SendablePlayerWrapper: @unchecked Sendable {
    let player: AVAudioPlayer
}
