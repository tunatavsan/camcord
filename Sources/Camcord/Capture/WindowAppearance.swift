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
        guard seen.width == shape.width, seen.height == shape.height else { return nil }
        return composite(seen: seen, at: CGRect(x: 0, y: 0, width: seen.width, height: seen.height), shape: shape)
    }

    /// `seen` placed at `placement` (pixels, bottom-left origin) inside the shape of `shape`; a part
    /// of the window that was off the screen is left out.
    static func composite(seen: CGImage, at placement: CGRect, shape: CGImage) -> CGImage? {
        let width = shape.width, height = shape.height
        guard width > 0, height > 0, placement.width >= 1, placement.height >= 1,
              CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: -1, dy: -1).contains(placement) else { return nil }
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
        context.draw(seen, in: placement)
        return context.makeImage()
    }

    /// How far apart two shots of the same window are, away from their edges: the mean difference
    /// of their channels, 0…255. A window that looks different on screen than on its own lets the
    /// screen through, whatever its own alpha says.
    static func difference(_ a: CGImage, _ b: CGImage) -> Double? {
        let width = min(a.width, b.width), height = min(a.height, b.height)
        guard width > 8, height > 8 else { return nil }
        func pixels(_ image: CGImage) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drew: Bool = bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            return drew ? bytes : nil
        }
        guard let one = pixels(a), let two = pixels(b) else { return nil }
        let insetX = width / 8, insetY = height / 8
        var total = 0, count = 0
        for y in insetY..<(height - insetY) {
            for x in insetX..<(width - insetX) {
                let i = (y * width + x) * 4
                total += abs(Int(one[i]) - Int(two[i])) + abs(Int(one[i + 1]) - Int(two[i + 1])) + abs(Int(one[i + 2]) - Int(two[i + 2]))
                count += 3
            }
        }
        return count > 0 ? Double(total) / Double(count) : nil
    }

    /// The on-screen windows below `windowID`, front to back.
    static func windowsBelow(_ windowID: CGWindowID) -> [CGWindowID] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenBelowWindow], windowID) as? [[String: Any]] else { return [] }
        return list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) } }
    }

    /// Where the window is now, in global top-left points.
    static func frame(of windowID: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    /// The on-screen windows above `windowID`, front to back.
    static func windowsAbove(_ windowID: CGWindowID) -> [CGWindowID] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], windowID) as? [[String: Any]] else { return [] }
        return list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) } }
    }
}
