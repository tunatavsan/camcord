import AppKit
import SwiftUI

/// SF Symbols drawn on a fixed square and centred on their ink rather than their typographic
/// box, so a row of different glyphs sits on one optical centre.
@MainActor enum InkCenteredSymbol {
    private static var cache: [String: NSImage] = [:]

    /// A template image for SwiftUI: tinted by the foreground style, light or dark.
    static func template(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .medium, canvas: CGFloat) -> NSImage {
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(canvas)"
        if let cached = cache[key] { return cached }
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let image: NSImage
        if let rendered = render(name, pointSize: pointSize, weight: weight, canvas: canvas, scale: scale, color: .black) {
            image = NSImage(cgImage: rendered, size: CGSize(width: canvas, height: canvas))
        } else {
            image = NSImage(size: CGSize(width: canvas, height: canvas))
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    static func render(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, canvas: CGFloat,
                       scale: CGFloat, color: NSColor) -> CGImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        else { return nil }
        let side = Int((canvas * scale).rounded())
        func draw(offset: CGPoint) -> CGContext? {
            guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let size = image.size
            image.draw(in: CGRect(x: (canvas - size.width) / 2 + offset.x, y: (canvas - size.height) / 2 + offset.y,
                                  width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
            return context
        }
        guard let first = draw(offset: .zero), let data = first.data else { return nil }
        // Ink bounds in pixels; bitmap rows run top to bottom.
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var minX = side, maxX = -1, minRow = side, maxRow = -1
        for row in 0..<side {
            for column in 0..<side where pixels[(row * side + column) * 4 + 3] > 24 {
                minX = min(minX, column); maxX = max(maxX, column)
                minRow = min(minRow, row); maxRow = max(maxRow, row)
            }
        }
        guard maxX >= minX, maxRow >= minRow else { return first.makeImage() }
        let inkX = CGFloat(minX + maxX + 1) / 2 / scale
        let inkY = (CGFloat(side) - CGFloat(minRow + maxRow + 1) / 2) / scale
        return draw(offset: CGPoint(x: canvas / 2 - inkX, y: canvas / 2 - inkY))?.makeImage()
    }
}

/// An ink-centred symbol in SwiftUI.
struct InkSymbol: View {
    let name: String
    var pointSize: CGFloat = 17
    var weight: NSFont.Weight = .medium
    var canvas: CGFloat = 26
    var body: some View {
        Image(nsImage: InkCenteredSymbol.template(name, pointSize: pointSize, weight: weight, canvas: canvas))
            .renderingMode(.template)
            .frame(width: canvas, height: canvas)
            .accessibilityHidden(true)
    }
}
