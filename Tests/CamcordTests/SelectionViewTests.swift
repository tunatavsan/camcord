import AppKit
import Testing
@testable import Camcord

@Suite("Selection chrome visibility", .serialized)
@MainActor
struct SelectionViewTests {
    @Test("Frozen panel suppresses AppKit ordering motion without changing live selection")
    func frozenPanelPresentationPolicy() {
        _ = NSApplication.shared
        let live = selectionPanel()
        let frozen = selectionPanel()

        live.configureForPresentation(displaysFrozenDesktop: false)
        frozen.configureForPresentation(displaysFrozenDesktop: true)

        #expect(live.animationBehavior == .default)
        #expect(frozen.animationBehavior == .none)
    }

    @Test("Frozen desktop does not cover the drag border or its dimensions", arguments: [1, 2])
    func frozenDragChromeRemainsVisible(scale: Int) throws {
        let image = try renderSelection(scale: scale)
        // A neutral desktop has no blue pixels: these must come from the actual
        // selection outline, composed above the frozen capture.
        var bluePixels = 0
        var badgePixels = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                let color = try #require(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.blueComponent > color.redComponent + 0.3,
                   color.blueComponent > color.greenComponent + 0.15 {
                    bluePixels += 1
                }
                if color.redComponent < 0.4, color.greenComponent < 0.4, color.blueComponent < 0.4 {
                    badgePixels += 1
                }
            }
        }
        #expect(bluePixels > 150, "The drag outline must be visible above frozen pixels")
        #expect(badgePixels > 150, "The dimensions badge must be visible above frozen pixels")
    }

    @Test("Foreground chrome leaves input targeting on the selection view")
    func chromeDoesNotStealDragInput() {
        let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 320, height: 220))
        view.selectionRect = CGRect(x: 40, y: 40, width: 220, height: 110)
        view.badge = (view.selectionRect!, "440 × 220")
        #expect(view.hitTest(CGPoint(x: 100, y: 80)) === view)
        #expect(view.hitTest(CGPoint(x: 220, y: 165)) === view)
    }

    @Test("Clearing a drag removes its chrome without changing the frozen desktop")
    func clearedDragRemovesChrome() throws {
        let image = try renderSelection(clearSelection: true)
        for point in [CGPoint(x: 40, y: 100), CGPoint(x: 150, y: 90), CGPoint(x: 220, y: 50)] {
            let pixel = try #require(image.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.deviceRGB))
            #expect(abs(pixel.redComponent - pixel.greenComponent) < 0.01)
            #expect(abs(pixel.greenComponent - pixel.blueComponent) < 0.01)
            #expect(pixel.redComponent > 0.7)
        }
    }

    private func renderSelection(clearSelection: Bool = false, scale: Int = 1) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let size = CGSize(width: 320, height: 220)
        let view = SelectionView(frame: CGRect(origin: .zero, size: size))
        view.appearance = NSAppearance(named: .aqua)
        view.accent = NSColor(srgbRed: 0, green: 0.4, blue: 1, alpha: 1)
        let desktop = try #require(CGContext(
            data: nil, width: 320 * scale, height: 220 * scale, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        desktop.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        desktop.setFillColor(CGColor(gray: 0.95, alpha: 1))
        desktop.fill(view.bounds)
        let desktopImage: CGImage = try #require(desktop.makeImage())
        view.setFrozenDesktopImage(desktopImage, scale: CGFloat(scale))
        view.selectionRect = CGRect(x: 40, y: 40, width: 220, height: 110)
        view.badge = (view.selectionRect!, "440 × 220")
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        if clearSelection {
            // Exercise invalidation of already drawn backing contents, not only an
            // initially empty view that never showed a border in the first place.
            view.selectionRect = nil
            view.badge = nil
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let output = try #require(CGContext(
            data: nil, width: 320 * scale, height: 220 * scale, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        output.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        try #require(view.layer).render(in: output)
        let bitmap = NSBitmapImageRep(cgImage: try #require(output.makeImage()))
        if let directory = ProcessInfo.processInfo.environment["CAMCORD_SELECTION_TEST_RENDER_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(clearSelection ? "selection-cleared.png" : "selection-drag-\(scale)x.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        return bitmap
    }

    private func selectionPanel() -> SelectionPanel {
        SelectionPanel(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }
}
