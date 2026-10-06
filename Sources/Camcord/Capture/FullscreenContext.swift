import AppKit
import CoreGraphics
import os

/// What owns the display under the cursor. A fullscreen game covers the screen, often
/// sits above every panel level Camcord can reach, and may hold the display captured —
/// so an overlay or a picker there is invisible at best. Triggers in this context are routed
/// to UI-less captures, and the measurement is logged at every trigger so an in-game test run
/// says which failure class applies.
///
/// The decision is a pure function of the four measurements, so it can be table-tested;
/// `current()` is a thin live wrapper around it.
struct FullscreenContext: Equatable {
    let displayID: CGDirectDisplayID
    let frontmostBundleID: String?
    /// A window of the frontmost app covers the whole display.
    let coversDisplay: Bool
    /// `kCGWindowLayer` of that covering window (0 = normal window).
    let windowLayer: Int
    let displayCaptured: Bool
    /// The measurement the decision came out of, for the trigger log: the display and the
    /// candidate windows in ONE coordinate space at the SAME scale, so a points-vs-pixels
    /// mismatch or an empty frontmost window set is visible in the line instead of guessed.
    var survey: String = ""

    static let finderBundleID = "com.apple.finder"

    /// Another app covering the display outright. `windowLayer` and `displayCaptured`
    /// are carried for the trigger log — they say WHY nothing can be drawn — but they do
    /// not narrow the decision: covering the display is what makes our overlays useless.
    var isGameLike: Bool {
        guard coversDisplay, let frontmostBundleID else { return false }
        return frontmostBundleID != Bundle.main.bundleIdentifier
    }

    var logLine: String {
        let measurement = survey.isEmpty ? "" : " \(survey)"
        return "display=\(displayID) front=\(frontmostBundleID ?? "-") covers=\(coversDisplay) layer=\(windowLayer) captured=\(displayCaptured) game=\(isGameLike)\(measurement)"
    }

    /// Measures the display under `point` (AppKit global coordinates).
    @MainActor
    static func current(at point: CGPoint = NSEvent.mouseLocation) -> FullscreenContext {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let displayID = screen?.cgDirectDisplayID ?? CGMainDisplayID()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let displayBounds = CGDisplayBounds(displayID)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let cover = cover(
            in: windows,
            frontmostPID: frontmost?.processIdentifier,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            displayBounds: displayBounds
        )
        return FullscreenContext(
            displayID: displayID,
            frontmostBundleID: frontmost?.bundleIdentifier
                ?? cover?.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier },
            coversDisplay: cover != nil,
            windowLayer: cover?.layer ?? 0,
            // `CGDisplayIsCaptured` is unavailable in Swift; a captured display is the
            // one that owns a shielding window, which is exactly what the id reports.
            displayCaptured: CGShieldingWindowID(displayID) != kCGNullWindowID,
            survey: survey(in: windows, pid: frontmost?.processIdentifier, displayBounds: displayBounds,
                           source: cover?.source ?? "none")
        )
    }

    /// The same measurement for a surface the user reaches THROUGH Camcord (the window
    /// picker): clicking our panel makes Camcord frontmost, so `current()` would report
    /// ourselves and never see the game still covering the screen behind us. Reads the
    /// covering app off the window list's own front-to-back order instead.
    @MainActor
    static func covering(at point: CGPoint = NSEvent.mouseLocation) -> FullscreenContext {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let displayID = screen?.cgDirectDisplayID ?? CGMainDisplayID()
        let displayBounds = CGDisplayBounds(displayID)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let covering = firstCovering(
            in: windows,
            excludingPID: ProcessInfo.processInfo.processIdentifier,
            displayBounds: displayBounds
        )
        return FullscreenContext(
            displayID: displayID,
            frontmostBundleID: covering.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier },
            coversDisplay: covering != nil,
            windowLayer: covering?.layer ?? 0,
            displayCaptured: CGShieldingWindowID(displayID) != kCGNullWindowID,
            survey: survey(in: windows, pid: covering?.pid, displayBounds: displayBounds,
                           source: covering != nil ? "list" : "none")
        )
    }

    /// The cover read behind `current()`, pure over the window list so the Valheim case can
    /// be tested without a game on screen. The frontmost app answers first. When it owns no
    /// covering window the list's own front-to-back order answers instead: a game running
    /// under a translation layer registers ONE app with the Dock and draws from ANOTHER
    /// process, so the frontmost PID owned nothing and a full screen of game reported
    /// `covers=false layer=0`.
    static func cover(
        in list: [[String: Any]],
        frontmostPID: pid_t?,
        ownPID: pid_t,
        displayBounds: CGRect
    ) -> (layer: Int, pid: pid_t?, source: String)? {
        if let frontmostPID,
           let layer = coveringLayer(in: list, pid: frontmostPID, displayBounds: displayBounds) {
            return (layer, frontmostPID, "front")
        }
        if let fallback = firstCovering(in: list, excludingPID: ownPID, displayBounds: displayBounds) {
            return (fallback.layer, fallback.pid, "list")
        }
        return nil
    }

    /// `kCGWindowLayer` of the frontmost app's first on-screen window that contains the
    /// display's bounds. Fully transparent windows and Finder's desktop are not cover.
    /// Pure over the window list so the filtering itself is testable with fake dictionaries.
    /// The frontmost app is trusted at ANY level: it is in front, so whatever it draws over
    /// the display is what the user is looking at.
    static func coveringLayer(in list: [[String: Any]], pid: pid_t, displayBounds: CGRect) -> Int? {
        for window in list where window[kCGWindowOwnerPID as String] as? pid_t == pid {
            if let layer = layerIfCovering(window, displayBounds: displayBounds) { return layer }
        }
        return nil
    }

    /// The frontmost covering window that is NOT ours, in the list's own z-order, and NOT
    /// system chrome. Measured on this machine: the Dock owns a full-display window at
    /// level 20, the Window Server one at 24 and Control Center a row at 25 — reading any
    /// of those as cover would declare a fullscreen game every time the app in front
    /// happened to own no full-display window of its own. Ordinary application content
    /// lives below the Dock's level; a wallpaper or desktop agent sits below zero.
    static let ordinaryLayers = 0..<Int(CGWindowLevelForKey(.dockWindow))

    static func firstCovering(
        in list: [[String: Any]],
        excludingPID: pid_t,
        displayBounds: CGRect
    ) -> (pid: pid_t, layer: Int)? {
        for window in list {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != excludingPID else { continue }
            guard let layer = layerIfCovering(window, displayBounds: displayBounds) else { continue }
            if ordinaryLayers.contains(layer) { return (pid, layer) }
        }
        return nil
    }

    /// A fullscreen-exclusive app can report its window in backing PIXELS while
    /// `CGDisplayBounds` is in points, so the same full-screen window reads as 2x or 3x the
    /// display and — off the main display, where the origin is scaled too — misses the
    /// containment test entirely. Dividing by the scale can only ever shrink a window, so a
    /// window measured in points is unaffected and 1 keeps the original comparison.
    private static let coverScales: [CGFloat] = [1, 2, 3]

    private static func layerIfCovering(_ window: [String: Any], displayBounds: CGRect) -> Int? {
        if let owner = window[kCGWindowOwnerName as String] as? String, owner == "Finder" { return nil }
        if let alpha = window[kCGWindowAlpha as String] as? Double, alpha == 0 { return nil }
        guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              coverScales.contains(where: { scale in
                  CGRect(x: bounds.minX / scale, y: bounds.minY / scale,
                         width: bounds.width / scale, height: bounds.height / scale)
                      .insetBy(dx: -2, dy: -2).contains(displayBounds)
              }) else { return nil }
        return window[kCGWindowLayer as String] as? Int ?? 0
    }

    /// The evidence behind `coversDisplay`, on one line: the display, how many windows the
    /// frontmost app owns on screen, and the first few candidates with their bounds, layer
    /// and alpha — all in CoreGraphics points, top-left origin, unscaled. `cover` says which
    /// read decided: the frontmost PID's own windows, the list's z-order, or neither.
    static func survey(
        in list: [[String: Any]],
        pid: pid_t?,
        displayBounds: CGRect,
        source: String,
        limit: Int = 3
    ) -> String {
        let owned = pid.map { pid in
            list.filter { $0[kCGWindowOwnerPID as String] as? pid_t == pid }
        } ?? []
        let rows = (owned.isEmpty ? Array(list.prefix(limit)) : Array(owned.prefix(limit))).map(row)
        return "cover=\(source) bounds=\(rectLine(displayBounds)) front=\(owned.count)/\(list.count)"
            + " [\(rows.joined(separator: " | "))]"
    }

    private static func row(_ window: [String: Any]) -> String {
        let owner = window[kCGWindowOwnerName as String] as? String ?? "-"
        let pid = window[kCGWindowOwnerPID as String] as? pid_t ?? -1
        let layer = window[kCGWindowLayer as String] as? Int ?? 0
        let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
        let bounds = (window[kCGWindowBounds as String] as? [String: Any])
            .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
        return "\(owner)/\(pid) layer=\(layer) alpha=\(String(format: "%.2f", alpha)) win=\(rectLine(bounds))"
    }

    private static func rectLine(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
    }
}

/// A game-like context owns the display and sits above every ordinary panel
/// level, so Camcord's own transient surfaces have to be raised to the shielding level to be
/// seen at all. The flag lives next to the measurement that decides it because more than one
/// surface reads it — the camera tile, its shadow, the HUD toast — and each reads it as it
/// orders itself in, so leaving the game restores the ordinary level with no extra teardown.
@MainActor
enum GameOverlayElevation {
    /// Above a fullscreen game's own window, and above the shielding window of a captured
    /// display — the highest level AppKit will hand out.
    static let shieldingLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    /// `show()` has already ordered the panels in, so 50 ms later the tile is either on
    /// screen or something is over it. Short enough to stay inside the same gesture.
    static let probeDelay = Duration.milliseconds(50)

    private(set) static var isActive = false

    static func set(_ active: Bool) { isActive = active }

    static func level(base: NSWindow.Level) -> NSWindow.Level { isActive ? shieldingLevel : base }

    /// The level for a surface that appears once and goes — a toast. The camera tile holds
    /// the flag only while it is on screen, so a toast cannot ride on it: with the preview
    /// closed a confirmation inside a game would sit under the game, which is the exact
    /// failure this exists to prevent. `covering(at:)` rather than `current()`, because
    /// showing a toast may follow a click on our own panel, which makes Camcord frontmost.
    static func levelForPassingSurface(base: NSWindow.Level, at point: CGPoint) -> NSWindow.Level {
        isActive || FullscreenContext.covering(at: point).isGameLike ? shieldingLevel : base
    }

    /// Raise when the context says a game owns the display, or when the panel we just put up
    /// is not on screen — the second is the measurement, the first is the prediction.
    static func shouldElevate(gameLike: Bool, probeVisible: Bool) -> Bool { gameLike || !probeVisible }

    static func logLine(surface: String, visible: Bool, level: NSWindow.Level) -> String {
        "\(surface).visible=\(visible) level=\(level.rawValue)"
    }
}

/// One line per trigger, so a run inside a fullscreen game says whether the trigger
/// reached us at all (Class A) and, if it did, what was in front of it (Class B).
/// The installed app's `os_log` lines are not retrievable with `log show`, so every line
/// also goes to `~/Library/Logs/Camcord/diagnostics.log` — that file is what to read after
/// an in-game trigger test.
enum TriggerLog {
    private static let logger = Logger(subsystem: "dev.tavsan.camcord", category: "trigger")

    /// Returns the measured context so a caller that routes on it (the record hotkey's
    /// game path) does not pay for a second window-list sweep.
    @MainActor
    @discardableResult
    static func fired(_ source: String) -> FullscreenContext {
        let context = FullscreenContext.current()
        let line = "trigger source=\(source) \(context.logLine)"
        logger.notice("\(line, privacy: .public)")
        DiagnosticsLog.append(line)
        return context
    }

    static func overlay(_ message: String) {
        logger.notice("overlay \(message, privacy: .public)")
        DiagnosticsLog.append("overlay \(message)")
    }
}
