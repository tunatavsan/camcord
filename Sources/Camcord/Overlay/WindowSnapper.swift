import AppKit
import ScreenCaptureKit

/// Hit-tests the window under the cursor for the overlay's window-snap mode.
enum WindowSnapper {
    private static let minimumSize: CGFloat = 40

    /// Returns the topmost eligible window under `point` (CG screen space), or nil.
    ///
    /// `SCShareableContent.windows` is NOT guaranteed to be in z-order, so hit-testing
    /// "the first entry whose frame contains the point" can pick a window BEHIND the
    /// front one (e.g. a small window behind a full-screen one). Instead we ask the
    /// window server for the real front-to-back list (`CGWindowListCopyWindowInfo`),
    /// take the topmost normal window at the point, and map it back to its `SCWindow`
    /// by window number. Excludes our own windows, non-normal layers, and tiny windows.
    static func window(atCGPoint point: CGPoint, content: SCShareableContent) -> SCWindow? {
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let ownBundleID = Bundle.main.bundleIdentifier

        guard
            let infoList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return nil
        }

        // Front-to-back order.
        for info in infoList {
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                bounds.width >= minimumSize, bounds.height >= minimumSize,
                bounds.contains(point)
            else { continue }
            guard let number = info[kCGWindowNumber as String] as? Int else { continue }

            // Only snap to windows ScreenCaptureKit can actually capture.
            guard let window = byID[CGWindowID(number)], window.isOnScreen else { continue }
            if window.owningApplication?.bundleIdentifier == ownBundleID { continue }
            return window
        }
        return nil
    }
}
