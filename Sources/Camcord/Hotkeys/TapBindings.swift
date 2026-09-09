import Foundation

/// What a Tier-2 (mouse button / double-tap) binding can trigger.
enum TapAction: String, Codable, CaseIterable {
    case captureRegion
    /// Mouse buttons only: hold the button, drag out the region while holding,
    /// release to shoot — one continuous gesture instead of press-then-click-drag.
    /// A tap-then-hold variant of the same button OCRs the region instead (see
    /// `HoldGestureDetector`). Meaningless for the double-tap gesture (no held phase).
    case holdCaptureRegion
    /// Mouse buttons only: a CAPTURE MODIFIER. Hold this button, then:
    ///   • drag with the LEFT mouse button → region screenshot,
    ///   • drag with the RIGHT mouse button → region OCR,
    ///   • release without dragging (a plain tap) → open the region-select overlay.
    /// While held it intercepts left/right mouse so those clicks drive capture, not the
    /// app underneath. Meaningless for the double-tap gesture (no held phase).
    case captureModifier
    /// Paste the clipboard into the focused app (synthesized Cmd+V) — so an image or
    /// text lands without reaching for Cmd+V.
    case paste
    case toggleRecording
}

/// Whether a hold-to-capture gesture shoots a screenshot or OCRs the region. Shared
/// between the gesture detector and the capture coordinator.
enum HoldCaptureMode: Equatable {
    case screenshot
    case text
}

/// User-configurable Tier-2 bindings: mouse buttons (wheel + two side buttons) and the
/// double-tap Right ⌘ gesture. Persisted as JSON in `UserDefaults` (an injectable suite,
/// so tests never touch the user's real defaults) under `TapBindings.defaultsKey`.
///
/// Naming: UI "button N" maps to CGEvent button (N-1) — UI 3 = wheel (CG 2), UI 4 =
/// CG 3, UI 5 = CG 4.
struct TapBindings: Codable, Equatable {
    var mouseButton3: TapAction?
    var mouseButton4: TapAction?
    var mouseButton5: TapAction?
    var doubleTapRightCommand: TapAction?

    static let defaultsKey = "tapBindings"

    init(
        mouseButton3: TapAction? = nil,
        mouseButton4: TapAction? = .paste,
        mouseButton5: TapAction? = .captureModifier,
        doubleTapRightCommand: TapAction? = nil
    ) {
        self.mouseButton3 = mouseButton3
        self.mouseButton4 = mouseButton4
        self.mouseButton5 = mouseButton5
        self.doubleTapRightCommand = doubleTapRightCommand
    }

    var anyEnabled: Bool {
        mouseButton3 != nil || mouseButton4 != nil || mouseButton5 != nil || doubleTapRightCommand != nil
    }

    /// The pre-modifier default set — migrated forward so a user who never customized
    /// their mouse buttons picks up the new capture-modifier model automatically.
    private static let legacyDefault = TapBindings(
        mouseButton3: .paste, mouseButton4: .captureRegion,
        mouseButton5: .holdCaptureRegion, doubleTapRightCommand: nil
    )

    /// Returns the persisted bindings, or the defaults if the key is absent or
    /// undecodable.
    static func load(from defaults: UserDefaults) -> TapBindings {
        let hasMigrated = defaults.bool(forKey: "hasMigratedV2")
        guard
            let data = defaults.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(TapBindings.self, from: data)
        else {
            defaults.set(true, forKey: "hasMigratedV2")
            return TapBindings()
        }
        if !hasMigrated {
            defaults.set(true, forKey: "hasMigratedV2")
            if decoded == legacyDefault {
                return TapBindings()
            }
        }
        return decoded
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Pure state machine that disambiguates a hold-to-capture button's two gestures:
///   • press + hold + drag → SCREENSHOT the region
///   • tap (quick press/release, no drag) then press + hold + drag → OCR the region
/// The mode is decided at press time (was there a recent tap?); the caller reports on
/// release whether a drag actually happened so a plain tap arms the next press for OCR.
/// No clock calls — timestamps are supplied, so it's fully unit-testable.
struct HoldGestureDetector {
    /// Max gap from a tap's release to the next press for it to count as tap-then-hold.
    static let tapWindow: TimeInterval = 0.4

    private var lastTapButton: Int64?
    private var lastTapReleaseTime: TimeInterval?

    /// Call on button DOWN; returns the mode for the hold that may follow. The tap and
    /// the hold must be the SAME button — a tap on one bound button never arms OCR for
    /// a different button's next hold.
    mutating func modeForPress(button: Int64, at time: TimeInterval) -> HoldCaptureMode {
        let mode: HoldCaptureMode
        if lastTapButton == button, let last = lastTapReleaseTime, time - last <= Self.tapWindow {
            mode = .text
        } else {
            mode = .screenshot
        }
        lastTapButton = nil  // consumed / a stale tap never carries over
        lastTapReleaseTime = nil
        return mode
    }

    /// Call on button UP. `dragged` = whether the press produced a drag. A no-drag
    /// release is a tap and arms the OCR window for that button's next press.
    mutating func registerRelease(button: Int64, dragged: Bool, at time: TimeInterval) {
        if dragged {
            lastTapButton = nil
            lastTapReleaseTime = nil
        } else {
            lastTapButton = button
            lastTapReleaseTime = time
        }
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
