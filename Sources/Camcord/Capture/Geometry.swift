import CoreGraphics

/// Pure coordinate-space helpers. No `NSScreen` dependency so they stay unit-testable
/// without a display.
///
/// AppKit space (`NSEvent.mouseLocation`, `NSScreen.frame`): origin at the
/// bottom-left of the primary screen, Y increases upward.
/// CoreGraphics / ScreenCaptureKit screen space (`SCScreenshotManager.captureImage(in:)`,
/// `SCWindow.frame`): origin at the top-left of the primary screen, Y increases downward.
///
/// Both conversions use the same formula (they are self-inverse): flip the rect's Y
/// through the primary screen's height. Every AppKit<->CG conversion in this app must
/// go through these two functions -- never hand-flip Y anywhere else.
enum Geometry {

    /// Converts a rect from AppKit global screen space to CoreGraphics/SCK screen space.
    static func appKitToCG(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Converts a rect from CoreGraphics/SCK screen space to AppKit global screen space.
    /// Same formula as `appKitToCG` -- the flip is its own inverse.
    static func cgToAppKit(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Normalizes a drag between two arbitrary points into a positive-size rect,
    /// regardless of which direction the drag went.
    static func normalizedRect(from p1: CGPoint, to p2: CGPoint) -> CGRect {
        CGRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y),
            width: abs(p1.x - p2.x),
            height: abs(p1.y - p2.y)
        )
    }

    /// Converts a point-space rect's size to a pixel size at the given backing scale,
    /// for the dimension badge shown while dragging.
    static func pixelSize(of rect: CGRect, scale: CGFloat) -> (w: Int, h: Int) {
        (Int((rect.width * scale).rounded()), Int((rect.height * scale).rounded()))
    }
}
