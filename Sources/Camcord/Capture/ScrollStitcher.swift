import CoreGraphics

/// Incremental vertical-scroll stitcher for **manual** scrolling capture. The user
/// scrolls the target while we feed settled viewport frames (top→bottom) plus a
/// predicted pixel offset seeded from the real scroll delta. It measures the true shift
/// by tolerant row cross-correlation, detects sticky header/footer bands so they are
/// painted exactly once, and composes one tall image on demand — for the live preview
/// and for the final result.
///
/// Why this shape (grounded in how the reliable tools do it):
///  • Manual scroll gives a REAL displacement and GUARANTEED overlap, so we never guess
///    a scroll amount or fight momentum (the two things that make synthesized-scroll
///    capture fail on macOS).
///  • Matching is TOLERANT (mean-abs-diff over a grayscale row signature), not an exact
///    pixel compare — so sub-pixel re-rendering / anti-aliasing between frames doesn't
///    break the stitch.
///  • The overlap search is SEEDED around the scroll delta, which sidesteps the classic
///    false correlation peak a sticky navbar produces at offset 0.
///  • Fixed bands are found by CROSS-FRAME INVARIANCE (rows identical across ≥3 frames
///    captured at different scroll positions) and composited once, instead of repeating
///    in every stitched strip.
///
/// Pure pixel logic, no AppKit / ScreenCaptureKit — unit-testable without a display.
final class ScrollStitcher {

    // MARK: Tunables
    private let columns = 20            // row-signature downsample width
    private let rowStride = 3           // sample every Nth row when correlating
    private let confidenceLimit = 24.0  // mean abs-diff above which a match is untrusted
    private let bandDetectFrames = 3    // frames needed before header/footer detection
    private let maxWarmup = 7           // stop waiting for band detection after this many
    private let bandShiftMargin = 5.0   // a row is "fixed" if staying beats moving by this
    private let bandAbsFixed = 32.0     // ...or, when "moved" can't be tested, matches this well
    private let uniformBandRange = 24   // a strip flatter than this = blank over-scroll, skip it
    private let endStableLimit = 20.0   // a strip matching the reference's own tail = a bounce dup
    private let maxTotalHeight: Int     // px safety cap on the stitched content
    private static let previewMaxHeightPx = 1200  // live preview renders at most this tall (tail only)

    struct Frame {
        let image: CGImage
        let sig: [UInt8]   // per-row grayscale, `columns` wide, full height
        let height: Int
        let width: Int
    }

    enum Outcome: Equatable {
        case buffered              // warm-up: nothing committed yet (preview still valid)
        case appended              // a strip (or the baseline set) was committed after real motion
        case baselined             // forced baseline commit with NO confirmed motion (a static
                                   // page): the composite now exists, but nothing actually moved —
                                   // callers driving the scroll must treat this as "no advance"
        case ignored               // no confident downward move (scrolled up / too fast / static)
        case atCap                 // hit the height cap; caller should finalize
    }

    /// Why an aligned frame wasn't appended — drives re-baseline recovery.
    private enum AlignResult {
        case appended
        case noMotion       // matched but the page barely moved (static / just a live timer)
        case lostAlignment  // couldn't find a confident match (a jump past the overlap window)
    }

    /// After this many consecutive lost-alignment frames, re-baseline to the latest frame
    /// so a single over-large scroll jump can't freeze the stitch for the rest of the run.
    private let reBaselineAfter = 2
    private var consecutiveMisses = 0
    private(set) var rebaselineCount = 0

    // MARK: Detection state
    private var warmup: [Frame] = []
    private var detected = false
    private var headerH = 0
    private var footerH = 0

    // MARK: Committed composition (top→bottom)
    // topImage = baseline rows [0, H-footerH) (header + first content; footer excluded),
    // then the revealed content strips, then footerImage painted once at the very bottom.
    private var topImage: CGImage?
    private var footerImage: CGImage?
    private var strips: [CGImage] = []
    private var reference: Frame?
    private(set) var contentPixelHeight = 0

    init(maxTotalHeight: Int = 40_000) { self.maxTotalHeight = maxTotalHeight }

    /// Number of stitched sections so far — for the live "N bölüm" readout.
    var sectionCount: Int {
        if detected { return (topImage != nil ? 1 : 0) + strips.count }
        return warmup.isEmpty ? 0 : 1
    }

    // MARK: - Feed

    /// Feeds one settled viewport frame. `predictedOffset` is the scroll delta since the
    /// last accepted frame, in the image's PIXELS (0 = unknown → full search).
    @discardableResult
    func add(_ image: CGImage, predictedOffset: Int) -> Outcome {
        guard let f = makeFrame(image) else { return .ignored }

        if !detected {
            warmup.append(f)
            if warmup.count >= bandDetectFrames, warmupHasMovement() {
                commitWarmup(forced: false)
                return .appended
            }
            if warmup.count >= maxWarmup {
                // We only reach the forced commit when movement was NEVER confirmed across
                // the whole warm-up (the movement branch above would have fired first). The
                // baseline is real, but the page never moved — report `.baselined`, not
                // `.appended`, so an auto-scroller can still tell it's going nowhere.
                commitWarmup(forced: true)
                return .baselined
            }
            return .buffered
        }

        if contentPixelHeight >= maxTotalHeight { return .atCap }
        switch appendLive(f, predicted: predictedOffset) {
        case .appended:
            consecutiveMisses = 0
            return .appended
        case .noMotion:
            // Static frame (e.g. the user paused, a timer ticked) — not a miss.
            return .ignored
        case .lostAlignment:
            consecutiveMisses += 1
            if consecutiveMisses >= reBaselineAfter {
                // The stitch lost the thread (a jump past the overlap window). Re-anchor
                // to the current frame so capture keeps working — there's a genuine gap in
                // content here (the user scrolled faster than we could grab), which an
                // honest discontinuity reflects better than freezing or duplicating.
                reference = f
                consecutiveMisses = 0
                rebaselineCount += 1
            }
            return .ignored
        }
    }

    // MARK: - Composites

    /// Full-resolution stitched image of everything so far (nil if nothing captured).
    func finalImage() -> CGImage? {
        if !detected { commitWarmup(forced: true) }
        return render(pieces(), maxWidth: nil)
    }

    /// A width-capped composite for the live preview. Only the BOTTOM tail is rendered:
    /// the panel pins the image to its bottom edge and clips the rest, so compositing the
    /// full (up to `maxTotalHeight`) panorama every frame would be O(n) work — and O(n²)
    /// across a long auto-scroll — for pixels no one sees. Rendering just the visible tail
    /// keeps each redraw bounded regardless of how tall the capture has grown.
    func previewImage(maxWidth: Int) -> CGImage? {
        let all = pieces()
        guard !all.isEmpty else { return nil }
        let srcW = all.map(\.width).max() ?? 0
        guard srcW > 0 else { return nil }
        let scale = srcW > maxWidth ? Double(maxWidth) / Double(srcW) : 1
        // Enough source rows to more than fill the panel's visible tail once scaled down.
        let sourceCap = Int((Double(Self.previewMaxHeightPx) / scale).rounded())
        var tail: [CGImage] = []
        var accumulated = 0
        for piece in all.reversed() {
            tail.append(piece)
            accumulated += piece.height
            if accumulated >= sourceCap { break }
        }
        return render(Array(tail.reversed()), maxWidth: maxWidth)
    }

    // MARK: - Warm-up → committed

    private func commitWarmup(forced: Bool) {
        guard !detected, let first = warmup.first else { detected = true; return }
        let H = first.height
        if warmup.count >= bandDetectFrames, warmup.allSatisfy({ $0.height == H }) {
            let (h, f) = detectBands(warmup)
            headerH = h
            footerH = f
        } else {
            headerH = 0
            footerH = 0
        }
        headerH = min(headerH, H / 3)
        footerH = min(footerH, H / 3)

        topImage = crop(first.image, y: 0, height: H - footerH)
        footerImage = footerH > 0 ? crop(first.image, y: H - footerH, height: footerH) : nil
        contentPixelHeight = H - footerH
        reference = first
        strips = []

        for frame in warmup.dropFirst() { _ = appendLive(frame, predicted: 0) }
        detected = true
        warmup = []
    }

    /// Aligns `f` against the current reference and, on a confident downward move,
    /// appends the newly revealed content strip.
    @discardableResult
    private func appendLive(_ f: Frame, predicted: Int) -> AlignResult {
        guard let ref = reference, f.height == ref.height else { return .lostAlignment }
        let (offset, score) = downOffset(
            ref.sig, f.sig, height: ref.height,
            headerH: headerH, footerH: footerH, predicted: predicted
        )
        if score > confidenceLimit { return .lostAlignment }
        if offset < minShift(ref.height) { return .noMotion }

        // End-of-page guards apply ONLY to small slivers. When the page can't scroll
        // further, an elastic over-scroll "bounce" reveals just a thin band that
        // correlates as a downward move but carries no new content — small offset. A
        // genuine scroll step is large (~40% of the viewport), so gating on offset means
        // real content (even a uniform banner or a repeating list) scrolled in a normal
        // step is NEVER dropped; only bounce slivers get bounce-checked.
        let stripTop = ref.height - footerH - offset
        let stripBottom = ref.height - footerH
        if offset < 2 * minShift(ref.height) {
            // (a) The revealed band is blank window background (over-scroll past content).
            if isUniformBand(f.sig, from: stripTop, to: stripBottom) { return .noMotion }
            // (b) The revealed band re-shows what the reference already had at the bottom
            //     (the bounce re-captured the tail) — a duplicate, not new content.
            if regionMAD(ref.sig, f.sig, from: stripTop, to: stripBottom) <= endStableLimit { return .noMotion }
        }

        guard let strip = cropContent(f.image, offset: offset, footerH: footerH) else { return .noMotion }
        strips.append(strip)
        contentPixelHeight += offset
        reference = f
        return .appended
    }

    /// True once the buffered warm-up frames show consistent downward movement — i.e. the
    /// user actually scrolled, so cross-frame invariance can distinguish sticky bands.
    private func warmupHasMovement() -> Bool {
        guard warmup.count >= bandDetectFrames else { return false }
        var moves = 0
        for i in 1..<warmup.count where warmup[i].height == warmup[i - 1].height {
            let (d, s) = downOffset(
                warmup[i - 1].sig, warmup[i].sig, height: warmup[i].height,
                headerH: 0, footerH: 0, predicted: 0
            )
            if s <= confidenceLimit, d >= minShift(warmup[i].height) { moves += 1 }
        }
        return moves >= bandDetectFrames - 1
    }

    // MARK: - Sticky-band detection (shift test)

    /// Detects sticky header/footer bands by the SHIFT TEST: for each consecutive frame
    /// pair we measure the global scroll offset `g`, then ask of every row "did it STAY
    /// (matches the previous frame at the same position) or MOVE (matches it shifted by
    /// `g`)?". Rows that consistently stayed, anchored to the top edge = sticky header;
    /// to the bottom edge = sticky footer. Unlike byte-invariance this survives a fixed
    /// bar whose content changes a little each frame — e.g. a live timer / token counter
    /// in a terminal's status line — which invariance wrongly treated as scrolling and
    /// duplicated in every strip.
    private func detectBands(_ frames: [Frame]) -> (header: Int, footer: Int) {
        let H = frames[0].height
        guard frames.count >= 3 else { return (0, 0) }   // need ≥2 pairs to vote meaningfully
        var fixedVotes = [Int](repeating: 0, count: H)
        var pairs = 0
        for i in 1..<frames.count where frames[i].height == H && frames[i - 1].height == H {
            let prev = frames[i - 1].sig
            let new = frames[i].sig
            let (g, score) = downOffset(prev, new, height: H, headerH: 0, footerH: 0, predicted: 0)
            guard g >= minShift(H), score <= confidenceLimit else { continue }
            pairs += 1
            for r in 0..<H {
                let stayed = rowMAD(new, prev, r, r)
                let isFixed: Bool
                if r + g < H {
                    isFixed = stayed + bandShiftMargin < rowMAD(new, prev, r, r + g)
                } else {
                    // Bottom rows: the "moved" hypothesis reads off-frame, so fall back to
                    // "does it still match the same position well" (fixed footers do).
                    isFixed = stayed < bandAbsFixed
                }
                if isFixed { fixedVotes[r] += 1 }
            }
        }
        guard pairs >= 2 else { return (0, 0) }

        // A row is fixed only if it stayed put in a strict majority of pairs AND in at
        // least two of them — so a single coincidental same-position match can never
        // manufacture a phantom band (which would truncate real content).
        func isFixedBand(_ r: Int) -> Bool { fixedVotes[r] >= 2 && fixedVotes[r] * 2 > pairs }
        var header = 0
        while header < H, isFixedBand(header) { header += 1 }
        var footer = 0
        var r = H - 1
        while r >= 0, isFixedBand(r) { footer += 1; r -= 1 }
        // A page that didn't really scroll would look "all fixed" — reject that.
        if header + footer >= H - minShift(H) { return (0, 0) }
        return (min(header, H / 3), min(footer, H / 3))
    }

    /// Mean per-pixel abs-diff between row `ra` of `a` and row `rb` of `b`.
    private func rowMAD(_ a: [UInt8], _ b: [UInt8], _ ra: Int, _ rb: Int) -> Double {
        let ia = ra * columns
        let ib = rb * columns
        var sum = 0
        var c = 0
        while c < columns { sum += abs(Int(a[ia + c]) - Int(b[ib + c])); c += 1 }
        return Double(sum) / Double(columns)
    }

    /// True if rows [r0, r1) of `sig` are near-flat (little vertical variation) — a blank
    /// band such as the window background revealed by an elastic over-scroll.
    private func isUniformBand(_ sig: [UInt8], from r0: Int, to r1: Int) -> Bool {
        let lo = max(0, r0)
        let hi = min(sig.count / columns, r1)
        guard lo < hi else { return true }
        var minV = 255
        var maxV = 0
        var r = lo
        while r < hi {
            let base = r * columns
            var c = 0
            while c < columns {
                let v = Int(sig[base + c])
                if v < minV { minV = v }
                if v > maxV { maxV = v }
                c += 1
            }
            r += rowStride
        }
        return maxV - minV <= uniformBandRange
    }

    /// Mean per-pixel abs-diff between rows [r0, r1) of `a` and the SAME rows of `b`
    /// (offset 0) — how different `b` is from `a` in that band.
    private func regionMAD(_ a: [UInt8], _ b: [UInt8], from r0: Int, to r1: Int) -> Double {
        let lo = max(0, r0)
        let hi = min(min(a.count, b.count) / columns, r1)
        guard lo < hi else { return .greatestFiniteMagnitude }
        var sum = 0
        var count = 0
        var r = lo
        while r < hi {
            let base = r * columns
            var c = 0
            while c < columns { sum += abs(Int(a[base + c]) - Int(b[base + c])); c += 1 }
            count += columns
            r += rowStride
        }
        return count > 0 ? Double(sum) / Double(count) : .greatestFiniteMagnitude
    }

    // MARK: - Overlap detection

    /// The smallest offset (px) that counts as "the page actually moved" — ~8% of the
    /// viewport, so momentum jitter and sub-line wheel steps don't register as content.
    private func minShift(_ height: Int) -> Int { max(8, height / 12) }

    /// Best downward offset `d` (>0 ⇒ `new` == `prev` scrolled up by `d`, i.e. we
    /// scrolled DOWN) and its mean per-pixel abs-diff (lower = more confident), measured
    /// only over the moving content band [headerH, height-footerH). Seeds the search
    /// around `predicted` and falls back to a full search if that isn't confident.
    private func downOffset(
        _ prev: [UInt8], _ new: [UInt8], height: Int,
        headerH: Int, footerH: Int, predicted: Int
    ) -> (offset: Int, score: Double) {
        let hTop = max(0, min(headerH, height))
        let hBot = max(0, min(footerH, height))
        let contentH = height - hTop - hBot
        guard contentH > 8 else { return (0, .greatestFiniteMagnitude) }
        let minD = minShift(height)
        let maxD = max(minD, contentH - contentH / 6)   // keep ≥1/6 overlap

        func search(_ lo: Int, _ hi: Int) -> (Int, Double) {
            var bestOffset = 0
            var bestScore = Double.greatestFiniteMagnitude
            var d = max(minD, lo)
            let top = min(hi, maxD)
            while d <= top {
                var sum = 0
                var count = 0
                var r = hTop
                let rEnd = height - hBot - d
                while r < rEnd {
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
                    if score < bestScore { bestScore = score; bestOffset = d }
                }
                d += 1
            }
            return (bestOffset, bestScore)
        }

        if predicted >= minD {
            let slack = max(minD, Int(Double(predicted) * 0.6))
            let (d, s) = search(predicted - slack, predicted + slack)
            if s <= confidenceLimit { return (d, s) }
        }
        return search(minD, maxD)
    }

    // MARK: - Pixel helpers

    private func makeFrame(_ image: CGImage) -> Frame? {
        guard let sig = rowSignature(image) else { return nil }
        return Frame(image: image, sig: sig, height: image.height, width: image.width)
    }

    private func rowSignature(_ image: CGImage) -> [UInt8]? {
        let h = image.height
        guard h > 0 else { return nil }
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: columns, height: h,
            bitsPerComponent: 8, bytesPerRow: columns,
            space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        // No Y-flip: a bitmap context is bottom-left, and CGContext draws an image
        // "upside down" there, so buffer row 0 lands on the image's TOP row — matching
        // `CGImage.cropping`'s top-left origin. (Flipping here inverts sig vs. crop, which
        // is what made the old stitcher run the wrong direction.)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: h))
        guard let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: columns * h)
        return Array(UnsafeBufferPointer(start: ptr, count: columns * h))
    }

    /// The newly revealed content in `image`: the `offset` rows just above the footer.
    private func cropContent(_ image: CGImage, offset: Int, footerH: Int) -> CGImage? {
        let top = image.height - footerH - offset
        guard offset > 0, top >= 0 else { return nil }
        return image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: offset))
    }

    /// Crops rows [y, y+height) — CGImage coordinates are top-left origin.
    private func crop(_ image: CGImage, y: Int, height: Int) -> CGImage? {
        guard height > 0, y >= 0, y + height <= image.height else { return nil }
        return image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height))
    }

    private func pieces() -> [CGImage] {
        if !detected { return warmup.last.map { [$0.image] } ?? [] }
        var p: [CGImage] = []
        if let topImage { p.append(topImage) }
        p.append(contentsOf: strips)
        if let footerImage { p.append(footerImage) }
        return p
    }

    /// Vertically stacks pieces (first = top). Optionally scales down to `maxWidth`.
    private func render(_ pieces: [CGImage], maxWidth: Int?) -> CGImage? {
        let valid = pieces.filter { $0.width > 0 && $0.height > 0 }
        guard !valid.isEmpty else { return nil }
        let srcW = valid.map(\.width).max() ?? 0
        guard srcW > 0 else { return nil }
        let scale: CGFloat = {
            if let maxWidth, srcW > maxWidth { return CGFloat(maxWidth) / CGFloat(srcW) }
            return 1
        }()
        let outW = Int((CGFloat(srcW) * scale).rounded())
        let outH = Int((CGFloat(valid.reduce(0) { $0 + $1.height }) * scale).rounded())
        guard outW > 0, outH > 0 else { return nil }
        let rgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // CGContext origin is bottom-left; the first piece belongs at the TOP.
        var yFromTop: CGFloat = 0
        for piece in valid {
            let ph = CGFloat(piece.height) * scale
            let pw = CGFloat(piece.width) * scale
            let yBottom = CGFloat(outH) - yFromTop - ph
            ctx.draw(piece, in: CGRect(x: 0, y: yBottom, width: pw, height: ph))
            yFromTop += ph
        }
        return ctx.makeImage()
    }
}
