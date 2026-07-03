import AppKit
import ScreenCaptureKit

/// Hit-tests the window under the cursor for the overlay's window-snap mode.
enum WindowSnapper {
    private static let minimumSize: CGFloat = 40

    /// Returns the topmost eligible window under `point` (CG screen space), or nil.
    /// Topmost = first match in `content.windows` (documented front-to-back order).
    /// Excludes: our own app's windows, off-screen windows, non-normal window layers,
    /// and windows smaller than 40x40pt.
    static func window(atCGPoint point: CGPoint, content: SCShareableContent) -> SCWindow? {
        content.windows.first { window in
            guard window.isOnScreen else { return false }
            guard window.windowLayer == 0 else { return false }
            guard window.frame.width >= minimumSize, window.frame.height >= minimumSize else { return false }
            if window.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
                return false
            }
            return window.frame.contains(point)
        }
    }
}
