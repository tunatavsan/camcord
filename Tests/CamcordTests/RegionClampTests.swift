import CoreGraphics
import Testing

@testable import Camcord

@Suite("RegionClamp")
struct RegionClampTests {

    // MARK: - Fully inside one display

    @Test("a region fully inside a display is left untouched, and sourceRect is display-relative")
    func regionFullyInsideDisplay() {
        let display = RegionClamp.DisplayFrame(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2)
        let region = CGRect(x: 100, y: 100, width: 400, height: 300)

        let result = RegionClamp.clamp(region: region, displays: [display])
        #expect(result?.displayIndex == 0)
        #expect(result?.clampedRegion == region)
        #expect(result?.sourceRect == region) // display origin is (0,0) -- relative == absolute
        #expect(result?.pixelWidth == 800)
        #expect(result?.pixelHeight == 600)
    }

    @Test("sourceRect is offset relative to a non-origin display's top-left")
    func sourceRectIsDisplayRelative() {
        // A secondary display placed to the right of the primary, in CG space.
        let secondary = RegionClamp.DisplayFrame(frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080), scale: 1)
        let region = CGRect(x: 2020, y: 50, width: 300, height: 200)

        let result = RegionClamp.clamp(region: region, displays: [secondary])
        #expect(result?.displayIndex == 0)
        #expect(result?.sourceRect == CGRect(x: 100, y: 50, width: 300, height: 200))
        #expect(result?.pixelWidth == 300)
        #expect(result?.pixelHeight == 200)
    }

    // MARK: - Spanning multiple displays

    @Test("a region spanning two displays clamps to the display containing its center")
    func regionSpanningTwoDisplaysClampsToCenterDisplay() {
        let left = RegionClamp.DisplayFrame(frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), scale: 1)
        let right = RegionClamp.DisplayFrame(frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000), scale: 1)

        // Spans the boundary at x=1000, but its center (x=1100) is on the right display.
        let region = CGRect(x: 900, y: 100, width: 400, height: 200)

        let result = RegionClamp.clamp(region: region, displays: [left, right])
        #expect(result?.displayIndex == 1)
        // Clamped (intersected) to the right display's bounds: x in [1000, 1300).
        #expect(result?.clampedRegion == CGRect(x: 1000, y: 100, width: 300, height: 200))
        #expect(result?.sourceRect == CGRect(x: 0, y: 100, width: 300, height: 200))
    }

    @Test("a region whose center is on the left display clamps there instead")
    func regionSpanningTwoDisplaysClampsToLeftWhenCenterIsLeft() {
        let left = RegionClamp.DisplayFrame(frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), scale: 1)
        let right = RegionClamp.DisplayFrame(frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000), scale: 1)

        // Center (x=950) is on the left display.
        let region = CGRect(x: 800, y: 100, width: 300, height: 200)

        let result = RegionClamp.clamp(region: region, displays: [left, right])
        #expect(result?.displayIndex == 0)
        #expect(result?.clampedRegion == CGRect(x: 800, y: 100, width: 200, height: 200))
    }

    // MARK: - Even-pixel rounding

    @Test("pixel size rounds down to even integers at 1x scale")
    func pixelSizeRoundsDownToEvenAt1x() {
        let display = RegionClamp.DisplayFrame(frame: CGRect(x: 0, y: 0, width: 2000, height: 2000), scale: 1)
        let region = CGRect(x: 0, y: 0, width: 401, height: 301)

        let result = RegionClamp.clamp(region: region, displays: [display])
        #expect(result?.pixelWidth == 400)
        #expect(result?.pixelHeight == 300)
    }

    @Test("pixel size rounds down to even integers at 2x scale")
    func pixelSizeRoundsDownToEvenAt2x() {
        let display = RegionClamp.DisplayFrame(frame: CGRect(x: 0, y: 0, width: 2000, height: 2000), scale: 2)
        // 150.5 * 2 = 301 (odd) -> should floor to 300.
        let region = CGRect(x: 0, y: 0, width: 150.5, height: 100)

        let result = RegionClamp.clamp(region: region, displays: [display])
        #expect(result?.pixelWidth == 300)
        #expect(result?.pixelHeight == 200)
    }

    @Test("an already-even pixel size at 2x scale is left unchanged")
    func pixelSizeAlreadyEvenAt2x() {
        let display = RegionClamp.DisplayFrame(frame: CGRect(x: 0, y: 0, width: 2000, height: 2000), scale: 2)
        let region = CGRect(x: 0, y: 0, width: 100, height: 50)

        let result = RegionClamp.clamp(region: region, displays: [display])
        #expect(result?.pixelWidth == 200)
        #expect(result?.pixelHeight == 100)
    }

    // MARK: - No displays

    @Test("returns nil when there are no displays to clamp to")
    func returnsNilWhenNoDisplays() {
        let result = RegionClamp.clamp(region: CGRect(x: 0, y: 0, width: 100, height: 100), displays: [])
        #expect(result == nil)
    }
}
