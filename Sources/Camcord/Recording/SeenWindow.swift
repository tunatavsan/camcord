import AppKit
@preconcurrency import ScreenCaptureKit

/// How a translucent window is recorded: from its display, with only the window itself and the
/// windows below it, wallpaper included. What shows through it, and the blur it draws of that,
/// is in the recording as on screen, and a window that comes above it later never is; a window
/// it hides behind is still recorded whole. An opaque window has nothing to show through and is
/// recorded on its own, as before.
@MainActor struct SeenWindow {
    let display: SCDisplay
    /// The window and every window below it on screen when the recording started.
    let windows: [SCWindow]
    let windowID: CGWindowID

    /// Nil for a window that looks on screen as it does on its own, or one that is not on screen
    /// wholly on one display. A window can be opaque to itself and still let the screen through
    /// (a terminal whose window server draws its background translucent), so the test is how it
    /// looks: a small shot on its own against a small shot as seen.
    static func plan(for window: SCWindow) async -> SeenWindow? {
        guard window.isOnScreen else { return nil }
        guard let content = try? await withHardTimeout(.seconds(2), onTimeout: CaptureError.timeout, operation: {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }), let plan = plan(for: window.windowID, frame: window.frame, in: content),
              await plan.looksDifferent(window) else { return nil }
        return plan
    }

    /// The same plan against fresh content, after the stream had to be rebuilt.
    func refreshed(in content: SCShareableContent) -> SeenWindow? {
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        return Self.plan(for: windowID, frame: window.frame, in: content)
    }

    private static func plan(for id: CGWindowID, frame: CGRect, in content: SCShareableContent) -> SeenWindow? {
        guard let display = content.displays.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(frame) }) else { return nil }
        let below = Set(WindowAppearance.windowsBelow(id))
        let windows = content.windows.filter { $0.windowID == id || below.contains($0.windowID) }
        guard windows.contains(where: { $0.windowID == id }) else { return nil }
        return SeenWindow(display: display, windows: windows, windowID: id)
    }

    /// The filter that draws the window as seen.
    var filter: SCContentFilter { SCContentFilter(display: display, including: windows) }

    /// The window's rect on its display, in the display's own points, where `frame` puts it.
    func sourceRect(for frame: CGRect) -> CGRect {
        frame.intersection(display.frame).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }

    /// Whether the window on its own differs from the window as seen, away from its edges.
    private func looksDifferent(_ window: SCWindow) async -> Bool {
        guard let alone = try? await ScreenshotService.captureWindowThumbnail(window, maxWidth: 160) else { return false }
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.sourceRect = sourceRect(for: window.frame)
        configuration.width = alone.width
        configuration.height = alone.height
        let filter = filter
        let box = SeenShot(filter: filter, configuration: configuration)
        guard let seen = try? await withHardTimeout(.seconds(2), onTimeout: CaptureError.timeout, operation: {
            try await SCScreenshotManager.captureImage(contentFilter: box.filter, configuration: box.configuration)
        }), let difference = WindowAppearance.difference(alone, seen) else { return false }
        DiagnosticsLog.append("recording window difference=\(String(format: "%.1f", difference))")
        return difference > 3
    }
}

/// The filter and configuration of a small shot, handed to ScreenCaptureKit across actors.
private struct SeenShot: @unchecked Sendable {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
}
