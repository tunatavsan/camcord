import CoreGraphics
import Foundation

/// Decides, from the stitcher's per-frame outcomes, whether an auto-scroll should keep
/// going, reverse direction, or stop because the page bottom was reached. Pure and
/// clock-free so it's fully unit-testable.
struct AutoScrollProgress: Equatable {
    enum Decision: Equatable {
        case keepScrolling
        case flipDirection
        case reachedEnd
    }

    private var advancedEver = false
    private var flipped = false
    private var stallStreak = 0
    mutating func record(_ motion: ScrollStitcher.Motion) -> Decision {
        switch motion {
        case .down:
            advancedEver = true
            stallStreak = 0
            return .keepScrolling
        case .up:
            // Once the run has advanced, an upward frame is the rubber band springing back
            // off the bottom — the page end, not a wrong direction. Stop immediately, or the
            // next posted ticks stitch that bottom a second and third time.
            if advancedEver { return .reachedEnd }
        case .none:
            stallStreak += 1
            // Two stalled frames are enough: the direction is measured at calibration, so a
            // stall after advancing can only mean the page stopped moving.
            guard stallStreak >= 2 else { return .keepScrolling }
            if advancedEver { return .reachedEnd }
        }
        if flipped { return .reachedEnd }
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

    /// Persists the wheel-delta sign that was PROVEN to scroll pages downward on this Mac
    /// (it depends on the "natural scrolling" setting, which we can't reliably read for
    /// synthesized events). Seeded from here so the very first auto-scroll of every later
    /// session starts in the right direction instead of re-learning it each time.
    static let directionDefaultsKey = "scrollCaptureWheelDirection.v3"

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
    /// Last sign written to UserDefaults by `confirmDirection`, to keep a long auto run
    /// from rewriting the identical value once per frame.
    private var persistedDirection: Int32?
    private var burstPoints: CGFloat?
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
    func start(at point: CGPoint, region: CGRect, burstPoints: CGFloat? = nil) {
        stop()
        rampTick = 0
        self.burstPoints = burstPoints
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
        persistedDirection = nil
    }

    /// Persist only after a measured downward motion under the current wheel sign. Called
    /// once per stitched frame, so it writes only when the stored sign actually changes.
    func confirmDirection() {
        guard persistedDirection != direction else { return }
        persistedDirection = direction
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
        let peak = burstPoints.map { $0 * 2 / CGFloat(Self.rampTicks + 1) } ?? Self.pixelsPerTick
        let magnitude = max(1, (peak * ease).rounded())
        let wheel1 = direction * Int32(magnitude)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel, wheelCount: 1,
            wheel1: wheel1, wheel2: 0, wheel3: 0
        ) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.echoSentinel)
        event.post(tap: .cghidEventTap)
        onTick?(magnitude)
        if burstPoints != nil, rampTick == Self.rampTicks { stop() }
    }
}
