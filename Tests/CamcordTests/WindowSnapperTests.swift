import CoreGraphics
import Testing

@testable import Camcord

@Suite("WindowSnapper.topmost")
struct WindowSnapperTests {
    private func candidate(_ id: CGWindowID, _ rect: CGRect, layer: Int = 0) -> WindowSnapper.Candidate {
        WindowSnapper.Candidate(windowID: id, layer: layer, bounds: rect)
    }

    /// The regression that motivated the fix: a small window ON TOP of a big back
    /// window must win when the cursor is over the small one, even though the point is
    /// also inside the big window's frame.
    @Test("a small front window on top of a large one wins under the cursor")
    func smallFrontWindowWinsOverLargeBack() {
        let big = candidate(1, CGRect(x: 0, y: 0, width: 1000, height: 800))
        let small = candidate(2, CGRect(x: 100, y: 100, width: 200, height: 150))
        // Front-to-back: the small window is in front.
        let ordered = [small, big]
        let id = WindowSnapper.topmost(
            atCGPoint: CGPoint(x: 150, y: 150),
            ordered: ordered,
            capturableIDs: [1, 2],
            ownWindowIDs: []
        )
        #expect(id == 2)
    }

    @Test("over the big window but outside the small one snaps to the big window")
    func fallsThroughToBackWindowOutsideFront() {
        let big = candidate(1, CGRect(x: 0, y: 0, width: 1000, height: 800))
        let small = candidate(2, CGRect(x: 100, y: 100, width: 200, height: 150))
        let id = WindowSnapper.topmost(
            atCGPoint: CGPoint(x: 700, y: 500),  // inside big, outside small
            ordered: [small, big],
            capturableIDs: [1, 2],
            ownWindowIDs: []
        )
        #expect(id == 1)
    }

    @Test("skips non-normal layers, tiny windows, own windows, and non-capturable windows")
    func skipsIneligible() {
        let point = CGPoint(x: 50, y: 50)
        let menuBar = candidate(10, CGRect(x: 0, y: 0, width: 1000, height: 100), layer: 25)
        let tiny = candidate(11, CGRect(x: 0, y: 0, width: 20, height: 20))
        let own = candidate(12, CGRect(x: 0, y: 0, width: 500, height: 500))
        let real = candidate(13, CGRect(x: 0, y: 0, width: 500, height: 500))
        let ordered = [menuBar, tiny, own, real]
        let id = WindowSnapper.topmost(
            atCGPoint: point,
            ordered: ordered,
            capturableIDs: [10, 11, 12, 13],
            ownWindowIDs: [12]
        )
        #expect(id == 13)
    }

    @Test("a window absent from the capturable set is skipped")
    func skipsNonCapturable() {
        let front = candidate(1, CGRect(x: 0, y: 0, width: 500, height: 500))
        let back = candidate(2, CGRect(x: 0, y: 0, width: 500, height: 500))
        let id = WindowSnapper.topmost(
            atCGPoint: CGPoint(x: 10, y: 10),
            ordered: [front, back],
            capturableIDs: [2],   // front (1) is not capturable
            ownWindowIDs: []
        )
        #expect(id == 2)
    }

    @Test("no eligible window under the point returns nil")
    func returnsNilWhenNothingHit() {
        let win = candidate(1, CGRect(x: 0, y: 0, width: 100, height: 100))
        let id = WindowSnapper.topmost(
            atCGPoint: CGPoint(x: 500, y: 500),
            ordered: [win],
            capturableIDs: [1],
            ownWindowIDs: []
        )
        #expect(id == nil)
    }

    // MARK: - Click-path hit-test (no capturable-set dependency)

    /// The regression that motivated the click path: a window that is missing from the
    /// (stale) shareable-content snapshot — e.g. opened seconds ago — must still be
    /// pickable; the hover variant skipped it and selected the window BEHIND it.
    @Test("click path picks the front window even when no snapshot knows it")
    func clickPathIgnoresSnapshotStaleness() {
        let front = candidate(1, CGRect(x: 0, y: 0, width: 500, height: 500))
        let back = candidate(2, CGRect(x: 0, y: 0, width: 500, height: 500))
        let id = WindowSnapper.topmost(
            atCGPoint: CGPoint(x: 10, y: 10),
            ordered: [front, back],
            excludingPID: 999
        )
        #expect(id == 1)
    }

    @Test("click path skips this process's own windows and non-normal layers")
    func clickPathSkipsOwnAndNonNormal() {
        let point = CGPoint(x: 50, y: 50)
        let menuBar = WindowSnapper.Candidate(windowID: 10, layer: 25, bounds: CGRect(x: 0, y: 0, width: 1000, height: 100))
        let own = WindowSnapper.Candidate(windowID: 11, layer: 0, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), ownerPID: 42)
        let real = WindowSnapper.Candidate(windowID: 12, layer: 0, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), ownerPID: 7)
        let id = WindowSnapper.topmost(atCGPoint: point, ordered: [menuBar, own, real], excludingPID: 42)
        #expect(id == 12)
    }

    @Test("candidate mapping keeps z-order, carries the owner pid, and drops transparent windows")
    func candidateMappingFiltersTransparent() {
        let infoList: [[String: Any]] = [
            [
                kCGWindowLayer as String: 0,
                kCGWindowNumber as String: 1,
                kCGWindowOwnerPID as String: 42,
                kCGWindowAlpha as String: 0.0,   // invisible click-catcher — must be dropped
                kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 500, "Height": 500],
            ],
            [
                kCGWindowLayer as String: 0,
                kCGWindowNumber as String: 2,
                kCGWindowOwnerPID as String: 7,
                kCGWindowAlpha as String: 1.0,
                kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 400, "Height": 300],
            ],
        ]
        let mapped = WindowSnapper.candidates(from: infoList)
        #expect(mapped.count == 1)
        #expect(mapped.first?.windowID == 2)
        #expect(mapped.first?.ownerPID == 7)
        #expect(mapped.first?.bounds == CGRect(x: 0, y: 0, width: 400, height: 300))
    }
}
