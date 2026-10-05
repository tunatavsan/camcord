import CoreGraphics
import Testing

@testable import Camcord

@Suite("Preview zoom")
struct PreviewZoomTests {
    let capture = CGSize(width: 1_800, height: 1_100)
    let view = CGSize(width: 900, height: 600)

    @Test("whole, the capture fits the view and sits centred")
    func whole() {
        let rect = PreviewZoomGeometry().rect(capture, in: view)
        #expect(abs(rect.width - 900) < 0.001)
        #expect(abs(rect.midX - 450) < 0.001 && abs(rect.midY - 300) < 0.001)
    }

    @Test("zooming keeps the point under the pointer in place")
    func anchored() {
        var geometry = PreviewZoomGeometry()
        let anchor = CGPoint(x: 700, y: 420)
        let before = geometry.rect(capture, in: view)
        let unit = CGPoint(x: (anchor.x - before.minX) / before.width, y: (anchor.y - before.minY) / before.height)
        geometry.zoom(to: 2.5, keeping: anchor, capture, in: view)
        let after = geometry.rect(capture, in: view)
        #expect(abs(after.minX + unit.x * after.width - anchor.x) < 0.5)
        #expect(abs(after.minY + unit.y * after.height - anchor.y) < 0.5)
    }

    @Test("zoomed in, moving around never leaves a gap at an edge")
    func panClamps() {
        var geometry = PreviewZoomGeometry()
        geometry.zoom(to: 3, keeping: CGPoint(x: 450, y: 300), capture, in: view)
        geometry.pan(by: CGPoint(x: 5_000, y: -5_000), capture, in: view)
        let rect = geometry.rect(capture, in: view)
        #expect(rect.minX == 0)
        #expect(abs(rect.maxY - view.height) < 0.001)
    }

    @Test("zoom stays between whole and four times the capture's own size")
    func bounds() {
        var geometry = PreviewZoomGeometry()
        geometry.zoom(to: 0.2, keeping: .zero, capture, in: view)
        #expect(geometry.zoom == 1)
        geometry.zoom(to: 500, keeping: .zero, capture, in: view)
        #expect(abs(geometry.rect(capture, in: view).width - 4 * capture.width) < 0.5)
    }

    @Test("a double click goes to the capture's own size, or twice it when the view already shows that")
    func closer() {
        #expect(abs(PreviewZoomGeometry.closer(capture, in: view) - 2) < 0.001)
        let small = CGSize(width: 300, height: 200)
        #expect(abs(PreviewZoomGeometry.closer(small, in: view) - 2) < 0.001)
    }

    @Test("a preview takes most of the screen; a pin opens modest, centred on its card and on screen")
    func firstSizes() {
        let visible = CGRect(x: 0, y: 0, width: 1_800, height: 1_100)
        let preview = ScreenshotPreviewGeometry(pointSize: capture, visible: visible, pinned: false)
        #expect(preview.frame.width > visible.width * 0.8 || preview.frame.height > visible.height * 0.8)
        #expect(abs(preview.frame.midX - visible.midX) <= 1)
        let card = CGRect(x: 1_460, y: 20, width: 320, height: 232)
        let pin = ScreenshotPreviewGeometry(pointSize: capture, visible: visible, pinned: true, anchor: card)
        #expect(pin.well.width <= ScreenshotPreviewGeometry.maximumWell.width)
        let margin = ScreenshotPreviewGeometry.shadowInset
        #expect(pin.frame.maxX <= visible.maxX + margin && pin.frame.minY >= visible.minY - margin)
    }
}
