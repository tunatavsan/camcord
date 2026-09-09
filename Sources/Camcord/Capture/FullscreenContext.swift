import AppKit
import CoreGraphics
import os

/// What owns the display under the cursor. A fullscreen game covers the screen, often
/// sits above every panel level Camcord can reach, and may hold the display captured —
/// so an overlay or a picker there is invisible at best. Phase G routes triggers in this
/// context to UI-less captures; G.1 logs the measurement at every trigger so the owner's
/// LoL run says which failure class applies.
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

    static let finderBundleID = "com.apple.finder"

    /// Another app covering the display outright. `windowLayer` and `displayCaptured`
    /// are carried for the trigger log — they say WHY nothing can be drawn — but they do
    /// not narrow the decision: covering the display is what makes our overlays useless.
    var isGameLike: Bool {
        guard coversDisplay, let frontmostBundleID else { return false }
        return frontmostBundleID != Bundle.main.bundleIdentifier
    }

    var logLine: String {
        "display=\(displayID) front=\(frontmostBundleID ?? "-") covers=\(coversDisplay) layer=\(windowLayer) captured=\(displayCaptured) game=\(isGameLike)"
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
        let covering = frontmost.flatMap {
            coveringLayer(in: windows, pid: $0.processIdentifier, displayBounds: displayBounds)
        }
        return FullscreenContext(
            displayID: displayID,
            frontmostBundleID: frontmost?.bundleIdentifier,
            coversDisplay: covering != nil,
            windowLayer: covering ?? 0,
            // `CGDisplayIsCaptured` is unavailable in Swift; a captured display is the
            // one that owns a shielding window, which is exactly what the id reports.
            displayCaptured: CGShieldingWindowID(displayID) != kCGNullWindowID
        )
    }

    /// The same measurement for a surface the owner reaches THROUGH Camcord (the window
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
            displayCaptured: CGShieldingWindowID(displayID) != kCGNullWindowID
        )
    }

    /// `kCGWindowLayer` of the frontmost app's first on-screen window that contains the
    /// display's bounds. Fully transparent windows and Finder's desktop are not cover.
    /// Pure over the window list so the filtering itself is testable with fake dictionaries.
    static func coveringLayer(in list: [[String: Any]], pid: pid_t, displayBounds: CGRect) -> Int? {
        for window in list where window[kCGWindowOwnerPID as String] as? pid_t == pid {
            if let layer = layerIfCovering(window, displayBounds: displayBounds) { return layer }
        }
        return nil
    }

    /// The frontmost covering window that is NOT ours, in the list's own z-order.
    static func firstCovering(
        in list: [[String: Any]],
        excludingPID: pid_t,
        displayBounds: CGRect
    ) -> (pid: pid_t, layer: Int)? {
        for window in list {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != excludingPID else { continue }
            if let layer = layerIfCovering(window, displayBounds: displayBounds) { return (pid, layer) }
        }
        return nil
    }

    private static func layerIfCovering(_ window: [String: Any], displayBounds: CGRect) -> Int? {
        if let owner = window[kCGWindowOwnerName as String] as? String, owner == "Finder" { return nil }
        if let alpha = window[kCGWindowAlpha as String] as? Double, alpha == 0 { return nil }
        guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              bounds.insetBy(dx: -2, dy: -2).contains(displayBounds) else { return nil }
        return window[kCGWindowLayer as String] as? Int ?? 0
    }
}

/// One line per trigger, so a run inside a fullscreen game says whether the trigger
/// reached us at all (Class A) and, if it did, what was in front of it (Class B).
/// The installed app's `os_log` lines are not retrievable with `log show`, so every line
/// also goes to `~/Library/Logs/Camcord/diagnostics.log` — that file is what the owner
/// reads after an in-game trigger test.
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
