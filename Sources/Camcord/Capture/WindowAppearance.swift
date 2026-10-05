import CoreGraphics
import Foundation

/// A window as it looks on screen: the display's pixels inside the window's own shape.
enum WindowAppearance {
    /// How far a window's own alpha is raised to make its shape: a translucent body (a terminal
    /// at 85% opacity, a 20% overlay) becomes fully the window, while the soft edge of a rounded
    /// corner keeps its anti-aliasing.
    static let coverageGain = 8

    /// `seen` (the display under the window's rect) inside the shape of `shape` (the window on
    /// its own, transparent where it lets the screen through). Nil when they differ in size.
    static func composite(seen: CGImage, shape: CGImage) -> CGImage? {
        let width = shape.width, height = shape.height
        guard seen.width == width, seen.height == height, width > 0, height > 0 else { return nil }
        var coverage = [UInt8](repeating: 0, count: width * height)
        let drew: Bool = coverage.withUnsafeMutableBytes { bytes in
            guard let alpha = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                        bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            alpha.draw(shape, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        for index in coverage.indices { coverage[index] = UInt8(min(255, Int(coverage[index]) * coverageGain)) }
        guard let provider = CGDataProvider(data: Data(coverage) as CFData),
              let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let space = seen.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clip(to: rect, mask: mask)
        context.draw(seen, in: rect)
        return context.makeImage()
    }

    /// The on-screen windows above `windowID`, front to back.
    static func windowsAbove(_ windowID: CGWindowID) -> [CGWindowID] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], windowID) as? [[String: Any]] else { return [] }
        return list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) } }
    }
}
