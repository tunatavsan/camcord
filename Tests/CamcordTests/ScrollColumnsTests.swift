import CoreGraphics
import Foundation
import Testing

@testable import Camcord

/// Fixed side columns are found from two frames a known shift apart.
@Suite("Scroll columns")
struct ScrollColumnsTests {
    private func noise(_ n: Int) -> UInt8 {
        var z = UInt64(bitPattern: Int64(n)) &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return UInt8(truncatingIfNeeded: z ^ (z >> 31))
    }

    private func image(width: Int, height: Int, _ value: (Int, Int) -> UInt8) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { bytes[y * width + x] = value(x, y) } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Text-like content: short dark runs on a light ground, different on every line.
    private func text(_ x: Int, _ y: Int, seed: Int) -> UInt8 {
        let line = y / 12
        guard y % 12 < 7, noise(line &* 31 &+ (x / 6) &+ seed) % 4 != 0 else { return 240 }
        return noise(x &* 7 &+ y &* 13 &+ seed) % 2 == 0 ? 40 : 240
    }

    @Test("a sidebar fixed beside the page is left out, the page's columns kept")
    func fixedSidebarIsLeftOut() throws {
        let width = 400, height = 300, sidebar = 90, shift = 120
        func frame(_ offset: Int) -> CGImage {
            image(width: width, height: height) { x, y in
                x < sidebar ? text(x, y, seed: 999) : text(x, y + offset, seed: 1)
            }
        }
        let span = try #require(ScrollColumns.scrolling(earlier: frame(0), later: frame(shift), shift: shift))
        #expect(span.lowerBound >= sidebar - 4 && span.lowerBound <= sidebar + 34, "left edge at \(span.lowerBound)")
        #expect(span.upperBound == width)
    }

    @Test("a page with nothing fixed beside it keeps its full width")
    func nothingFixedKeepsEverything() {
        let width = 400, height = 300, shift = 120
        func frame(_ offset: Int) -> CGImage { image(width: width, height: height) { x, y in text(x, y + offset, seed: 1) } }
        #expect(ScrollColumns.scrolling(earlier: frame(0), later: frame(shift), shift: shift) == nil)
    }

    @Test("plain margins beside a centred page are not taken for sidebars")
    func plainMarginsAreNotSidebars() {
        let width = 400, height = 300, shift = 120
        func frame(_ offset: Int) -> CGImage {
            image(width: width, height: height) { x, y in
                x < 100 || x >= 300 ? 230 : text(x, y + offset, seed: 1)
            }
        }
        #expect(ScrollColumns.scrolling(earlier: frame(0), later: frame(shift), shift: shift) == nil)
    }
}
