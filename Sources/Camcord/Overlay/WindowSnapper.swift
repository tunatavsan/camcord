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
        let ownerPID: pid_t

        init(windowID: CGWindowID, layer: Int, bounds: CGRect, ownerPID: pid_t = 0) {
            self.windowID = windowID
            self.layer = layer
            self.bounds = bounds
            self.ownerPID = ownerPID
        }
    }

    /// Maps a `CGWindowListCopyWindowInfo` result to `Candidate`s, preserving its
    /// front-to-back order. Fully transparent windows are dropped — they are invisible
    /// click-catchers that would otherwise win the hit-test over the window the user sees.
    static func candidates(from infoList: [[String: Any]]) -> [Candidate] {
        infoList.compactMap { info in
            guard
                let layer = info[kCGWindowLayer as String] as? Int,
                let number = info[kCGWindowNumber as String] as? Int,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { return nil }
            let pid = (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) ?? 0
            return Candidate(windowID: CGWindowID(number), layer: layer, bounds: bounds, ownerPID: pid)
        }
    }

    /// Fresh window-server geometry in front-to-back order. Kept synchronous and side-effect free;
    /// callers decide whether to run it on the main actor (one trigger-time sample) or off-main
    /// (continuous hover).
    static func currentCandidates() -> [Candidate] {
        guard
            let infoList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]]
        else { return [] }
        return candidates(from: infoList)
    }

    /// Shorter or narrower than this is nothing to scroll: a browser's link-status bubble or a
    /// tooltip, both separate windows of the frontmost app that sit above its real window.
    static let scrollTargetMinimumSide: CGFloat = 120

    /// The window the scroll shortcut captures. The focused window Accessibility names wins when
    /// it is on screen; without it, the frontmost app's front normal window big enough to scroll.
    /// Never one of ours. `ordered` MUST be front-to-back.
    static func scrollTarget(
        ordered: [Candidate],
        frontmostPID: pid_t?,
        ownPID: pid_t,
        focused: CGRect?
    ) -> CGRect? {
        let targetPID = frontmostPID.flatMap { $0 == ownPID ? nil : $0 }
        let eligible = ordered.filter { candidate in
            candidate.ownerPID != ownPID && candidate.layer == 0
                && (targetPID == nil || candidate.ownerPID == targetPID)
                && candidate.bounds.width >= scrollTargetMinimumSide
                && candidate.bounds.height >= scrollTargetMinimumSide
        }
        if let focused {
            // Two windows of one app can stack within a few points of each other: the closest wins.
            if let match = eligible.filter({ distance($0.bounds, focused) <= 4 })
                .min(by: { distance($0.bounds, focused) < distance($1.bounds, focused) }) {
                return match.bounds
            }
        }
        return eligible.first?.bounds
    }

    /// How far apart two frames are: their largest edge or size difference, in points.
    static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }

    /// The app's window at `frame`, as Accessibility knows it (a window picked on screen).
    @MainActor
    static func axWindow(pid: pid_t, matching frame: CGRect) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let windows: [AXUIElement] = AXScrollActuator.attribute(app, kAXWindowsAttribute) ?? []
        return windows.first { window in AXScrollActuator.frame(of: window).map { distance($0, frame) <= 4 } ?? false }
    }

    /// The app's focused window as Accessibility reports it, with its frame in CG (top-left)
    /// points. Nil without the permission or when the app names none.
    @MainActor
    static func focusedWindow(pid: pid_t) -> (element: AXUIElement, frame: CGRect)? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let window: AXUIElement = AXScrollActuator.attribute(app, kAXFocusedWindowAttribute),
              let frame = AXScrollActuator.frame(of: window) else { return nil }
        return (window, frame)
    }

    /// The frames of the parts of `window` that scroll: a browser's web area, an app's scroll
    /// areas. Never inside one of them (a web page's own tree is huge), and bounded in time so
    /// the shortcut stays instant on a slow app.
    @MainActor
    static func scrollingAreas(in window: AXUIElement) -> [CGRect] {
        let scrolling: Set<String> = ["AXWebArea", kAXScrollAreaRole as String]
        let opaque: Set<String> = [kAXTextAreaRole as String, kAXTableRole as String, kAXListRole as String,
                                   kAXOutlineRole as String, kAXBrowserRole as String]
        let deadline = ContinuousClock.now + .milliseconds(150)
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var areas: [CGRect] = []
        var visited = 0
        while !queue.isEmpty, visited < 1_500, ContinuousClock.now < deadline {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role: String = AXScrollActuator.attribute(element, kAXRoleAttribute) ?? ""
            if scrolling.contains(role) {
                if let frame = AXScrollActuator.frame(of: element) { areas.append(frame) }
                continue
            }
            guard depth < 14, !opaque.contains(role) else { continue }
            for child in (AXScrollActuator.attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                queue.append((child, depth + 1))
            }
        }
        return areas
    }

    /// Which scrolling area of `window` the capture takes: the one under the pointer, else the
    /// largest. Areas smaller than a fifth of the window (a carousel, a palette) never count, so
    /// a pointer over one picks the area around it.
    static func scrollContent(areas: [CGRect], window: CGRect, pointer: CGPoint?) -> CGRect? {
        let minimumArea = window.width * window.height / 5
        let eligible = areas.map { $0.intersection(window) }.filter { area in
            !area.isNull && area.width >= scrollTargetMinimumSide && area.height >= scrollTargetMinimumSide
                && area.width * area.height >= minimumArea
        }
        let size: (CGRect) -> CGFloat = { $0.width * $0.height }
        if let pointer, let under = eligible.filter({ $0.contains(pointer) }).min(by: { size($0) < size($1) }) {
            return under
        }
        return eligible.max { size($0) < size($1) }
    }

    /// Resolves the actual active normal window from fresh WindowServer z-order. A display-sized
    /// non-normal surface is a narrow fallback for exclusive-fullscreen apps only.
    static func activeWindowID(
        ordered: [Candidate],
        frontmostPID: pid_t?,
        ownPID: pid_t,
        displayFrames: [CGRect]
    ) -> CGWindowID? {
        let belongsToTarget: (Candidate) -> Bool = { candidate in
            guard candidate.ownerPID != ownPID else { return false }
            if let frontmostPID, frontmostPID != ownPID {
                return candidate.ownerPID == frontmostPID
            }
            return true
        }
        let sized: (Candidate) -> Bool = {
            $0.bounds.width >= minimumSize && $0.bounds.height >= minimumSize
        }
        if let normal = ordered.first(where: { belongsToTarget($0) && sized($0) && $0.layer == 0 }) {
            return normal.windowID
        }
        return ordered.first(where: { candidate in
            guard belongsToTarget(candidate), sized(candidate), candidate.layer != 0 else { return false }
            return displayFrames.contains { display in
                candidate.bounds.width >= display.width * 0.9
                    && candidate.bounds.height >= display.height * 0.9
            }
        })?.windowID
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

        let ordered = candidates(from: infoList)
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

    /// Pure hit-test for the CLICK path: the topmost normal-layer window at `point`,
    /// excluding only OUR OWN windows (by pid). Unlike the hover variant above it does
    /// NOT require membership in a shareable-content snapshot: that snapshot can lag the
    /// window server by seconds (a just-opened window is missing from it), and requiring
    /// it made the picker skip the window actually under the cursor and select whatever
    /// sat behind it.
    static func topmost(atCGPoint point: CGPoint, ordered: [Candidate], excludingPID pid: pid_t) -> CGWindowID? {
        for candidate in ordered {
            guard candidate.layer == 0 else { continue }
            guard candidate.bounds.width >= minimumSize, candidate.bounds.height >= minimumSize else { continue }
            guard candidate.bounds.contains(point) else { continue }
            guard candidate.ownerPID != pid else { continue }
            return candidate.windowID
        }
        return nil
    }

    /// Click-time resolver: hit-tests a FRESH front-to-back window-server list at `point`
    /// (see `topmost(atCGPoint:ordered:excludingPID:)`), off the main thread.
    static func clickTopmostWindowID(atCGPoint point: CGPoint) async -> CGWindowID? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            topmost(atCGPoint: point, ordered: currentCandidates(), excludingPID: pid_t(ownPID))
        }.value
    }

    /// Background-safe helper to offload CGWindowListCopyWindowInfo IPC from the main thread.
    static func topmostWindowID(
        atCGPoint point: CGPoint,
        capturableIDs: Set<CGWindowID>,
        ownWindowIDs: Set<CGWindowID>
    ) async -> CGWindowID? {
        await Task.detached(priority: .userInitiated) {
            return topmost(
                atCGPoint: point,
                ordered: currentCandidates(),
                capturableIDs: capturableIDs,
                ownWindowIDs: ownWindowIDs
            )
        }.value
    }
}
