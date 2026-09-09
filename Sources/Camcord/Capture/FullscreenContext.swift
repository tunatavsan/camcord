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
        let covering = frontmost.flatMap { coveringWindow(pid: $0.processIdentifier, displayBounds: displayBounds) }
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

    /// `kCGWindowLayer` of the frontmost app's first on-screen window that contains the
    /// display's bounds. Fully transparent windows and Finder's desktop are not cover.
    @MainActor
    private static func coveringWindow(pid: pid_t, displayBounds: CGRect) -> Int? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for window in list {
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid else { continue }
            if let owner = window[kCGWindowOwnerName as String] as? String, owner == "Finder" { continue }
            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha == 0 { continue }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.insetBy(dx: -2, dy: -2).contains(displayBounds) else { continue }
            return window[kCGWindowLayer as String] as? Int ?? 0
        }
        return nil
    }
}

/// One line per trigger, so a run inside a fullscreen game says whether the trigger
/// reached us at all (Class A) and, if it did, what was in front of it (Class B).
/// Read with: log show --predicate 'subsystem == "dev.tavsan.camcord"' --last 10m --style compact
enum TriggerLog {
    private static let logger = Logger(subsystem: "dev.tavsan.camcord", category: "trigger")

    @MainActor
    static func fired(_ source: String) {
        logger.notice("trigger source=\(source, privacy: .public) \(FullscreenContext.current().logLine, privacy: .public)")
    }

    static func overlay(_ message: String) {
        logger.notice("overlay \(message, privacy: .public)")
    }
}
