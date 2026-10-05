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

    /// Nil for an opaque window, or one that is not on screen wholly on one display.
    static func plan(for window: SCWindow) async -> SeenWindow? {
        guard window.isOnScreen, await isTranslucent(window) else { return nil }
        guard let content = try? await withHardTimeout(.seconds(2), onTimeout: CaptureError.timeout, operation: {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }) else { return nil }
        return plan(for: window.windowID, frame: window.frame, in: content)
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

    /// Whether the window lets the screen show through anywhere inside its edges: a small shot of
    /// it on its own, its alpha read away from the rounded corners.
    private static func isTranslucent(_ window: SCWindow) async -> Bool {
        guard let shot = try? await ScreenshotService.captureWindowThumbnail(window, maxWidth: 160) else { return false }
        return WindowAppearance.isTranslucent(shot)
    }
}
