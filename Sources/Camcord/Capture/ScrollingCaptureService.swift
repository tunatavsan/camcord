import CoreGraphics
import Foundation
import os

/// Captures a full scrollable area into one tall image: scroll the region a step at a
/// time, screenshot each viewport, detect how far the content actually moved between
/// frames (image cross-correlation, since synthesized scrolls aren't pixel-exact), and
/// stitch the newly revealed strips beneath the first frame.
///
/// Best-effort: if a step can't be aligned (reached the bottom, the area doesn't
/// scroll, or the scroll went the wrong way) it stops and returns what it has — at
/// minimum the first viewport, i.e. a normal screenshot.
enum ScrollingCaptureService {
    private static let logger = Logger(subsystem: "dev.tavsan.camcord", category: "scrolling-capture")

    // Tunables.
    private static let maxFrames = 60
    private static let settle: Duration = .milliseconds(300)
    private static let columns = 16          // downsample width for row signatures
    private static let rowStride = 3         // sample every Nth row when matching
    private static let minRevealed = 8       // px of new content below which we stop
    private static let alignScoreLimit = 30.0  // mean abs diff above which alignment is untrusted
    private static let maxTotalHeight = 24_000  // px safety cap

    /// `region` is CG screen space (top-left origin), in points.
    static func capture(region: CGRect) async throws -> CGImage {
        // Move the pointer into the region so scroll events land on that window; restore
        // it afterwards. CGEvent locations are top-left CG coordinates.
        let originalPointer = CGEvent(source: nil)?.location
        let center = CGPoint(x: region.midX, y: region.midY)
        CGWarpMouseCursorPosition(center)
        defer {
            if let originalPointer { CGWarpMouseCursorPosition(originalPointer) }
        }

        let first = try await ScreenshotService.captureRegion(cgRect: region)
        let width = first.width
        let height = first.height
        guard height > 0, width > 0 else { return first }

        // Scroll ~60% of the viewport per step (points → the OS scrolls in points).
        let scrollStep = Int(max(60, region.height * 0.6))

        guard var prevSig = rowSignature(first, columns: columns) else { return first }
        var strips: [CGImage] = []
        var totalHeight = height

        for _ in 0..<maxFrames {
            postScroll(pixelsDown: scrollStep)
            try? await Task.sleep(for: settle)

            let frame = try await ScreenshotService.captureRegion(cgRect: region)
            guard frame.height == height, frame.width == width,
                let sig = rowSignature(frame, columns: columns)
            else { break }

            let (offset, score) = detectDownScroll(prev: prevSig, new: sig, height: height)
            // Stop at the bottom (barely moved) or when we can't trust the alignment.
            if offset < minRevealed || score > alignScoreLimit { break }

            guard let strip = frame.cropping(to: CGRect(x: 0, y: height - offset, width: width, height: offset)) else {
                break
            }
            strips.append(strip)
            totalHeight += offset
            prevSig = sig
            if totalHeight >= maxTotalHeight { break }
        }

        return compose(top: first, strips: strips) ?? first
    }

    // MARK: - Scroll synthesis

    private static func postScroll(pixelsDown: Int) {
        // Negative wheel1 = content up / reveal below (non-natural scrolling).
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: Int32(-pixelsDown), wheel2: 0, wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Row signatures + alignment

    /// A grayscale, `columns`-wide downsample of the image, one row of bytes per image
    /// row, top row first. Comparing rows across frames gives the scroll offset.
    private static func rowSignature(_ image: CGImage, columns: Int) -> [UInt8]? {
        let h = image.height
        guard h > 0 else { return nil }
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: columns, height: h,
            bitsPerComponent: 8, bytesPerRow: columns,
            space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        // Flip so buffer row 0 == image TOP row.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: h))
        guard let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: columns * h)
        return Array(UnsafeBufferPointer(start: ptr, count: columns * h))
    }

    /// Best downward offset `d` (>0 means `new` == `prev` scrolled up by `d`, i.e. we
    /// scrolled down) and its mean per-pixel abs-diff score (lower = better match).
    private static func detectDownScroll(prev: [UInt8], new: [UInt8], height: Int) -> (offset: Int, score: Double) {
        var bestOffset = 0
        var bestScore = Double.greatestFiniteMagnitude
        let hi = height - 1
        var d = minRevealed
        while d <= hi {
            let overlap = height - d
            if overlap <= height / 6 { break }  // too little overlap to trust
            var sum = 0
            var count = 0
            var r = 0
            while r < overlap {
                let a = r * columns
                let b = (r + d) * columns
                var c = 0
                while c < columns {
                    sum += abs(Int(new[a + c]) - Int(prev[b + c]))
                    c += 1
                }
                count += columns
                r += rowStride
            }
            if count > 0 {
                let score = Double(sum) / Double(count)
                if score < bestScore {
                    bestScore = score
                    bestOffset = d
                }
            }
            d += 1
        }
        return (bestOffset, bestScore)
    }

    // MARK: - Compose

    private static func compose(top: CGImage, strips: [CGImage]) -> CGImage? {
        let width = top.width
        let totalHeight = top.height + strips.reduce(0) { $0 + $1.height }
        let rgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Bottom-up context: the first piece belongs at the top (highest y).
        var yFromTop = 0
        let pieces = [top] + strips
        for piece in pieces {
            let yBottom = totalHeight - yFromTop - piece.height
            ctx.draw(piece, in: CGRect(x: 0, y: yBottom, width: width, height: piece.height))
            yFromTop += piece.height
        }
        return ctx.makeImage()
    }
}
