import CoreGraphics
import Testing

@testable import Camcord

@Suite("Geometry")
struct GeometryTests {

    // MARK: - AppKit <-> CG round-trip

    @Test("round-trips a rect on the primary screen (1600pt tall)")
    func roundTripPrimaryScreen() {
        let primaryHeight: CGFloat = 1600
        let appKitRect = CGRect(x: 100, y: 200, width: 300, height: 400)

        let cgRect = Geometry.appKitToCG(appKitRect, primaryScreenHeight: primaryHeight)
        // AppKit maxY (600) becomes CG minY via H - maxY; AppKit minY (200) becomes CG maxY.
        #expect(cgRect == CGRect(x: 100, y: 1000, width: 300, height: 400))

        let backToAppKit = Geometry.cgToAppKit(cgRect, primaryScreenHeight: primaryHeight)
        #expect(backToAppKit == appKitRect)
    }

    @Test("round-trips a rect on a secondary display with negative X")
    func roundTripSecondaryDisplayNegativeX() {
        let primaryHeight: CGFloat = 1600
        // A secondary monitor placed to the left of, and above, the primary screen's
        // AppKit origin -- negative X, Y beyond the primary's own height.
        let appKitRect = CGRect(x: -500, y: 1700, width: 200, height: 150)

        let cgRect = Geometry.appKitToCG(appKitRect, primaryScreenHeight: primaryHeight)
        #expect(cgRect.minX == -500)
        #expect(cgRect == CGRect(x: -500, y: primaryHeight - 1850, width: 200, height: 150))

        let backToAppKit = Geometry.cgToAppKit(cgRect, primaryScreenHeight: primaryHeight)
        #expect(backToAppKit == appKitRect)
    }

    @Test("cgToAppKit is the exact inverse of appKitToCG for arbitrary rects")
    func inverseIsExact() {
        let primaryHeight: CGFloat = 900
        let rects = [
            CGRect(x: 0, y: 0, width: 1, height: 1),
            CGRect(x: -1200, y: -300, width: 640, height: 480),
            CGRect(x: 50.5, y: 12.25, width: 99.75, height: 88.125),
        ]
        for rect in rects {
            let cg = Geometry.appKitToCG(rect, primaryScreenHeight: primaryHeight)
            #expect(Geometry.cgToAppKit(cg, primaryScreenHeight: primaryHeight) == rect)
        }
    }

    // MARK: - normalizedRect

    @Test("normalizes a drag to the bottom-right")
    func normalizeBottomRight() {
        let rect = Geometry.normalizedRect(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 50))
        #expect(rect == CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    @Test("normalizes a drag to the top-left (reversed)")
    func normalizeTopLeft() {
        let rect = Geometry.normalizedRect(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 0, y: 0))
        #expect(rect == CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    @Test("normalizes a drag to the top-right")
    func normalizeTopRight() {
        let rect = Geometry.normalizedRect(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 100, y: 0))
        #expect(rect == CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    @Test("normalizes a drag to the bottom-left")
    func normalizeBottomLeft() {
        let rect = Geometry.normalizedRect(from: CGPoint(x: 100, y: 0), to: CGPoint(x: 0, y: 50))
        #expect(rect == CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    // MARK: - pixelSize

    @Test("computes pixel size at 2x scale")
    func pixelSizeAtScale2() {
        let size = Geometry.pixelSize(of: CGRect(x: 0, y: 0, width: 150, height: 75), scale: 2)
        #expect(size.w == 300)
        #expect(size.h == 150)
    }

    @Test("computes pixel size at 1x scale")
    func pixelSizeAtScale1() {
        let size = Geometry.pixelSize(of: CGRect(x: 10, y: 10, width: 47, height: 33), scale: 1)
        #expect(size.w == 47)
        #expect(size.h == 33)
    }
}
