// Deterministic Retina article with fixed browser chrome, independent of the matcher.
import CoreGraphics
import Foundation

struct RetinaScrollFixture {
    let width: Int
    let viewportHeight: Int
    let pageHeight: Int
    let header: Int
    let footer: Int
    let pixelScale: Int

    private func hash(_ n: Int) -> UInt8 {
        var z = UInt64(bitPattern: Int64(n)) &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return UInt8(truncatingIfNeeded: z)
    }

    private func articlePixel(x: Int, pageY: Int) -> UInt8 {
        let logicalX = x / pixelScale
        let logicalY = pageY / pixelScale
        let logicalWidth = width / pixelScale
        let sectionRow = logicalY % 480
        let section = logicalY / 480
        let margin = max(36, logicalWidth / 12)
        if (30..<52).contains(sectionRow) {
            let headingLength = logicalWidth * (35 + Int(hash(section * 43)) % 35) / 100
            guard logicalX >= margin,
                logicalX < min(logicalWidth - margin, margin + headingLength)
            else { return 248 }
            return UInt8(145 + Int(hash(section * 71 + logicalX / max(1, logicalWidth / 720))) % 32)
        }
        let line = logicalY / 24
        let within = logicalY % 24
        guard (6...10).contains(within) else { return 248 }
        let available = max(1, logicalWidth - 2 * margin)
        let start = margin + Int(hash(line * 17)) % max(1, available / 12)
        let length = available * (58 + Int(hash(line * 31 + 7)) % 32) / 100
        guard logicalX >= start, logicalX < min(logicalWidth - margin, start + length) else { return 248 }
        if ((logicalX - start) / max(2, logicalWidth / 480)) % 11 == 8 { return 248 }
        return UInt8(202 + Int(hash(logicalX / max(1, logicalWidth / 720) + line * 97)) % 22)
    }

    func fullPageValue(x: Int, y: Int) -> UInt8 {
        if y < header {
            return (y >= header / 2 && y < header / 2 + 4 * pixelScale
                && x > width / 8 && x < width / 2) ? 188 : 252
        }
        if y >= header + pageHeight {
            return (y < header + pageHeight + 3 && x > width / 3 && x < width * 2 / 3) ? 178 : 235
        }
        return articlePixel(x: x, pageY: y - header)
    }

    func viewport(offset: Int, ditherPhase: Int? = nil) -> CGImage {
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * viewportHeight)
        for y in 0..<viewportHeight {
            for x in 0..<width {
                let value: UInt8
                if y < header {
                    // Sparse but non-uniform fixed browser/header chrome.
                    value = (y >= header / 2 && y < header / 2 + 4 * pixelScale
                        && x > width / 8 && x < width / 2) ? 188 : 252
                } else if y >= viewportHeight - footer {
                    value = (y < viewportHeight - footer + 3 && x > width / 3 && x < width * 2 / 3) ? 178 : 235
                } else {
                    value = articlePixel(x: x, pageY: offset + y - header)
                }
                let i = y * rowBytes + x * 4
                var noise = 0
                if let phase = ditherPhase {
                    let seed = x * 13 + y * 7
                    noise = (seed + phase * 17) % 3 - 1
                }
                let rendered = UInt8(clamping: Int(value) + noise)
                bytes[i] = rendered
                bytes[i + 1] = rendered
                bytes[i + 2] = rendered
                bytes[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: viewportHeight,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }
}
