import AppKit
import ScreenCaptureKit

/// Hit-tests the window under the cursor for the overlay's window-snap mode.
enum WindowSnapper {
    static let minimumSize: CGFloat = 40

    /// One on-screen window's geometry as reported by the window server, in
    /// front-to-back z-order. Pure value type so the hit-test is unit-testable
    /// without a live window server.
    struct Candidate: Equatable {
        let windowID: CGWindowID
        let layer: Int
        let bounds: CGRect
    }

    /// Pure hit-test: the topmost eligible window at `point`. `ordered` MUST be
    /// front-to-back. Eligible = normal layer (0), at least `minimumSize` on each edge,
    /// containing `point`, ScreenCaptureKit-capturable (`capturableIDs`), and not one of
    /// our own windows (`ownWindowIDs`). Returns the first match — i.e. a small window
    /// sitting on top of a larger one wins over the larger one, which is exactly what a
    /// front-to-back scan guarantees.
    static func topmost(
        atCGPoint point: CGPoint,
        ordered: [Candidate],
        capturableIDs: Set<CGWindowID>,
        ownWindowIDs: Set<CGWindowID>
    ) -> CGWindowID? {
        for candidate in ordered {
            guard candidate.layer == 0 else { continue }
            guard candidate.bounds.width >= minimumSize, candidate.bounds.height >= minimumSize else { continue }
            guard candidate.bounds.contains(point) else { continue }
            guard capturableIDs.contains(candidate.windowID) else { continue }
            guard !ownWindowIDs.contains(candidate.windowID) else { continue }
            return candidate.windowID
        }
        return nil
    }

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

        let ordered: [Candidate] = infoList.compactMap { info in
            guard
                let layer = info[kCGWindowLayer as String] as? Int,
                let number = info[kCGWindowNumber as String] as? Int,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return Candidate(windowID: CGWindowID(number), layer: layer, bounds: bounds)
        }
        // Only snap to windows ScreenCaptureKit can actually capture, and never our own.
        let capturableIDs = Set(content.windows.filter { $0.isOnScreen }.map { $0.windowID })
        let ownWindowIDs = Set(
            content.windows
                .filter { $0.owningApplication?.bundleIdentifier == ownBundleID }
                .map { $0.windowID }
        )
        guard let id = topmost(
            atCGPoint: point,
            ordered: ordered,
            capturableIDs: capturableIDs,
            ownWindowIDs: ownWindowIDs
        ) else { return nil }
        return byID[id]
    }
}
