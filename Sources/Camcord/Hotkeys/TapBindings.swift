import Foundation

/// v1 surface for what a Tier-2 (mouse button / double-tap) binding can trigger.
enum TapAction: String, Codable, CaseIterable {
    case captureRegion
    case toggleRecording
}

/// User-configurable Tier-2 bindings: mouse side buttons and the double-tap Right ⌘
/// gesture. Persisted as JSON in `UserDefaults` (an injectable suite, so tests never
/// touch the user's real defaults) under `TapBindings.defaultsKey`.
struct TapBindings: Codable, Equatable {
    var mouseButton4: TapAction?
    var mouseButton5: TapAction?
    var doubleTapRightCommand: TapAction?

    static let defaultsKey = "tapBindings"

    init(
        mouseButton4: TapAction? = .captureRegion,
        mouseButton5: TapAction? = nil,
        doubleTapRightCommand: TapAction? = nil
    ) {
        self.mouseButton4 = mouseButton4
        self.mouseButton5 = mouseButton5
        self.doubleTapRightCommand = doubleTapRightCommand
    }

    var anyEnabled: Bool {
        mouseButton4 != nil || mouseButton5 != nil || doubleTapRightCommand != nil
    }

    /// Returns the persisted bindings, or the defaults if the key is absent or
    /// undecodable.
    static func load(from defaults: UserDefaults) -> TapBindings {
        guard
            let data = defaults.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(TapBindings.self, from: data)
        else {
            return TapBindings()
        }
        return decoded
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Input events the double-tap state machine reacts to. `otherKeyDown` covers any
/// non-Right-Command key going down (e.g. the "C" in a Cmd+C chord) and resets the
/// sequence per the M2 brief -- so two quick Cmd+C's never look like a double-tap.
enum TapKeyEvent {
    case rightCmdDown
    case rightCmdUp
    case otherKeyDown
}

/// Pure state machine detecting a "double-tap Right Command" gesture: two complete
/// press-release taps of Right ⌘, with the second press starting within 350ms of the
/// first, and no other key going down in between. No Foundation date calls -- the
/// caller supplies the timestamp, so this is fully unit-testable without a real clock.
struct DoubleTapDetector {
    /// Max interval, in seconds, from the first press to the second press.
    static let maxInterval: TimeInterval = 0.35

    private enum State {
        /// No press seen yet (or the sequence was reset).
        case idle
        /// Right ⌘ is currently held down, waiting for its release to complete tap 1.
        case firstDown
        /// Tap 1 completed (pressed then released) at `pressTime`; waiting for a second
        /// press within `maxInterval`.
        case firstComplete(pressTime: TimeInterval)
        /// Right ⌘ is down again, within the window of tap 1 -- waiting for release to
        /// complete the double-tap.
        case secondDown
    }

    private var state: State = .idle
    private var firstPressTime: TimeInterval = 0

    mutating func handle(event: TapKeyEvent, at time: TimeInterval) -> Bool {
        switch (state, event) {
        case (.idle, .rightCmdDown):
            firstPressTime = time
            state = .firstDown
            return false

        case (.idle, .rightCmdUp), (.idle, .otherKeyDown):
            return false

        case (.firstDown, .rightCmdDown):
            // Key-repeat or a stray extra down with no release yet -- still one press.
            return false

        case (.firstDown, .rightCmdUp):
            state = .firstComplete(pressTime: firstPressTime)
            return false

        case (.firstDown, .otherKeyDown):
            state = .idle
            return false

        case (.firstComplete(let pressTime), .rightCmdDown):
            if time - pressTime <= Self.maxInterval {
                state = .secondDown
            } else {
                // Window elapsed -- this press becomes a fresh tap 1.
                firstPressTime = time
                state = .firstDown
            }
            return false

        case (.firstComplete, .rightCmdUp):
            // Stray release with no matching down; ignore.
            return false

        case (.firstComplete, .otherKeyDown):
            state = .idle
            return false

        case (.secondDown, .rightCmdUp):
            state = .idle
            return true

        case (.secondDown, .rightCmdDown):
            // Key-repeat; stay put.
            return false

        case (.secondDown, .otherKeyDown):
            state = .idle
            return false
        }
    }
}
