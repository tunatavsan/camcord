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
    /// Consecutive warm-up (buffered / forced-baseline) frames since the last real advance
    /// or flip. A CORRECT scroll commits within a couple of frames, so a short warm-up run
    /// is normal; a WRONG direction produces an ENDLESS warm-up (nothing ever moves), so
    /// past the grace we stop treating warm-up as progress and let it drive the flip.
    private var warmupStreak = 0

    /// Consecutive stalled frames, BEFORE any advance, that mean the direction is wrong.
    let flipThreshold: Int
    /// Consecutive stalled frames, AFTER advancing, that mean the bottom was reached.
    let endThreshold: Int
    /// How many leading warm-up frames are tolerated as "still starting up" before they
    /// count as stalls. Keeps a correct scroll (which commits fast) from ever flipping,
    /// while stopping a wrong direction from hiding behind the stitcher's ~7-frame buffer.
    let warmupGrace: Int

    init(flipThreshold: Int = 4, endThreshold: Int = 4, warmupGrace: Int = 2) {
        self.flipThreshold = flipThreshold
        self.endThreshold = endThreshold
        self.warmupGrace = warmupGrace
    }

    /// Feed one capture outcome. `advanced` = the stitch grew (a real downward move);
    /// `warmup` = the stitcher buffered a frame without committing yet.
    mutating func record(advanced: Bool, warmup: Bool) -> Decision {
        if advanced {
            advancedEver = true
            stallStreak = 0
            warmupStreak = 0
            return .keepScrolling
        }
        if warmup {
            warmupStreak += 1
            // Within the grace window, warm-up is progress and can't stall/flip.
            if warmupStreak <= warmupGrace {
                stallStreak = 0
                return .keepScrolling
            }
            // Beyond it, fall through and count this warm-up frame as a stall — a wrong
            // direction looks exactly like a warm-up that never commits.
        } else {
            warmupStreak = 0
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
        warmupStreak = 0   // the corrected direction gets its own fresh warm-up grace
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

    /// Persists the wheel-delta sign that was PROVEN to scroll pages downward on this Mac
    /// (it depends on the "natural scrolling" setting, which we can't reliably read for
    /// synthesized events). Seeded from here so the very first auto-scroll of every later
    /// session starts in the right direction instead of re-learning it each time.
    static let directionDefaultsKey = "scrollCaptureWheelDirection"

    /// Called each tick with the scroll amount since the last tick (always > 0), in the same
    /// point unit `NSEvent.scrollingDeltaY` reports, so the session feeds the stitcher
    /// exactly as a real wheel event would.
    var onTick: ((CGFloat) -> Void)?

    private var timer: DispatchSourceTimer?
    private let source = CGEventSource(stateID: .hidSystemState)
    /// Sign of the wheel delta. `-1` reveals content further down on a default Mac; seeded
    /// from the last PROVEN-good direction (see `directionDefaultsKey`) and flipped once by
    /// the session if the page turns out to move the other way.
    private var direction: Int32 = {
        let saved = UserDefaults.standard.integer(forKey: AutoScroller.directionDefaultsKey)
        return saved == 0 ? -1 : Int32(saved)   // 0 = unset → default
    }()
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
    /// don't advance the page). Not persisted — only a direction that actually advances the
    /// page (see `confirmDirection`) is trustworthy enough to remember.
    func flipDirection() {
        direction = -direction
        rampTick = 0
    }

    /// Called once the stitch actually grew under the current direction — proof this sign
    /// scrolls pages DOWNWARD here (scrolling up never advances the downward stitcher). Saved
    /// so future sessions skip the wrong-direction detour entirely. Idempotent / cheap.
    func confirmDirection() {
        UserDefaults.standard.set(Int(direction), forKey: Self.directionDefaultsKey)
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
