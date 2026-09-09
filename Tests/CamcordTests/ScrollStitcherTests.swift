import CoreGraphics
import Foundation
import Testing

@testable import Camcord

/// The scrolling-capture stitcher is pure pixel logic, so we can drive it with synthetic
/// viewport frames cropped from a known "page" and assert the reconstruction — no
/// display or ScreenCaptureKit needed.
///
/// Synthetic content is TEXTURED (varies across columns), like real screen content, so
/// the alignment/band-detection heuristics are exercised the way they would be in
/// practice — flat single-value rows would make "did this row stay put?" match by chance.
/// One column (`sampleCol`) carries a distinct per-row marker that the reader samples, so
/// we can assert exact vertical positions after stitching.
@Suite("ScrollStitcher")
struct ScrollStitcherTests {

    private let width = 40
    private var sampleCol: Int { width / 2 }

    /// splitmix64 finalizer → high-entropy, no linear self-similarity under shift.
    private func hash(_ n: Int) -> UInt8 {
        var z = UInt64(bitPattern: Int64(n)) &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return UInt8(truncatingIfNeeded: z) % 220   // ≤ 219, never collides with a 250 footer
    }

    /// Distinct per-row marker, read back at `sampleCol` to check vertical position.
    private func marker(_ row: Int) -> UInt8 { hash(row &* 2_654_435_761) }

    /// Full-page pixel value: textured everywhere, marker down the sample column.
    private func pixel(_ x: Int, _ y: Int) -> UInt8 {
        x == sampleCol ? marker(y) : hash(x &* 92_821 &+ y &* 40_503)
    }

    private func pixelImage(height: Int, value: (Int, Int) -> UInt8) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { bytes[y * width + x] = value(x, y) }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// A scrolled viewport of the page starting `contentOffset` rows down.
    private func viewport(contentOffset: Int, height: Int) -> CGImage {
        pixelImage(height: height) { x, y in pixel(x, contentOffset + y) }
    }

    /// Mostly-white article rows with low-contrast text blocks. The full-frame MAD for
    /// a real scroll is deliberately below the old static threshold even though the
    /// relative shifted match is exact.
    private func articlePixel(_ x: Int, _ y: Int) -> UInt8 {
        let line = y / 19
        let within = y % 19
        guard (4...7).contains(within) else { return 248 }
        let start = 2 + Int(hash(line * 17)) % 8
        let length = 14 + Int(hash(line * 31 + 7)) % 21
        guard x >= start, x < min(width, start + length) else { return 248 }
        return UInt8(218 + Int(hash(x * 13 + line * 97)) % 8)
    }

    private func articleViewport(contentOffset: Int, height: Int) -> CGImage {
        pixelImage(height: height) { x, y in articlePixel(x, contentOffset + y) }
    }

    private func wideArticlePixel(_ x: Int, _ pageY: Int, width: Int) -> UInt8 {
        let sectionRow = pageY % 480
        let section = pageY / 480
        let margin = max(36, width / 12)
        if (30..<52).contains(sectionRow) {
            let headingLength = width * (35 + Int(hash(section * 43)) % 35) / 100
            guard x >= margin, x < min(width - margin, margin + headingLength) else { return 248 }
            return UInt8(150 + Int(hash(section * 71 + x)) % 28)
        }
        let line = pageY / 24
        let within = pageY % 24
        guard (6...10).contains(within) else { return 248 }
        let available = max(1, width - 2 * margin)
        let start = margin + Int(hash(line * 17)) % max(1, available / 12)
        let length = available * (58 + Int(hash(line * 31 + 7)) % 32) / 100
        guard x >= start, x < min(width - margin, start + length) else { return 248 }
        if ((x - start) / max(2, width / 480)) % 11 == 8 { return 248 }
        return UInt8(206 + Int(hash(x / max(1, width / 720) + line * 97)) % 18)
    }

    private func wideArticleViewport(
        width: Int, height: Int, offset: Int, header: Int, footer: Int,
        toolbarInk: Bool = false
    ) -> CGImage {
        var bytes = [UInt8](repeating: 248, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                if y < header {
                    let showsToolbarInk = toolbarInk
                        && y >= header / 2 && y < header / 2 + 4
                        && x > width / 8 && x < width / 2
                    bytes[y * width + x] = showsToolbarInk ? 188 : 252
                } else if y >= height - footer {
                    bytes[y * width + x] = 232
                } else {
                    bytes[y * width + x] = wideArticlePixel(x, offset + y - header, width: width)
                }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    private func wideArticlePage(
        width: Int, pageHeight: Int, header: Int, footer: Int,
        toolbarInk: Bool
    ) -> CGImage {
        wideArticleViewport(
            width: width, height: header + pageHeight + footer, offset: 0,
            header: header, footer: footer, toolbarInk: toolbarInk
        )
    }

    /// Normalizes an image to the same byte layout before an exact raster comparison.
    private func rgbaBytes(_ image: CGImage) -> [UInt8] {
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let context = CGContext(
            data: &bytes, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        )!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    /// Per-row value at `sampleCol`, row 0 = top.
    private func topDownRows(_ image: CGImage) -> [Int] {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        // No flip: a bottom-left bitmap context draws the image so buffer row 0 == image
        // TOP row (same convention the stitcher uses).
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let col = min(sampleCol, w - 1)
        return (0..<h).map { Int(buf[$0 * w + col]) }
    }

    @Test("rapid Retina scrolling retains every row, including the previously missing two rows")
    func rapidRetinaArticleIsPixelExact() throws {
        let fixture = RetinaScrollFixture(width: 2000, viewportHeight: 2100,
            pageHeight: 12000, header: 144, footer: 96, pixelScale: 2)
        let stitcher = ScrollStitcher()
        let steps = [104, 136, 168, 192, 224, 248, 272, 296]
        let lastOffset = fixture.pageHeight - (fixture.viewportHeight - fixture.header - fixture.footer)
        var offset = 0, index = 0
        while true {
            _ = autoreleasepool { stitcher.add(fixture.viewport(offset: offset), predictedOffset: 0) }
            if offset == lastOffset { break }
            offset = min(lastOffset, offset + steps[index % steps.count])
            index += 1
        }
        let final = try #require(stitcher.finalImage())
        try #require(final.width == fixture.width)
        try #require(final.height == fixture.header + fixture.pageHeight + fixture.footer)
        let actual = rgbaBytes(final)
        var mismatchCount = 0
        for y in 0..<final.height {
            for x in 0..<final.width {
                let value = fixture.fullPageValue(x: x, y: y)
                let i = (y * final.width + x) * 4
                if actual[i] != value || actual[i + 1] != value || actual[i + 2] != value { mismatchCount += 1 }
            }
        }
        #expect(mismatchCount == 0)
    }

    @Test("a fast browser step with 200 real overlapping rows is still searched")
    func fastStepRetainsShortOverlap() throws {
        let fixture = RetinaScrollFixture(width: 1200, viewportHeight: 1640,
                                         pageHeight: 5400, header: 144, footer: 96, pixelScale: 2)
        let stitcher = ScrollStitcher()
        for offset in [0, 220, 440, 960, 1600, 2800, 4000] {
            _ = stitcher.add(fixture.viewport(offset: offset), predictedOffset: 0)
        }
        let final = try #require(stitcher.finalImage())
        #expect(final.height == 5640)
        #expect(!stitcher.hasUnresolvedContinuity)
    }

    @Test("display dithering cannot shift a join within repeated Retina pixel rows")
    func ditheredRetinaRows() throws {
        let width = 256, height = 800
        let stitcher = ScrollStitcher()
        func value(_ x: Int, _ row: Int) -> UInt8 {
            var hash = UInt64(row / 3 + 1) &* 2_654_435_761 ^ UInt64(x / 8 + 7) &* 2_246_822_519
            hash ^= hash >> 13
            hash &*= 3_266_489_917
            hash ^= hash >> 16
            return UInt8(40 + (hash >> 19) % 190)
        }
        var offset = 0
        for index in 0...60 {
            if index > 0 { offset += [36, 52, 68, 44][(index - 1) % 4] }
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for row in 0..<height {
                for x in 0..<width {
                    var noise = UInt64(x + 3) &* 2_246_822_519 ^ UInt64(row + 7) &* 3_266_489_917
                    noise ^= noise >> 13
                    let sample = UInt8(Int(value(x, offset + row)) + Int(noise % 5) - 2)
                    let index = (row * width + x) * 4
                    bytes[index] = sample; bytes[index + 1] = sample; bytes[index + 2] = sample
                }
            }
            let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
            let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            stitcher.add(image, predictedOffset: 0)
        }
        let output = try #require(stitcher.finalImage())
        try #require(output.height == height + offset)
        let pixels = rgbaBytes(output)
        var mismatches = 0
        for row in 0..<output.height {
            for x in 0..<width {
                if abs(Int(pixels[(row * width + x) * 4]) - Int(value(x, row))) > 2 { mismatches += 1 }
            }
        }
        #expect(mismatches == 0)
    }

    @Test("static display dithering does not manufacture motion or sticky bands during warm-up")
    func staticDitherDoesNotFillWarmup() {
        let fixture = RetinaScrollFixture(width: 640, viewportHeight: 400, pageHeight: 1400,
            header: 32, footer: 24, pixelScale: 1)
        let stitcher = ScrollStitcher()
        for phase in 0..<9 {
            let outcome = stitcher.add(fixture.viewport(offset: 0, ditherPhase: phase), predictedOffset: 0)
            #expect(outcome == (phase == 0 ? .buffered : .ignored))
        }
        #expect(!stitcher.isReadyForLiveFrames)
        #expect(stitcher.finalImage()?.height == fixture.viewportHeight)
    }

    // MARK: - Reconstruction

    @Test("stitches scrolled viewports back into the full page at the right height and order")
    func reconstructsFullPage() {
        let pageHeight = 180
        let viewportHeight = 50
        let step = 20
        let stitcher = ScrollStitcher()

        var offset = 0
        while offset + viewportHeight <= pageHeight {
            stitcher.add(viewport(contentOffset: offset, height: viewportHeight), predictedOffset: step)
            offset += step
        }
        stitcher.add(viewport(contentOffset: pageHeight - viewportHeight, height: viewportHeight), predictedOffset: step)

        let final = stitcher.finalImage()
        #expect(final != nil)
        let rows = topDownRows(final!)
        // Close to full-page height (never taller — no duplicated strips).
        #expect(rows.count >= pageHeight - 2 * step)
        #expect(rows.count <= pageHeight + 2)
        // Content preserved in order at the right positions (alignment is exact → no drift).
        #expect(abs(rows[0] - Int(marker(0))) <= 3)
        #expect(abs(rows[80] - Int(marker(80))) <= 3)
        #expect(abs(rows[rows.count - 1] - Int(marker(rows.count - 1))) <= 3)
    }

    @Test("a sparse low-contrast browser article reconstructs despite low frame MAD")
    func reconstructsSparseBrowserArticle() {
        let pageHeight = 820
        let viewportHeight = 240
        let step = 100
        let stitcher = ScrollStitcher()
        var rawDifference = 0
        for y in 0..<viewportHeight {
            for x in 0..<width {
                rawDifference += abs(Int(articlePixel(x, y)) - Int(articlePixel(x, y + step)))
            }
        }
        let rawMAD = Double(rawDifference) / Double(width * viewportHeight)
        #expect(rawMAD < 10) // far below the former 32-point absolute static gate
        var outcomes: [ScrollStitcher.Outcome] = []
        for offset in stride(from: 0, through: pageHeight - viewportHeight, by: step) {
            outcomes.append(stitcher.add(
                articleViewport(contentOffset: offset, height: viewportHeight),
                predictedOffset: step
            ))
        }
        outcomes.append(stitcher.add(
            articleViewport(contentOffset: pageHeight - viewportHeight, height: viewportHeight),
            predictedOffset: step
        ))

        let final = stitcher.finalImage()
        #expect(!outcomes.contains(.lost))
        #expect(!outcomes.contains(.ambiguous))
        #expect(final != nil)
        if let final {
            #expect(final.height >= pageHeight - 2)
            #expect(final.height <= pageHeight + 2)
        }
    }

    @Test("a wide sparse numbered article reconstructs exactly across verified bridges")
    func reconstructsWideSparseNumberedArticle() {
        let pageHeight = 3_000
        let viewportHeight = 900
        let header = 72
        let footer = 48
        let movingHeight = viewportHeight - header - footer
        let step = 150
        let stitcher = ScrollStitcher()
        let maxOffset = pageHeight - movingHeight
        var offsets = Array(stride(from: 0, through: maxOffset, by: step))
        if offsets.last != maxOffset { offsets.append(maxOffset) }
        var outcomes: [ScrollStitcher.Outcome] = []
        for (index, offset) in offsets.enumerated() {
            outcomes.append(stitcher.add(
                wideArticleViewport(
                    width: 1_440, height: viewportHeight, offset: offset,
                    header: header, footer: footer
                ),
                predictedOffset: index == 0 ? 0 : offset - offsets[index - 1]
            ))
        }
        #expect(!outcomes.contains(.lost))
        #expect(!outcomes.contains(.ambiguous))
        let final = stitcher.finalImage()
        #expect(final?.width == 1_440)
        #expect(final?.height == header + pageHeight + footer)
    }

    @Test("brisk sparse article frames with fixed toolbar ink preserve every row")
    func briskSparseArticleWithToolbarPreservesEveryRow() {
        let pageHeight = 6_000
        let viewportHeight = 900
        let header = 72
        let footer = 48
        let movingHeight = viewportHeight - header - footer
        let step = 300
        let stitcher = ScrollStitcher()
        let maxOffset = pageHeight - movingHeight
        var offsets = Array(stride(from: 0, through: maxOffset, by: step))
        if offsets.last != maxOffset { offsets.append(maxOffset) }

        var outcomes: [ScrollStitcher.Outcome] = []
        for offset in offsets {
            outcomes.append(stitcher.add(
                wideArticleViewport(
                    width: 1_440, height: viewportHeight, offset: offset,
                    header: header, footer: footer, toolbarInk: true
                ),
                predictedOffset: 0
            ))
        }

        #expect(!outcomes.contains(.lost))
        #expect(!outcomes.contains(.ambiguous))
        let final = stitcher.finalImage()
        #expect(final?.width == 1_440)
        #expect(final?.height == header + pageHeight + footer)
        if let final {
            let expected = wideArticlePage(
                width: 1_440, pageHeight: pageHeight, header: header, footer: footer,
                toolbarInk: true
            )
            let actualBytes = rgbaBytes(final)
            let expectedBytes = rgbaBytes(expected)
            #expect(actualBytes.count == expectedBytes.count)
            let comparedCount = min(actualBytes.count, expectedBytes.count)
            let mismatch = (0..<comparedCount).first {
                actualBytes[$0] != expectedBytes[$0]
            }
            #expect(mismatch == nil)
        }
    }

    // MARK: - Sticky footer

    @Test("a sticky footer that is present in every frame is composited exactly once")
    func stickyFooterCompositedOnce() {
        let footerValue: UInt8 = 250
        let contentRows = 38
        let footerRows = 12
        let viewportHeight = contentRows + footerRows
        let pageHeight = 170
        let step = 18
        let stitcher = ScrollStitcher()
        var outcomes: [ScrollStitcher.Outcome] = []

        func feed(_ contentOffset: Int) {
            let vp = pixelImage(height: viewportHeight) { x, y in
                y < contentRows ? pixel(x, contentOffset + y) : footerValue
            }
            outcomes.append(stitcher.add(vp, predictedOffset: step))
        }

        var offset = 0
        while offset + contentRows <= pageHeight {
            feed(offset)
            offset += step
        }
        feed(pageHeight - contentRows)

        let final = stitcher.finalImage()
        #expect(!outcomes.contains(.lost))
        #expect(!outcomes.contains(.ambiguous))
        #expect(final != nil)
        if let final {
            #expect(bandCount(topDownRows(final), brightAtLeast: 230, minRun: footerRows / 2) == 1)
            #expect(topDownRows(final).last ?? 0 >= 230)   // and it sits at the very bottom
        }
    }

    @Test("a sticky footer whose content drifts each frame (a live timer) is still composited once")
    func liveUpdatingFooterCompositedOnce() {
        let contentRows = 38
        let footerRows = 12
        let viewportHeight = contentRows + footerRows
        let pageHeight = 170
        let step = 18
        let stitcher = ScrollStitcher()

        var frameIndex = 0
        func feed(_ contentOffset: Int) {
            // Footer drifts a little every frame — like a ticking timer / token counter —
            // so it is NEVER byte-identical across frames. It must still be recognised as
            // fixed via the shift test and composited once.
            let footerValue = UInt8(clamping: 255 - frameIndex * 2)
            let vp = pixelImage(height: viewportHeight) { x, y in
                y < contentRows ? pixel(x, contentOffset + y) : footerValue
            }
            stitcher.add(vp, predictedOffset: step)
            frameIndex += 1
        }

        var offset = 0
        while offset + contentRows <= pageHeight {
            feed(offset)
            offset += step
        }
        feed(pageHeight - contentRows)

        let final = stitcher.finalImage()
        #expect(final != nil)
        #expect(bandCount(topDownRows(final!), brightAtLeast: 235, minRun: footerRows / 2) == 1)
        #expect(topDownRows(final!).last ?? 0 >= 235)
    }

    @Test("static warm-up followed by scrolling preserves sticky header and footer once")
    func staticWarmupThenStickyBands() {
        let viewportHeight = 240
        let headerRows = 24
        let footerRows = 20
        let movingRows = viewportHeight - headerRows - footerRows
        let pageHeight = 620
        let step = 72
        let stitcher = ScrollStitcher()

        func frame(_ offset: Int) -> CGImage {
            pixelImage(height: viewportHeight) { x, y in
                if y < headerRows { return 252 }
                if y >= viewportHeight - footerRows { return 232 }
                return articlePixel(x, offset + y - headerRows)
            }
        }

        var outcomes: [ScrollStitcher.Outcome] = []
        for _ in 0..<7 { outcomes.append(stitcher.add(frame(0), predictedOffset: 0)) }
        for offset in stride(from: step, through: pageHeight - movingRows, by: step) {
            outcomes.append(stitcher.add(frame(offset), predictedOffset: step))
        }
        outcomes.append(stitcher.add(frame(pageHeight - movingRows), predictedOffset: step))

        let final = stitcher.finalImage()
        #expect(!outcomes.contains(.lost))
        #expect(!outcomes.contains(.ambiguous))
        #expect(final != nil)
        if let final {
            let rows = topDownRows(final)
            #expect(rows.prefix(headerRows).allSatisfy { $0 >= 248 })
            #expect(rows.suffix(footerRows).allSatisfy { $0 >= 228 && $0 < 248 })
            #expect(rows.filter { $0 == 252 }.count == headerRows)
            #expect(rows.filter { $0 == 232 }.count == footerRows)
        }
    }

    // MARK: - Robustness

    @Test("static frames (no scrolling) never grow the capture beyond one viewport")
    func staticContentDoesNotGrow() {
        let viewportHeight = 60
        let stitcher = ScrollStitcher()
        let frame = viewport(contentOffset: 0, height: viewportHeight)
        for _ in 0..<5 { stitcher.add(frame, predictedOffset: 0) }

        let final = stitcher.finalImage()
        #expect(final != nil)
        #expect(final!.height == viewportHeight)   // identical frames add nothing
    }

    @Test("an over-large jump blocks export until scrolling back reacquires verified overlap")
    func gapMustBeReacquiredBeforeExport() {
        let pageHeight = 420
        let viewportHeight = 60
        let step = 20
        let stitcher = ScrollStitcher()

        // Warm-up + a few normal steps (grows to height ~160).
        for off in stride(from: 0, through: 100, by: step) {
            stitcher.add(viewport(contentOffset: off, height: viewportHeight), predictedOffset: step)
        }
        #expect(stitcher.add(viewport(contentOffset: 260, height: viewportHeight), predictedOffset: step) == .lost)
        #expect(stitcher.add(viewport(contentOffset: 280, height: viewportHeight), predictedOffset: step) == .lost)
        #expect(stitcher.hasUnresolvedContinuity)
        #expect(stitcher.finalImage() == nil)

        // Return to the last verified viewport and continue with overlap. The rejected
        // jump must not poison the reference or leave a hidden hole in the output.
        for off in stride(from: 120, through: pageHeight - viewportHeight, by: step) {
            stitcher.add(viewport(contentOffset: off, height: viewportHeight), predictedOffset: step)
        }

        let final = stitcher.finalImage()
        #expect(final != nil)
        #expect(!stitcher.hasUnresolvedContinuity)
        #expect(final!.height >= pageHeight - 2)
        #expect(final!.height <= pageHeight + 2)
        let rows = topDownRows(final!)
        #expect(abs(rows[180] - Int(marker(180))) <= 3)
        #expect(abs(rows[rows.count - 1] - Int(marker(pageHeight - 1))) <= 3)
    }

    @Test("a gap during warm-up cannot be exported as a partial capture")
    func warmupGapBlocksExport() {
        let stitcher = ScrollStitcher()
        let offsets = [0, 260, 280, 300, 320, 340, 360]
        var outcomes: [ScrollStitcher.Outcome] = []
        for offset in offsets {
            outcomes.append(stitcher.add(
                viewport(contentOffset: offset, height: 60),
                predictedOffset: 20
            ))
        }
        #expect(outcomes.contains(.lost))
        #expect(stitcher.hasUnresolvedContinuity)
        #expect(stitcher.finalImage() == nil)
    }

    @Test("an over-scroll bounce that re-shows the reference's tail is not appended (no bottom duplicate)")
    func bounceAtBottomIsNotDuplicated() {
        let viewportHeight = 60
        let step = 20
        let stitcher = ScrollStitcher()
        for off in stride(from: 0, through: 100, by: step) {
            stitcher.add(viewport(contentOffset: off, height: viewportHeight), predictedOffset: step)
        }
        // Reference now shows content[100..160]. Bounce guards cover a thin 12px sliver.
        let before = stitcher.finalImage()!.height

        // A bounce SLIVER: top overlaps the reference (correlation finds offset 12), but
        // its bottom 12 rows RE-SHOW content[148..160] — the reference's own tail.
        // Appending it would duplicate that band (the reported footer-duplicate bug).
        let bounce = pixelImage(height: viewportHeight) { x, y in
            y < 48 ? pixel(x, 112 + y) : pixel(x, 148 + (y - 48))
        }
        stitcher.add(bounce, predictedOffset: 12)
        #expect(stitcher.finalImage()!.height == before)   // duplicate rejected, no growth
    }

    @Test("exact duplicate warm-up frames are discarded instead of filling the warm-up window")
    func staticWarmupDuplicatesAreDiscarded() {
        // A continuous stream can deliver several identical frames before the first scroll.
        // They carry no band-detection evidence and must not force an early baseline commit.
        let stitcher = ScrollStitcher()
        let frame = viewport(contentOffset: 0, height: 60)
        var outcomes: [ScrollStitcher.Outcome] = []
        for _ in 0..<7 { outcomes.append(stitcher.add(frame, predictedOffset: 0)) }

        #expect(outcomes.first == .buffered)
        #expect(outcomes.dropFirst().allSatisfy { $0 == .ignored })
        #expect(!outcomes.contains(.baselined))
        #expect(!outcomes.contains(.appended))
        #expect(stitcher.finalImage()?.height == 60)
    }

    @Test("a moving page reports .appended (real advance), not .baselined")
    func movingPageAppends() {
        let stitcher = ScrollStitcher()
        var outcomes: [ScrollStitcher.Outcome] = []
        for i in 0..<7 {
            outcomes.append(stitcher.add(viewport(contentOffset: i * 12, height: 60), predictedOffset: 12))
        }
        #expect(outcomes.contains(.appended))
        #expect(!outcomes.contains(.baselined))
    }

    // MARK: - Short pages (small total scroll)

    @Test("a page that can only scroll a few dozen pixels (short site) is stitched, not dismissed as static")
    func shortPageSmallScrollIsStitched() {
        let viewportHeight = 600
        let smallScroll = 30   // well under viewportHeight/12 — must still count as movement
        let stitcher = ScrollStitcher()

        stitcher.add(viewport(contentOffset: 0, height: viewportHeight), predictedOffset: 0)
        stitcher.add(viewport(contentOffset: smallScroll, height: viewportHeight), predictedOffset: smallScroll)
        // The page hit its bottom: everything after is static.
        var outcomes: [ScrollStitcher.Outcome] = []
        for _ in 0..<3 {
            outcomes.append(stitcher.add(viewport(contentOffset: smallScroll, height: viewportHeight), predictedOffset: 40))
        }
        // Exact resting frames do not force the warm-up to commit; finalization replays
        // the two distinct frames and must still preserve the small real movement.
        #expect(outcomes.allSatisfy { $0 == .ignored })
        #expect(!outcomes.contains(.baselined))
        let rows = topDownRows(stitcher.finalImage()!)
        #expect(rows.count >= viewportHeight + smallScroll - 2)
        #expect(rows.count <= viewportHeight + smallScroll + 2)
        #expect(abs(rows[rows.count - 1] - Int(marker(viewportHeight + smallScroll - 1))) <= 3)
    }

    @Test("a small final scroll after the stitch is established still appends (short remainder at page end)")
    func smallScrollAfterCommitAppends() {
        let viewportHeight = 600
        let step = 200
        let stitcher = ScrollStitcher()
        stitcher.add(viewport(contentOffset: 0, height: viewportHeight), predictedOffset: 0)
        stitcher.add(viewport(contentOffset: step, height: viewportHeight), predictedOffset: step)
        stitcher.add(viewport(contentOffset: 2 * step, height: viewportHeight), predictedOffset: step)
        // The page's last 30px — below the old viewport/12 gate, real content nonetheless.
        let outcome = stitcher.add(viewport(contentOffset: 2 * step + 30, height: viewportHeight), predictedOffset: 30)
        #expect(outcome == .appended)
        let rows = topDownRows(stitcher.finalImage()!)
        let expectedHeight = viewportHeight + 2 * step + 30
        #expect(rows.count >= expectedHeight - 2)
        #expect(rows.count <= expectedHeight + 2)
        #expect(abs(rows[rows.count - 1] - Int(marker(expectedHeight - 1))) <= 3)
    }

    // MARK: - Upward-motion detection (wrong auto direction)

    @Test("a frame showing earlier content during warm-up reports .movedUp (wrong-direction signal)")
    func warmupUpwardMoveIsReported() {
        let stitcher = ScrollStitcher()
        stitcher.add(viewport(contentOffset: 200, height: 400), predictedOffset: 0)
        let outcome = stitcher.add(viewport(contentOffset: 120, height: 400), predictedOffset: 80)
        #expect(outcome == .movedUp)
    }

    @Test("a wide sparse article reports the first reverse move for auto direction calibration")
    func wideSparseUpwardMoveIsReported() {
        let stitcher = ScrollStitcher()
        let width = 1_440
        let height = 900
        let header = 72
        let footer = 48
        stitcher.add(
            wideArticleViewport(
                width: width, height: height, offset: 300,
                header: header, footer: footer
            ),
            predictedOffset: 0
        )
        let outcome = stitcher.add(
            wideArticleViewport(
                width: width, height: height, offset: 150,
                header: header, footer: footer
            ),
            predictedOffset: 150
        )
        #expect(outcome == .movedUp)
    }

    @Test("an upward move after the stitch is established reports .movedUp and keeps the reference")
    func committedUpwardMoveKeepsReference() {
        let viewportHeight = 400
        let step = 120
        let stitcher = ScrollStitcher()
        for i in 0...2 {
            stitcher.add(viewport(contentOffset: i * step, height: viewportHeight), predictedOffset: step)
        }
        let before = stitcher.finalImage()!.height
        // The page jumps back UP (user reviewing / wrong auto direction): repeated
        // upward frames must not re-baseline — coming back down to the reference must
        // not duplicate content.
        for _ in 0..<3 {
            #expect(stitcher.add(viewport(contentOffset: step, height: viewportHeight), predictedOffset: step) == .movedUp)
        }
        #expect(stitcher.finalImage()!.height == before)
        // Scrolling back down past the reference resumes stitching seamlessly.
        let resumed = stitcher.add(viewport(contentOffset: 2 * step + 60, height: viewportHeight), predictedOffset: 60)
        #expect(resumed == .appended)
        #expect(stitcher.finalImage()!.height == before + 60)
    }

    @Test("reviewing similar article cards never appends a fake forward section")
    func repeatedCardsDoNotTurnReviewIntoForwardScroll() throws {
        func card(_ offset: Int) -> CGImage {
            pixelImage(height: 800) { x, y in
                let row = offset + y
                // Mostly shared article layout, with a small section-specific label.
                if x < 4 {
                    return UInt8(80 + Int(hash(x + row / 460 * 31 + row % 460)) % 100)
                }
                return UInt8(190 + Int(hash(x * 71 + row % 460)) % 40)
            }
        }
        let stitcher = ScrollStitcher()
        for offset in [0, 80, 160] { stitcher.add(card(offset), predictedOffset: 0) }
        let before = try #require(stitcher.finalImage()).height
        #expect(stitcher.add(card(120), predictedOffset: 0) == .movedUp)
        #expect(stitcher.finalImage()?.height == before)
        stitcher.add(card(240), predictedOffset: 0)
        #expect(stitcher.finalImage()?.height == before + 80)
    }

    @Test("final resting capture preserves a real blank tail after text moved")
    func finalBlankTailIsPreserved() async throws {
        let fixture = RetinaScrollFixture(width: 600, viewportHeight: 400,
                                         pageHeight: 1000, header: 0, footer: 0, pixelScale: 1)
        let worker = ScrollStitchWorker()
        for offset in [0, 100, 200] { _ = await worker.add(fixture.viewport(offset: offset), predictedOffset: 0) }
        let last = fixture.viewport(offset: 204)
        let captured = await worker.consumeRestingFrame(from: ScrollFrameBuffer(), after: 0, predictedOffset: 0) { last }
        #expect(captured.error == nil)
        let final = try #require(await worker.finalImage())
        #expect(final.height == 604)
    }

    @Test("periodic content (striped rows) scrolling DOWN is never mistaken for an upward move")
    func periodicContentDoesNotFakeUpwardMotion() {
        // Alternating stripes with a 40px period + light noise — a list/table page. A
        // downward move of 140px is indistinguishable from an upward move of 20px for
        // the periodic part; the up-detector must not flip auto-scroll on that tie.
        let viewportHeight = 400
        func stripedViewport(contentOffset: Int) -> CGImage {
            pixelImage(height: viewportHeight) { x, y in
                let page = contentOffset + y
                let stripe: Int = (page / 20) % 2 == 0 ? 200 : 60
                return UInt8(clamping: stripe + Int(hash(x &* 31 &+ page)) / 32)
            }
        }
        let stitcher = ScrollStitcher()
        stitcher.add(stripedViewport(contentOffset: 0), predictedOffset: 0)
        let outcome = stitcher.add(stripedViewport(contentOffset: 140), predictedOffset: 140)
        #expect(outcome != .movedUp)
    }

    @Test("periodic content with tied offsets is rejected instead of fabricating confidence")
    func periodicContentIsAmbiguous() {
        let viewportHeight = 400
        func stripedViewport(contentOffset: Int) -> CGImage {
            pixelImage(height: viewportHeight) { x, y in
                let page = contentOffset + y
                return UInt8(((page % 40) * 5 + x * 3) % 240)
            }
        }
        let stitcher = ScrollStitcher()
        #expect(stitcher.add(stripedViewport(contentOffset: 0), predictedOffset: 0) == .buffered)
        #expect(stitcher.add(stripedViewport(contentOffset: 140), predictedOffset: 140) == .buffered)
        #expect(stitcher.add(stripedViewport(contentOffset: 280), predictedOffset: 140) == .ambiguous)
        #expect(stitcher.hasUnresolvedContinuity)
        #expect(stitcher.finalImage() == nil)
    }

    @Test("one short final move preserves a fixed footer exactly once")
    func shortPageFixedFooterIsPreservedOnce() {
        let viewportHeight = 600
        let footerRows = 50
        let movingRows = viewportHeight - footerRows
        let smallScroll = 30
        let stitcher = ScrollStitcher()

        func feed(_ offset: Int) {
            stitcher.add(pixelImage(height: viewportHeight) { x, y in
                y < movingRows ? pixel(x, offset + y) : 250
            }, predictedOffset: smallScroll)
        }
        feed(0)
        feed(smallScroll)
        feed(smallScroll)
        feed(smallScroll)

        let final = stitcher.finalImage()
        #expect(final != nil)
        #expect(final!.height >= viewportHeight + smallScroll - 2)
        #expect(final!.height <= viewportHeight + smallScroll + 2)
        #expect(bandCount(topDownRows(final!), brightAtLeast: 230, minRun: footerRows / 2) == 1)
    }

    @Test("fully uniform warm-up frames are discarded without phantom motion")
    func uniformContentDoesNotAppend() {
        // A blank/uniform target correlates "perfectly" at every offset, fooling the
        // movement counter. Exact duplicate suppression keeps them out of the warm-up.
        let stitcher = ScrollStitcher()
        let flat = pixelImage(height: 300) { _, _ in 128 }
        var outcomes: [ScrollStitcher.Outcome] = []
        for _ in 0..<7 { outcomes.append(stitcher.add(flat, predictedOffset: 40)) }
        #expect(outcomes.first == .buffered)
        #expect(outcomes.dropFirst().allSatisfy { $0 == .ignored })
        #expect(!outcomes.contains(.appended))
        #expect(stitcher.finalImage()?.height == 300)
    }

    /// Counts contiguous runs of "bright" (≥ threshold) rows at least `minRun` tall.
    private func bandCount(_ rows: [Int], brightAtLeast: Int, minRun: Int) -> Int {
        var bands = 0
        var run = 0
        for value in rows {
            if value >= brightAtLeast {
                run += 1
            } else {
                if run >= minRun { bands += 1 }
                run = 0
            }
        }
        if run >= minRun { bands += 1 }
        return bands
    }
}
