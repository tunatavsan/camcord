import CoreGraphics
import Foundation
import Testing

@testable import Camcord

@Suite("Window appearance")
struct WindowAppearanceTests {
    /// An RGBA image of `width` by `height` filled by `pixel(x, y)` (y from the top).
    static func image(_ width: Int, _ height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let i = (y * width + x) * 4
                // Premultiplied, as a window's own capture is.
                bytes[i] = UInt8(Int(r) * Int(a) / 255); bytes[i + 1] = UInt8(Int(g) * Int(a) / 255)
                bytes[i + 2] = UInt8(Int(b) * Int(a) / 255); bytes[i + 3] = a
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    @Test("a translucent window takes the screen's colours inside its own shape, its corner left clear")
    func translucentWindow() throws {
        // On its own: a grey body at 85% with a fully clear top-left corner pixel block.
        let alone = Self.image(20, 20) { x, y in x < 3 && y < 3 ? (0, 0, 0, 0) : (80, 80, 90, 217) }
        // On screen: the blurred wallpaper showing through, a dark blue.
        let seen = Self.image(20, 20) { _, _ in (30, 30, 60, 255) }
        let composed = try #require(WindowAppearance.composite(seen: seen, shape: alone))
        let pixels = Self.pixels(composed)
        let body = (10 * 20 + 10) * 4
        #expect(pixels[body + 3] == 255, "the body is the window, fully")
        #expect(abs(Int(pixels[body]) - 30) <= 1 && abs(Int(pixels[body + 2]) - 60) <= 1, "with the colours on screen")
        #expect(pixels[3] == 0, "the corner stays clear, as the window's own is")
    }

    @Test("images of different sizes are not combined")
    func mismatched() {
        let a = Self.image(4, 4) { _, _ in (0, 0, 0, 255) }, b = Self.image(5, 4) { _, _ in (0, 0, 0, 255) }
        #expect(WindowAppearance.composite(seen: a, shape: b) == nil)
    }
}
