import AppKit
import Testing
@testable import Camcord

/// Renders the floating camera tile and checks the badges at the PIXEL level: the owner's
/// complaint was that the grip hung outside the tile's rounded corner, which no amount of
/// geometry unit-testing catches if the drawing code disagrees with the geometry.
/// Set CAMCORD_RENDER_SHOTS=<dir> to also drop the PNGs somewhere lookable.
@Suite("Badge rendering")
@MainActor
struct BadgeRenderPreview {
    @Test("every drawn badge pixel lands inside the tile, in the region it belongs to")
    func badgesDrawInsideTheTile() throws {
        _ = NSApplication.shared
        let shots = ProcessInfo.processInfo.environment["CAMCORD_RENDER_SHOTS"]

        for size in [CGSize(width: 320, height: 180), CGSize(width: 160, height: 90)] {
            let bounds = CGRect(origin: .zero, size: size)
            let radius = CameraOptions.cornerRadius(for: size)
            let tile = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)

            for (label, hotspot) in [("grip", CameraHotspot.resize(.bottomRight)), ("close", .close)] {
                let view = FloatingCameraView(frame: bounds)
                view.image = solidImage(size: size)
                view.layoutSubtreeIfNeeded()
                view.indicateForTesting(hotspot)
                view.layoutSubtreeIfNeeded()

                let scale: CGFloat = 2
                let rep = try #require(NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ))
                let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.cgContext.scaleBy(x: scale, y: scale)
                view.layer?.render(in: context.cgContext)
                NSGraphicsContext.restoreGraphicsState()
                if let shots {
                    try rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "\(shots)/\(Int(size.width))-\(label).png"))
                }

                // The badge is the only white in the frame (the tile itself is a solid tan).
                var painted: [CGPoint] = []
                for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
                    for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
                        guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5,
                              color.brightnessComponent > 0.9, color.saturationComponent < 0.2 else { continue }
                        // Bitmap rows run top-down; the view's coordinates run bottom-up.
                        painted.append(CGPoint(x: (CGFloat(x) + 0.5) / scale,
                                               y: size.height - (CGFloat(y) + 0.5) / scale))
                    }
                }
                #expect(!painted.isEmpty, "\(label) drew nothing at \(size)")
                for point in painted {
                    #expect(tile.contains(point), "\(label) painted \(point) outside the tile at \(size)")
                }

                switch hotspot {
                case .resize:
                    // Hugging its own corner: everything in the bottom-right quadrant.
                    #expect(painted.allSatisfy { $0.x > bounds.midX && $0.y < bounds.midY })
                case .close:
                    let circle = try #require(CameraResizeGeometry.closeFrame(in: bounds))
                    #expect(painted.allSatisfy { circle.insetBy(dx: -2, dy: -2).contains($0) })
                }
            }
        }
    }

    private func solidImage(size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.72, green: 0.55, blue: 0.36, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }
}
