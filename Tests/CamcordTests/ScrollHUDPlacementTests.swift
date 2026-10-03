import CoreGraphics
import Testing
@testable import Camcord

/// Where the scroll capture HUD stands: never under the menu bar or the Dock, never over the
/// region while there is room elsewhere, and still on screen when there is none.
@MainActor
@Suite("Scroll HUD placement")
struct ScrollHUDPlacementTests {
    /// A laptop screen's visible frame: the Dock below, the menu bar above.
    private let visible = CGRect(x: 0, y: 70, width: 1512, height: 874)

    @Test("with room beside the region the full tray stands there, clear of it and on screen")
    func besideTheRegion() {
        let region = CGRect(x: 300, y: 200, width: 700, height: 600)
        let placement = ScrollPreviewPanel.placement(near: region, visible: visible)
        #expect(!placement.compact)
        #expect(placement.tray.minX > region.maxX)
        #expect(visible.contains(placement.tray))
        #expect(!placement.tray.intersects(region))
    }

    @Test("a short region near the Dock slides the tray up beside it instead of giving it up")
    func shortRegionNearTheDock() {
        let region = CGRect(x: 300, y: 90, width: 700, height: 140)
        let placement = ScrollPreviewPanel.placement(near: region, visible: visible)
        #expect(!placement.compact)
        #expect(visible.contains(placement.tray))
        #expect(!placement.tray.intersects(region))
    }

    @Test("a full-width region gets the compact capsule below or above it")
    func fullWidthRegion() {
        let region = CGRect(x: 0, y: 260, width: 1512, height: 520)
        let placement = ScrollPreviewPanel.placement(near: region, visible: visible)
        #expect(placement.compact)
        #expect(visible.contains(placement.tray))
        #expect(!placement.tray.intersects(region))
    }

    @Test("a region filling the screen keeps the capsule inside its lower edge, on screen")
    func fullScreenRegion() {
        let region = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let placement = ScrollPreviewPanel.placement(near: region, visible: visible)
        #expect(placement.compact)
        #expect(visible.contains(placement.tray))
        #expect(placement.tray.minY >= visible.minY + 20)
        #expect(abs(placement.tray.midX - region.midX) < 1)
    }
}
