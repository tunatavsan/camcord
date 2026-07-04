import CoreGraphics
import Foundation

/// Decides, from the stitcher's per-frame outcomes, whether an auto-scroll should keep
/// going, reverse direction, or stop because the page bottom was reached. Pure and
/// clock-free so it's fully unit-testable.
///
/// The direction is unknown up front (it depends on the user's "natural scrolling"
/// setting), so we start scrolling one way and watch: if the page never advances after a
/// few frames, the direction was wrong → flip once. If it advanced and then stops
/// advancing for a few frames, we've hit the bottom → stop. Warm-up frames (the stitcher
/// buffering before it commits a baseline) count as progress, not a stall.
struct AutoScrollProgress: Equatable {
    enum Decision: Equatable {
        case keepScrolling
        case flipDirection
        case reachedEnd
    }

    private var advancedEver = false
    private var flipped = false
    private var stallStreak = 0

    /// Consecutive stalled frames, BEFORE any advance, that mean the direction is wrong.
    let flipThreshold: Int
    /// Consecutive stalled frames, AFTER advancing, that mean the bottom was reached.
    let endThreshold: Int

    init(flipThreshold: Int = 4, endThreshold: Int = 4) {
        self.flipThreshold = flipThreshold
        self.endThreshold = endThreshold
    }

    /// Feed one capture outcome. `advanced` = the stitch grew (a real downward move);
    /// `warmup` = the stitcher buffered a frame without committing yet.
    mutating func record(advanced: Bool, warmup: Bool) -> Decision {
        if warmup {
            stallStreak = 0
            return .keepScrolling
        }
        if advanced {
            advancedEver = true
            stallStreak = 0
            return .keepScrolling
        }
        stallStreak += 1
        if advancedEver {
            return stallStreak >= endThreshold ? .reachedEnd : .keepScrolling
        }
        // Never advanced yet: a sustained stall means we're scrolling the wrong way.
        guard stallStreak >= flipThreshold else { return .keepScrolling }
        if flipped { return .reachedEnd }   // both directions failed → give up
        flipped = true
        stallStreak = 0
        return .flipDirection
    }
}

/// Synthesizes smooth, pixel-precise scrolling on whatever window sits under a point, so a
/// scrolling capture can advance the page by itself. Posts `.pixel`-unit wheel events at
/// ~60 Hz with a short ease-in; pixel wheel events carry no gesture phase, so they never
/// spin up the inertial momentum that made earlier synthesized-scroll attempts
/// uncontrollable. Requires Accessibility (like the app's event tap) for the events to
/// reach other apps — the caller checks that before starting.
@MainActor
final class AutoScroller {
    /// Stamped onto every synthesized event's `.eventSourceUserData` field so the session's
    /// global scroll monitor can recognize (and drop) our own events when they echo back,
    /// by identity rather than timing. Arbitrary non-zero marker ("CMCD").
    static let echoSentinel: Int64 = 0x434D_4344

    /// Called each tick with the scroll amount since the last tick (always > 0), in the same
    /// point unit `NSEvent.scrollingDeltaY` reports, so the session feeds the stitcher
    /// exactly as a real wheel event would.
    var onTick: ((CGFloat) -> Void)?

    private var timer: DispatchSourceTimer?
    private let source = CGEventSource(stateID: .hidSystemState)
    /// Sign of the wheel delta. `-1` reveals content further down on a default Mac; flipped
    /// once by the session if the page turns out to move the other way.
    private var direction: Int32 = -1
    private var rampTick = 0
    /// The area the scroll must land in; if the cursor wanders out we PAUSE posting (rather
    /// than blast scroll into whatever window is now under the pointer) and resume when it
    /// returns — so reaching for the HUD's stop button never scrolls another app.
    private var region: CGRect = .zero

    private static let hz = 60.0
    private static let pixelsPerTick: CGFloat = 11    // ~660 pt/s at full speed
    private static let rampTicks = 10                 // ~0.16 s ease-in
    private static let strayTolerance: CGFloat = 4    // pt of slack around the region edge

    var isRunning: Bool { timer != nil }

    /// Parks the cursor over `point` (so the wheel events land on the intended window) and
    /// begins posting after a brief delay. The region is captured cursor-free, so parking
    /// the pointer inside it can't taint the shot.
    func start(at point: CGPoint, region: CGRect) {
        stop()
        rampTick = 0
        self.region = region
        CGWarpMouseCursorPosition(point)
        let t = DispatchSource.makeTimerSource(queue: .main)
        // Small lead-in so the cursor warp settles before the first event.
        t.schedule(deadline: .now() + .milliseconds(80), repeating: 1.0 / Self.hz)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Reverses scroll direction and restarts the ease-in (used once if the first frames
    /// don't advance the page).
    func flipDirection() {
        direction = -direction
        rampTick = 0
    }

    private func tick() {
        // Pause (skip this tick) while the pointer is off the target — e.g. the user is
        // reaching for the HUD's stop button — so we never scroll an unrelated window.
        // Posting resumes automatically when the cursor returns to the region.
        if let here = CGEvent(source: nil)?.location,
           !region.insetBy(dx: -Self.strayTolerance, dy: -Self.strayTolerance).contains(here) {
            return
        }
        rampTick = min(rampTick + 1, Self.rampTicks)
        let ease = CGFloat(rampTick) / CGFloat(Self.rampTicks)
        let magnitude = max(1, (Self.pixelsPerTick * ease).rounded())
        let wheel1 = direction * Int32(magnitude)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel, wheelCount: 1,
            wheel1: wheel1, wheel2: 0, wheel3: 0
        ) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.echoSentinel)
        event.post(tap: .cghidEventTap)
        onTick?(magnitude)
    }
}
