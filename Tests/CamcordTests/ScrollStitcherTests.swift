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

    /// Force the stitcher through its static warm-up so outcome assertions exercise live input.
    private func primeBaseline(_ stitcher: ScrollStitcher, contentOffset: Int, height: Int) {
        let frame = viewport(contentOffset: contentOffset, height: height)
        var outcome: ScrollStitcher.Outcome = .buffered
        for _ in 0..<7 { outcome = stitcher.add(frame, predictedOffset: 0) }
        #expect(outcome == .baselined)
    }

    private func expectPageRows(_ image: CGImage, startingAt start: Int) {
        let rows = topDownRows(image)
        for (index, value) in rows.enumerated() {
            #expect(abs(value - Int(marker(start + index))) <= 3)
        }
    }

    private func periodicViewport(contentOffset: Int, height: Int) -> CGImage {
        pixelImage(height: height) { x, y in
            UInt8(((contentOffset + y) % 48) * 4 + x % 4)
        }
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

        func feed(_ contentOffset: Int) {
            let vp = pixelImage(height: viewportHeight) { x, y in
                y < contentRows ? pixel(x, contentOffset + y) : footerValue
            }
            stitcher.add(vp, predictedOffset: step)
        }

        var offset = 0
        while offset + contentRows <= pageHeight {
            feed(offset)
            offset += step
        }
        feed(pageHeight - contentRows)

        let final = stitcher.finalImage()
        #expect(final != nil)
        #expect(bandCount(topDownRows(final!), brightAtLeast: 230, minRun: footerRows / 2) == 1)
        #expect(topDownRows(final!).last ?? 0 >= 230)   // and it sits at the very bottom
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

    @Test("a single over-large scroll jump re-baselines instead of freezing the rest of the capture")
    func recoversFromAnOverLargeJump() {
        let pageHeight = 420
        let viewportHeight = 60
        let step = 20
        let stitcher = ScrollStitcher()

        // Warm-up + a few normal steps (grows to height ~160).
        for off in stride(from: 0, through: 100, by: step) {
            stitcher.add(viewport(contentOffset: off, height: viewportHeight), predictedOffset: step)
        }
        // Two frames after a huge jump (well past the overlap window) — no confident match;
        // the second trips the re-baseline so the stitch doesn't freeze here.
        stitcher.add(viewport(contentOffset: 260, height: viewportHeight), predictedOffset: step)
        stitcher.add(viewport(contentOffset: 280, height: viewportHeight), predictedOffset: step)
        // Normal steps must resume growing the capture through to the bottom of the page.
        for off in stride(from: 300, through: pageHeight - viewportHeight, by: step) {
            stitcher.add(viewport(contentOffset: off, height: viewportHeight), predictedOffset: step)
        }

        let final = stitcher.finalImage()
        #expect(final != nil)
        // Post-jump content made it in (would be frozen at ~160 if the stitch had stalled).
        #expect(final!.height >= 220)
        let rows = topDownRows(final!)
        #expect(abs(rows[rows.count - 1] - Int(marker(pageHeight - 1))) <= 3)  // ends at the true bottom
    }

    @Test("two consecutive lost alignments re-baseline and remain exportable")
    func twoLostAlignmentsRebaselineAndRemainExportable() {
        let viewportHeight = 60
        let step = 20
        let stitcher = ScrollStitcher()

        for offset in stride(from: 0, through: 40, by: step) {
            stitcher.add(viewport(contentOffset: offset, height: viewportHeight), predictedOffset: step)
        }

        stitcher.add(viewport(contentOffset: 260, height: viewportHeight), predictedOffset: step)
        #expect(stitcher.rebaselineCount == 0)

        stitcher.add(viewport(contentOffset: 280, height: viewportHeight), predictedOffset: step)
        #expect(stitcher.rebaselineCount == 1)
        #expect(stitcher.finalImage() != nil)
    }

    @Test("a spring-back discards its pending bounce strip")
    func bounceAtBottomIsNotDuplicated() {
        let viewportHeight = 384
        let baseOffset = 500
        let stitcher = ScrollStitcher()
        primeBaseline(stitcher, contentOffset: baseOffset, height: viewportHeight)

        let bounce = pixelImage(height: viewportHeight) { x, y in
            y < viewportHeight - 120 ? pixel(x, baseOffset + 120 + y) : 0
        }
        #expect(stitcher.add(bounce, predictedOffset: 120) == .appended)
        #expect(stitcher.hasPending)
        #expect(stitcher.add(viewport(contentOffset: baseOffset, height: viewportHeight), predictedOffset: 120) == .movedUp)

        let final = stitcher.finalImage()!
        #expect(final.height == viewportHeight)
        expectPageRows(final, startingAt: baseOffset)
    }

    @Test("a static page (no motion) reports .baselined at the forced commit, never .appended")
    func staticForcedCommitIsBaselined() {
        // Auto-scroll relies on this: a page that never moves must NOT look like it advanced,
        // otherwise the wrong-direction flip never triggers. Feed the SAME viewport repeatedly.
        let stitcher = ScrollStitcher()
        let frame = viewport(contentOffset: 0, height: 60)
        var outcomes: [ScrollStitcher.Outcome] = []
        for _ in 0..<7 { outcomes.append(stitcher.add(frame, predictedOffset: 0)) }
        // The first frames buffer; the forced commit at maxWarmup is a baseline, not an append.
        #expect(outcomes.contains(.baselined))
        #expect(!outcomes.contains(.appended))
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

    // MARK: - Motion and pending strips

    @Test("an identical frame after a real move commits without growing")
    func identicalFrameAfterMoveCommitsWithoutGrowth() {
        let stitcher = ScrollStitcher()
        primeBaseline(stitcher, contentOffset: 0, height: 96)
        let moved = viewport(contentOffset: 32, height: 96)

        #expect(stitcher.add(moved, predictedOffset: 32) == .appended)
        let heightWithPending = stitcher.contentPixelHeight
        #expect(stitcher.add(moved, predictedOffset: 32) == .noMotion)
        #expect(stitcher.contentPixelHeight == heightWithPending)

        let final = stitcher.finalImage()!
        #expect(final.height == 128)
        expectPageRows(final, startingAt: 0)
    }

    @Test("manual reverse preserves every content row exactly once")
    func manualReversePreservesEveryContentRow() {
        let stitcher = ScrollStitcher()
        primeBaseline(stitcher, contentOffset: 0, height: 720)

        #expect(stitcher.add(viewport(contentOffset: 300, height: 720), predictedOffset: 300) == .appended)
        #expect(stitcher.add(viewport(contentOffset: 200, height: 720), predictedOffset: 100) == .movedUp)
        #expect(stitcher.add(viewport(contentOffset: 400, height: 720), predictedOffset: 200) == .appended)

        let final = stitcher.finalImage()!
        #expect(final.height == 1_120)
        expectPageRows(final, startingAt: 0)
    }

    @Test("periodic stripes use prediction or rebaseline instead of false appends")
    func periodicStripesUsePredictionOrRebaseline() {
        let predicted = ScrollStitcher()
        let first = periodicViewport(contentOffset: 0, height: 480)
        for _ in 0..<7 { _ = predicted.add(first, predictedOffset: 0) }
        for offset in [140, 280, 420] {
            #expect(predicted.add(periodicViewport(contentOffset: offset, height: 480), predictedOffset: 140) == .appended)
        }
        #expect(predicted.finalImage()!.height == 900)

        let unknown = ScrollStitcher()
        for _ in 0..<7 { _ = unknown.add(first, predictedOffset: 0) }
        let outcomes = [140, 280].map {
            unknown.add(periodicViewport(contentOffset: $0, height: 480), predictedOffset: 0)
        }
        #expect(!outcomes.contains(.appended))
        #expect(unknown.rebaselineCount == 1)
        #expect(unknown.finalImage()!.height == 480)
    }

    @Test("upward motion leaves the comparison reference unchanged")
    func upwardMotionLeavesReferenceUnchanged() {
        let stitcher = ScrollStitcher()
        primeBaseline(stitcher, contentOffset: 64, height: 96)

        #expect(stitcher.add(viewport(contentOffset: 32, height: 96), predictedOffset: 32) == .movedUp)
        #expect(stitcher.add(viewport(contentOffset: 96, height: 96), predictedOffset: 32) == .appended)

        let final = stitcher.finalImage()!
        #expect(final.height == 128)
        expectPageRows(final, startingAt: 64)
    }

    @Test("motion classifies down, up, and none")
    func motionClassifiesDownUpAndNone() throws {
        let top = try #require(ScrollStitcher.makeFrame(viewport(contentOffset: 0, height: 96)))
        let lower = try #require(ScrollStitcher.makeFrame(viewport(contentOffset: 32, height: 96)))

        guard case .down(let distance, _) = ScrollStitcher.motion(from: top, to: lower, predicted: 32) else {
            Issue.record("expected downward motion")
            return
        }
        #expect(distance == 32)
        #expect(ScrollStitcher.motion(from: lower, to: top, predicted: 32) == .up(32))
        #expect(ScrollStitcher.motion(from: top, to: top) == .none)
    }

    @Test("finalImage commits a move that has no settling frame")
    func finalImageCommitsPendingMove() {
        let stitcher = ScrollStitcher()
        primeBaseline(stitcher, contentOffset: 0, height: 96)

        #expect(stitcher.add(viewport(contentOffset: 32, height: 96), predictedOffset: 32) == .appended)
        #expect(stitcher.hasPending)
        let final = stitcher.finalImage()!
        #expect(final.height == 128)
        #expect(!stitcher.hasPending)
        expectPageRows(final, startingAt: 0)
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
