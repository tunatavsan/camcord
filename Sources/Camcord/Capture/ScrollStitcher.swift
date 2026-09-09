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
    /// Two materially different offsets this close in score are not enough evidence to
    /// choose either one. Repeating rows/tables routinely create several perfect peaks.
    private let ambiguityMargin = 0.25
    private let bandDetectFrames = 3    // frames needed before header/footer detection
    private let maxWarmup = 7           // stop waiting for band detection after this many
    private let bandShiftMargin = 5.0   // a row is "fixed" if staying beats moving by this
    private let bandAbsFixed = 32.0     // ...or, when "moved" can't be tested, matches this well
    // Prevent a narrow fixed toolbar glyph from outweighing a broad, exact content overlap.
    private let correlationDifferenceCap = 32
    private let uniformBandRange = 24   // a strip flatter than this = blank over-scroll, skip it
    private let endStableLimit = 1.0    // only a near-identical reference tail is a bounce duplicate
    private let maxTotalHeight: Int     // px safety cap on the stitched content
    private static let previewMaxHeightPx = 1200  // live preview renders at most this tall (tail only)

    struct Frame {
        let image: CGImage
        let sig: [UInt8]   // per-row grayscale, `columns` wide, full height
        let height: Int
        let width: Int
        let predictedOffset: Int
        let settled: Bool
    }

    enum Outcome: Equatable {
        case buffered              // warm-up: nothing committed yet (preview still valid)
        case appended              // a strip (or the baseline set) was committed after real motion
        case baselined             // forced baseline commit with NO confirmed motion (a static
                                   // page): the composite now exists, but nothing actually moved —
                                   // callers driving the scroll must treat this as "no advance"
        case ignored               // nothing to stitch (static frame / over-scroll sliver)
        case lost                  // no confident match at all — the frame jumped past the
                                   // overlap window (scrolled faster than we could grab);
                                   // callers surface a "slow down" hint on a streak of these
        case ambiguous             // two materially different offsets match almost equally
        case movedUp               // the page verifiably moved UPWARD vs. the reference —
                                   // nothing is appended; an auto-scroller reads this as
                                   // "the wheel sign is wrong" and flips immediately
        case atCap                 // hit the height cap; caller must block ordinary completion
    }

    /// Why an aligned frame wasn't appended.
    private enum AlignResult {
        case appended
        case noMotion       // matched but the page barely moved (static / just a live timer)
        case lostAlignment  // couldn't find a confident match (a jump past the overlap window)
        case ambiguousAlignment
        case movedUp
    }

    /// A normal final image is available only while every committed strip is contiguous.
    /// A later frame that reconnects to the still-held reference clears this again.
    private(set) var hasUnresolvedContinuity = false
    private var warmupFailureOutcome: Outcome?

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

    /// Automatic scrolling waits for warm-up to commit before posting its first probe,
    /// so every probe receives a live alignment outcome rather than a buffered guess.
    var isReadyForLiveFrames: Bool { detected }

    // MARK: - Feed

    /// Feeds one settled viewport frame. `predictedOffset` is the scroll delta since the
    /// last accepted frame, in the image's PIXELS (0 = unknown → full search).
    @discardableResult
    func add(_ image: CGImage, predictedOffset: Int, settled: Bool = false) -> Outcome {
        guard let f = makeFrame(image, predictedOffset: predictedOffset, settled: settled) else { return .ignored }

        if !detected {
            // A continuous stream commonly supplies several identical frames before the
            // first wheel movement. They add no motion or sticky-band evidence; retaining
            // them can fill maxWarmup, force a bandless baseline, and re-render the same
            // preview repeatedly before useful pixels arrive.
            if let previous = warmup.last,
               previous.width == f.width, previous.height == f.height,
               regionMAD(previous.sig, f.sig, from: 0, to: f.height) <= 1 {
                return .ignored
            }
            warmup.append(f)
            let (moves, trailingStatics) = warmupMovement()
            if warmup.count >= bandDetectFrames, moves >= bandDetectFrames - 1 {
                // Honor commitWarmup's "did anything actually append" — self-similar
                // (uniform/periodic) content can fool the movement count while the
                // append guards rightly reject every strip, and reporting .appended
                // then would fake an advance and defeat the wrong-direction flip.
                let appended = commitWarmup(forced: false)
                if let warmupFailureOutcome { return warmupFailureOutcome }
                return appended ? .appended : .baselined
            }
            // A page that moved what little it could and then stopped (a short site):
            // waiting out the full warm-up would misreport the run as a static page —
            // commit now. Band detection needs ≥2 moving pairs, so this path simply
            // forgoes sticky-band handling (a short page has no room to vote anyway).
            if moves >= 1, trailingStatics >= 2 {
                let appended = commitWarmup(forced: true)
                if let warmupFailureOutcome { return warmupFailureOutcome }
                return appended ? .appended : .baselined
            }
            if warmup.count >= maxWarmup {
                // Movement was never confirmed across the whole warm-up. The baseline is
                // real, but if nothing actually moved report `.baselined`, not `.appended`,
                // so an auto-scroller can still tell it's going nowhere.
                let appended = commitWarmup(forced: true)
                if let warmupFailureOutcome { return warmupFailureOutcome }
                return appended ? .appended : .baselined
            }
            // Check the OTHER direction — but only when the newest pair showed no
            // confident down-move (trailingStatics >= 1): a pair that scrolled down can
            // ALSO match upward on periodic content, and flipping on that tie aborted
            // good runs. A confident upward match here is the one-frame "wrong wheel
            // sign" signal.
            if warmup.count >= 2, trailingStatics >= 1 {
                let prev = warmup[warmup.count - 2]
                if upMotion(from: prev, to: f, predicted: predictedOffset) { return .movedUp }
            }
            return .buffered
        }

        if contentPixelHeight >= maxTotalHeight { return .atCap }
        switch appendLive(f, predicted: predictedOffset) {
        case .appended:
            hasUnresolvedContinuity = false
            return .appended
        case .noMotion:
            // Static frame (e.g. the user paused, a timer ticked) — not a miss.
            return .ignored
        case .movedUp:
            return .movedUp
        case .lostAlignment:
            // Before treating this as a lost thread, check the OTHER direction: a frame
            // showing EARLIER content means the page moved up (wrong auto direction, or
            // the user reviewing what's above). Crucially it must NOT count as a miss —
            // re-baselining onto an up-moved frame would stitch duplicates once the
            // scroll comes back down past the still-valid reference.
            if let ref = reference, upMotion(from: ref, to: f, predicted: predictedOffset) {
                return .movedUp
            }
            // Keep the last proven reference. Re-baselining would hide a missing interval
            // inside an apparently valid image; the user can scroll back until overlap is
            // reacquired, or cancel and retry.
            hasUnresolvedContinuity = true
            return .lost
        case .ambiguousAlignment:
            hasUnresolvedContinuity = true
            return .ambiguous
        }
    }

    /// True when `to` shows content ABOVE `from` — i.e. the page moved upward by a
    /// confident, at-least-`minShift` amount. Implemented as the downward correlation
    /// with the frames swapped: "from == to scrolled down by d" ⟺ "to == from moved up".
    ///
    /// Upward motion is trusted only when its match materially beats the DOWNWARD
    /// hypothesis. Sparse white pages can give a wrong-direction score below the broad
    /// absolute confidence ceiling, while periodic lists can correlate equally well in
    /// both directions. Relative separation handles the first and rejects the tie.
    private func upMotion(from earlier: Frame, to later: Frame, predicted: Int) -> Bool {
        guard earlier.height == later.height else { return false }
        let up = downOffset(
            later.sig, earlier.sig, height: later.height,
            headerH: headerH, footerH: footerH, predicted: predicted
        )
        guard !up.isAmbiguous, up.score <= confidenceLimit, up.offset >= minShift(later.height) else { return false }
        let down = downOffset(
            earlier.sig, later.sig, height: later.height,
            headerH: headerH, footerH: footerH, predicted: predicted
        )
        return down.score - up.score > ambiguityMargin
    }

    // MARK: - Composites

    /// Full-resolution stitched image of everything so far (nil if nothing captured).
    func finalImage() -> CGImage? {
        if !detected { commitWarmup(forced: true) }
        guard !hasUnresolvedContinuity else { return nil }
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

    /// Returns whether any real content strip was appended beyond the baseline — the
    /// caller reports `.appended` (the page verifiably moved) vs `.baselined` on it.
    @discardableResult
    private func commitWarmup(forced: Bool) -> Bool {
        guard !detected, let first = warmup.first else { detected = true; return false }
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
        warmupFailureOutcome = nil

        var appendedAny = false
        for frame in warmup.dropFirst() {
            switch appendLive(frame, predicted: frame.predictedOffset) {
            case .appended: appendedAny = true
            case .ambiguousAlignment:
                hasUnresolvedContinuity = true
                warmupFailureOutcome = .ambiguous
            case .lostAlignment:
                hasUnresolvedContinuity = true
                if warmupFailureOutcome == nil { warmupFailureOutcome = .lost }
            case .noMotion, .movedUp: break
            }
        }
        detected = true
        warmup = []
        return appendedAny
    }

    /// Aligns `f` against the current reference and, on a confident downward move,
    /// appends the newly revealed content strip.
    @discardableResult
    private func appendLive(_ f: Frame, predicted: Int) -> AlignResult {
        guard let ref = reference, f.height == ref.height else { return .lostAlignment }
        let samePosition = regionMAD(
            ref.sig, f.sig,
            from: headerH,
            to: ref.height - footerH
        )
        // Exact same-position signatures contain no pixel evidence of motion. Returning
        // before the offset search also keeps settled end-of-page frames cheap.
        if samePosition == 0 { return .noMotion }
        // On sparse pages, a merely low score inside the event-seeded window is not
        // enough: after one skipped frame the true bridge can be outside that window.
        // Search the full overlap range so visible ink chooses the reference connection.
        let searchPrediction = samePosition < bandAbsFixed ? 0 : predicted
        let rowMatch = downOffset(
            ref.sig, f.sig, height: ref.height,
            headerH: headerH, footerH: footerH, predicted: predicted,
            forceFullSearch: searchPrediction == 0
        )
        let (match, forwardPixels) = pixelRefinedOffset(from: ref, to: f, match: rowMatch)
        // Repeated article cards can match DOWN even while the page is moving UP.
        // Check the competing direction before accepting a merely plausible join,
        // rather than checking upward motion only after downward matching failed.
        // Exact physical matches avoid the second search. Row averages alone can
        // look excellent on repeated paragraphs even in the wrong direction.
        let shortOverlap = match.offset > (ref.height - match.top - match.bottom) / 2
        if forwardPixels > 0.5 || shortOverlap {
            let reverseRows = downOffset(f.sig, ref.sig, height: f.height,
                                     headerH: headerH, footerH: footerH, predicted: 0)
            let (reverse, reversePixels) = pixelRefinedOffset(from: f, to: ref, match: reverseRows)
            if !reverse.isAmbiguous, reverse.offset >= minShift(f.height),
               reversePixels <= 0.5,
               reversePixels + 0.5 < forwardPixels ||
                (shortOverlap && reversePixels <= forwardPixels + 0.5 &&
                 reverse.offset + minShift(f.height) < match.offset &&
                 reverse.score + ambiguityMargin < match.score) {
                return .movedUp
            }
        }
        // Sparse browser pages can move substantially while their full-frame MAD stays
        // small: most sampled pixels are still white background. Treat a low absolute
        // MAD as static only when the best shifted overlap fails to improve on position
        // zero. This retains the exact-static fast path while allowing sparse text to
        // prove motion through a materially better relative match.
        let minimumMotionImprovement = max(0.25, samePosition * 0.15)
        if samePosition < bandAbsFixed,
           samePosition - match.score < minimumMotionImprovement {
            return .noMotion
        }
        if match.isAmbiguous { return .ambiguousAlignment }
        let offset = match.offset
        if match.score > confidenceLimit { return .lostAlignment }
        if offset < minShift(ref.height) { return .noMotion }

        // A short page may move only once before it reaches the bottom, leaving too few
        // moving pairs for the normal multi-frame footer vote. Before the first strip is
        // committed, a single strong shift-test can still identify a fixed bottom edge;
        // promote it into the normal footer representation so the only small scroll is not
        // rejected as an over-scroll duplicate.
        if footerH == 0, strips.isEmpty {
            adoptEarlyFooterIfConfident(from: ref, to: f, offset: offset)
        }

        // End-of-page guards apply ONLY to small slivers. When the page can't scroll
        // further, an elastic over-scroll "bounce" reveals just a thin band that
        // correlates as a downward move but carries no new content — small offset. A
        // genuine scroll step is large (~40% of the viewport), so gating on offset means
        // real content (even a uniform banner or a repeating list) scrolled in a normal
        // step is NEVER dropped; only bounce slivers get bounce-checked.
        let stripTop = ref.height - footerH - offset
        let stripBottom = ref.height - footerH
        if offset < sliverBand(ref.height) {
            // Hold a blank sliver during momentum, but keep it if the final fresh
            // screenshot confirms it. Real whitespace after a paragraph is content,
            // too; rejecting it forever silently shortened captures stopped there.
            let blank = isUniformBand(f.sig, from: stripTop, to: stripBottom)
            if blank, !f.settled { return .noMotion }
            // (b) The revealed band re-shows what the reference already had at the bottom
            //     (the bounce re-captured the tail) — a duplicate, not new content.
            if !blank, regionMAD(ref.sig, f.sig, from: stripTop, to: stripBottom) <= endStableLimit { return .noMotion }
        }

        guard let strip = cropContent(f.image, offset: offset, footerH: footerH) else { return .noMotion }
        strips.append(strip)
        contentPixelHeight += offset
        reference = f
        return .appended
    }

    private func adoptEarlyFooterIfConfident(from previous: Frame, to current: Frame, offset: Int) {
        let H = previous.height
        guard H == current.height, offset >= minShift(H) else { return }
        var fixed = 0
        var strictFixed = 0
        var trailingSamePosition = 0
        var foundStrictEvidence = false
        var row = H - 1
        while row >= 0, fixed < H / 3 {
            let stayed = rowMAD(current.sig, previous.sig, row, row)
            let moved: Double?
            if row + offset < H {
                moved = rowMAD(current.sig, previous.sig, row, row + offset)
            } else if row - offset >= 0 {
                moved = rowMAD(current.sig, previous.sig, row - offset, row)
            } else {
                moved = nil
            }
            let isStrictlyFixed = moved.map { isFixedRow(stayed: stayed, moved: $0) } ?? false
            if isStrictlyFixed {
                foundStrictEvidence = true
                strictFixed += 1
            } else if !foundStrictEvidence,
                      trailingSamePosition < offset,
                      stayed < bandAbsFixed {
                // A footer taller than the scroll amount compares against itself under
                // both hypotheses at the bottom edge. Keep that undecidable suffix only
                // while looking for a substantial direction-verified fixed band below it.
                trailingSamePosition += 1
            } else {
                break
            }
            fixed += 1
            row -= 1
        }
        guard strictFixed >= max(4, H / 100) else { return }
        footerH = fixed
        topImage = crop(previous.image, y: 0, height: H - fixed)
        footerImage = crop(previous.image, y: H - fixed, height: fixed)
        contentPixelHeight = H - fixed
    }

    /// How the buffered warm-up frames moved: `moves` = confident downward pair-moves
    /// (the user/auto actually scrolled, so cross-frame voting can distinguish sticky
    /// bands), `trailingStatics` = consecutive non-moving pairs at the tail (a page that
    /// scrolled and then ran out of room — the short-page early-commit signal).
    private func warmupMovement() -> (moves: Int, trailingStatics: Int) {
        var moves = 0
        var trailing = 0
        guard warmup.count >= 2 else { return (0, 0) }
        for i in 1..<warmup.count {
            var moved = false
            if warmup[i].height == warmup[i - 1].height {
                let match = downOffset(
                    warmup[i - 1].sig, warmup[i].sig, height: warmup[i].height,
                    headerH: 0, footerH: 0, predicted: warmup[i].predictedOffset
                )
                if match.score <= confidenceLimit,
                   match.offset >= minShift(warmup[i].height) {
                    if match.isAmbiguous {
                        // Count this only far enough to commit warm-up; appendLive then
                        // records the tied alignment as a blocking ambiguity.
                        moved = true
                    } else {
                        let opposite = downOffset(
                            warmup[i].sig, warmup[i - 1].sig, height: warmup[i].height,
                            headerH: 0, footerH: 0, predicted: warmup[i].predictedOffset
                        )
                        moved = opposite.score - match.score > ambiguityMargin
                    }
                }
            }
            if moved {
                moves += 1
                trailing = 0
            } else {
                trailing += 1
            }
        }
        return (moves, trailing)
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
            let match = downOffset(prev, new, height: H, headerH: 0, footerH: 0, predicted: 0)
            guard match.offset >= minShift(H), match.score <= confidenceLimit
            else { continue }
            let g = match.offset
            pairs += 1
            for r in 0..<H {
                let stayed = rowMAD(new, prev, r, r)
                let isFixed: Bool
                if r + g < H {
                    isFixed = isFixedRow(stayed: stayed, moved: rowMAD(new, prev, r, r + g))
                } else if r - g >= 0 {
                    // The forward moving hypothesis is off-frame at the bottom. Compare
                    // the previous row with where it should have moved in the new frame.
                    isFixed = isFixedRow(stayed: stayed, moved: rowMAD(new, prev, r - g, r))
                } else {
                    isFixed = false
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
        // One to three agreeing edge rows can be a raster/dither coincidence, not
        // browser chrome. Treating them as a fixed footer silently changes the seam.
        return (header >= 4 ? min(header, H / 3) : 0, footer >= 4 ? min(footer, H / 3) : 0)
    }

    private func isFixedRow(stayed: Double, moved: Double) -> Bool {
        // A pale toolbar can differ from white content by only four code values.
        // A fixed five-value margin could never recognize it, so it contaminated
        // short overlaps. Keep a noise floor and scale the evidence to contrast.
        stayed + min(bandShiftMargin, max(1, moved * 0.25)) < moved
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

    /// The smallest offset (px) that counts as "the page actually moved". A small
    /// floor plus a gentle viewport fraction: the noise it rejects — momentum jitter, sub-line
    /// wheel steps, anti-aliasing shimmer — is a few pixels tall regardless of viewport
    /// size, while short pages often can only scroll a few dozen pixels TOTAL, which a
    /// viewport-relative gate (an earlier /12) silently discarded as "static".
    private func minShift(_ height: Int) -> Int { max(4, height / 200) }

    /// Offsets below this are "slivers" that get the end-of-page bounce checks in
    /// `appendLive`. Kept at the old viewport-relative scale (~1/6) on purpose: shrinking
    /// it with `minShift` would exempt the newly-accepted small offsets from exactly the
    /// over-scroll/duplicate guards they need most.
    private func sliverBand(_ height: Int) -> Int { max(2 * minShift(height), height / 4) }

    /// Best downward offset `d` (>0 ⇒ `new` == `prev` scrolled up by `d`, i.e. we
    /// scrolled DOWN) and its mean per-pixel abs-diff (lower = more confident), measured
    /// only over the moving content band [headerH, height-footerH). Seeds the search
    /// around `predicted` and falls back to a full search if that isn't confident.
    private struct OffsetMatch {
        let offset: Int
        let score: Double
        let secondScore: Double
        let isAmbiguous: Bool
        var top = 0
        var bottom = 0
    }

    /// Refine adjacent pixel rows against actual colored glyphs, not just row
    /// averages. A strong physical match also avoids an expensive reverse search.
    private func pixelRefinedOffset(from previous: Frame, to current: Frame,
                                    match: OffsetMatch) -> (OffsetMatch, Double) {
        guard !match.isAmbiguous, match.score <= confidenceLimit,
              match.offset >= minShift(previous.height) else { return (match, .infinity) }
        var best = match
        var bestScore = pixelAlignmentScore(previous.image, current.image, match)
        if bestScore <= 0.5 { return (match, bestScore) }
        let low = max(minShift(previous.height), match.offset - 2)
        let high = min(previous.height - match.top - match.bottom - 1, match.offset + 2)
        guard high >= low else { return (match, .infinity) }
        for offset in low...high where offset != match.offset {
            let candidate = OffsetMatch(offset: offset, score: match.score, secondScore: match.secondScore,
                                    isAmbiguous: match.isAmbiguous, top: match.top, bottom: match.bottom)
            let score = pixelAlignmentScore(previous.image, current.image, candidate)
            if score < bestScore { best = candidate; bestScore = score }
        }
        return (best, bestScore)
    }

    private func pixelAlignmentScore(_ a: CGImage, _ b: CGImage, _ match: OffsetMatch) -> Double {
        guard a.width == b.width, a.height == b.height,
              let ad = a.dataProvider?.data, let bd = b.dataProvider?.data,
              let ap = CFDataGetBytePtr(ad), let bp = CFDataGetBytePtr(bd) else { return .infinity }
        func layout(_ image: CGImage) -> (stride: Int, r: Int, g: Int, b: Int)? {
            guard image.bitsPerComponent == 8 else { return nil }
            if image.bitsPerPixel == 8, image.colorSpace?.model == .monochrome { return (1, 0, 0, 0) }
            guard image.bitsPerPixel == 32, image.colorSpace?.model == .rgb else { return nil }
            let first = image.alphaInfo == .premultipliedFirst || image.alphaInfo == .first || image.alphaInfo == .noneSkipFirst
            let little = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
            if little { return first ? (4, 2, 1, 0) : (4, 3, 2, 1) }
            return first ? (4, 1, 2, 3) : (4, 0, 1, 2)
        }
        guard let al = layout(a), let bl = layout(b),
              CFDataGetLength(ad) >= a.bytesPerRow * a.height,
              CFDataGetLength(bd) >= b.bytesPerRow * b.height else { return .infinity }
        let end = a.height - match.bottom - match.offset
        guard end > match.top else { return .infinity }
        let inset = min(20, a.width / 20)
        let columnStep = max(1, a.width / 64)
        var sum = 0, count = 0
        // Every vertical row matters at Retina scale. Stagger the horizontal probes
        // to keep narrow section numbers visible without reading the entire image.
        for row in match.top..<end {
            let ar = ap.advanced(by: (row + match.offset) * a.bytesPerRow)
            let br = bp.advanced(by: row * b.bytesPerRow)
            let firstX = inset + (row % 3) * columnStep / 3
            for x in stride(from: firstX, to: a.width - inset, by: columnStep) {
                let ax = x * al.stride, bx = x * bl.stride
                let r1 = Int(ar[ax + al.r]), g1 = Int(ar[ax + al.g]), b1 = Int(ar[ax + al.b])
                let r2 = Int(br[bx + bl.r]), g2 = Int(br[bx + bl.g]), b2 = Int(br[bx + bl.b])
                if min(r1, g1, b1) >= 245, min(r2, g2, b2) >= 245 { continue }
                sum += abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2)
                count += 3
            }
        }
        return count > 0 ? Double(sum) / Double(count) : .infinity
    }

    private func downOffset(
        _ prev: [UInt8], _ new: [UInt8], height: Int,
        headerH: Int, footerH: Int, predicted: Int,
        forceFullSearch: Bool = false
    ) -> OffsetMatch {
        let hTop = max(0, min(headerH, height))
        let hBot = max(0, min(footerH, height))
        let minD = minShift(height)
        if regionMAD(prev, new, from: hTop, to: height - hBot) == 0 {
            return OffsetMatch(
                offset: 0, score: 0, secondScore: .greatestFiniteMagnitude,
                isAmbiguous: false
            )
        }

        func inferredFixedEdges(at offset: Int) -> (top: Int, bottom: Int) {
            guard offset >= minD else { return (0, 0) }
            func isFixed(_ row: Int) -> Bool {
                let stayed = rowMAD(new, prev, row, row)
                let moved: Double
                if row + offset < height {
                    moved = rowMAD(new, prev, row, row + offset)
                } else if row - offset >= 0 {
                    moved = rowMAD(new, prev, row - offset, row)
                } else {
                    return false
                }
                return isFixedRow(stayed: stayed, moved: moved)
            }

            let limit = height / 3
            var top = 0
            while top < limit, isFixed(top) { top += 1 }
            var bottom = 0
            while bottom < limit, isFixed(height - 1 - bottom) { bottom += 1 }
            guard top + bottom < height / 2 else { return (0, 0) }
            return (top, bottom)
        }

        // Use the event delta only to propose fixed edges; every row still has to prove
        // it stayed put relative to the proposed image shift. Once found, excluding a
        // sticky browser bar keeps the ordinary seeded correlation fast.
        if (hTop == 0 || hBot == 0), predicted >= minD {
            let inferred = inferredFixedEdges(at: predicted)
            let inferredTop = hTop == 0 && inferred.top >= 4 ? inferred.top : hTop
            let inferredBottom = hBot == 0 && inferred.bottom >= 4 ? inferred.bottom : hBot
            if inferredTop != hTop || inferredBottom != hBot {
                return downOffset(
                    prev, new, height: height,
                    headerH: inferredTop, footerH: inferredBottom,
                    predicted: predicted, forceFullSearch: forceFullSearch
                )
            }
        }

        let contentH = height - hTop - hBot
        guard contentH > 8 else {
            return OffsetMatch(offset: 0, score: .greatestFiniteMagnitude,
                secondScore: .greatestFiniteMagnitude, isAmbiguous: false)
        }
        // Fast wheel steps can leave less than 1/6 of a viewport while still sharing
        // several complete text rows. Excluding their true offset let a repeated
        // paragraph at a smaller offset win and silently omit an entire section.
        let minimumOverlap = max(min(64, contentH / 6), contentH / 12)
        let maxD = max(minD, contentH - minimumOverlap)

        // Integer-pixel scrolling preserves row signatures. Hash every row first to
        // locate exact translation candidates in O(height), then verify their ENTIRE
        // overlap with the same ink/confidence/ambiguity rules as the general matcher.
        // Repeated blank rows never vote; ambiguous or re-rendered content falls back.
        let exactCandidates = exactRowOffsets(prev, new, height: height, minD: minD, maxD: maxD)

        func search(_ lo: Int, _ hi: Int, inferUnknownEdges: Bool, candidates: [Int]? = nil) -> OffsetMatch {
            var bestOffset = 0
            var bestScore = Double.greatestFiniteMagnitude
            var bestTop = hTop, bestBottom = hBot
            var scored: [(offset: Int, score: Double)] = []
            let top = min(hi, maxD)
            for d in candidates ?? Array(max(minD, lo)...max(max(minD, lo), top)) where d <= top {
                // Before warm-up has committed sticky bands, score each candidate after
                // excluding only the edge rows that pixel evidence says stayed fixed at
                // that candidate shift. This prevents a large footer from making the
                // smallest offset win while avoiding the old absolute test that mistook
                // white article margins for fixed chrome.
                let inferred = inferUnknownEdges && (hTop == 0 || hBot == 0)
                    ? inferredFixedEdges(at: d)
                    : (top: hTop, bottom: hBot)
                let candidateTop = hTop == 0 ? inferred.top : hTop
                let candidateBottom = hBot == 0 ? inferred.bottom : hBot
                var sum = 0
                var uncappedSum = 0
                var count = 0
                var r = candidateTop
                let rEnd = height - candidateBottom - d
                while r < rEnd {
                    let a = r * columns
                    let b = (r + d) * columns
                    var c = 0
                    while c < columns {
                        let newValue = new[a + c]
                        let previousValue = prev[b + c]
                        // White page background otherwise dominates sparse articles and
                        // makes many wrong line-height offsets look equally excellent.
                        // Score pixels carrying visible ink in either frame; dark-mode
                        // pages naturally score every sample through this same path.
                        if min(newValue, previousValue) < 240 {
                            // A few fixed toolbar/footer pixels can be much darker than a
                            // sparse article and dominate an otherwise exact candidate.
                            // Cap each sample's influence so alignment is decided by broad
                            // overlap support; periodic alternatives still face the
                            // independent best-vs-runner-up ambiguity gate below.
                            let difference = abs(Int(newValue) - Int(previousValue))
                            sum += min(correlationDifferenceCap, difference)
                            uncappedSum += difference
                            count += 1
                        }
                        c += 1
                    }
                    r += candidates == nil ? rowStride : 1
                }
                if count > 0 {
                    // Robust ranking must not turn unrelated high-entropy frames into a
                    // plausible join. The original uncapped confidence gate remains the
                    // admission test; only candidates that pass it may compete by their
                    // outlier-bounded score.
                    let uncappedScore = Double(uncappedSum) / Double(count)
                    guard uncappedScore <= confidenceLimit else {
                        continue
                    }
                    let score = Double(sum) / Double(count)
                    scored.append((d, score))
                    // Exhaustive row verification resolves adjacent one-pixel choices;
                    // a score tolerance here silently removed rows from Retina scrolls.
                    if score < bestScore - (candidates == nil ? ambiguityMargin : 0.000001)
                        || (candidates == nil && abs(score - bestScore) <= ambiguityMargin
                            && predicted >= minD
                            && abs(d - predicted) < abs(bestOffset - predicted)) {
                        bestScore = score
                        bestOffset = d
                        bestTop = candidateTop
                        bestBottom = candidateBottom
                    }
                }
            }
            // Adjacent offsets naturally have similar scores on antialiased content; only
            // a second peak at least one real-motion quantum away is a competing alignment.
            let second = scored.lazy
                .filter { abs($0.offset - bestOffset) >= minD }
                .map(\.score)
                .min() ?? .greatestFiniteMagnitude
            let ambiguous = bestScore <= confidenceLimit
                && second <= confidenceLimit
                && second - bestScore <= ambiguityMargin
            return OffsetMatch(offset: bestOffset, score: bestScore,
                secondScore: second, isAmbiguous: ambiguous, top: bestTop, bottom: bestBottom)
        }

        func refinePixelOffset(_ match: OffsetMatch) -> OffsetMatch {
            guard !match.isAmbiguous, match.score <= confidenceLimit, match.offset >= minD else { return match }
            let lo = max(minD, match.offset - minD)
            let hi = min(maxD, match.offset + minD)
            let refined = search(lo, hi, inferUnknownEdges: true, candidates: Array(lo...hi))
            // The coarse search still owns distant-peak ambiguity. Refinement reads
            // every row, so display dithering cannot alias a 2x/3x glyph row to its
            // neighbour merely because the coarse search sampled every third row.
            return refined.score <= confidenceLimit ? refined : match
        }

        if !exactCandidates.isEmpty {
            let exact = search(minD, maxD, inferUnknownEdges: true, candidates: exactCandidates)
            // A hash is only a proposal, never proof. Require a strong full-row
            // match, including the uncapped admission test and competing candidates.
            // Fingerprints can also hit a repeated paragraph. Only a near-exact
            // verification may bypass the full search; the old score < 8 admitted
            // the wrong card before checking a shorter, genuine overlap elsewhere.
            if exact.score <= 1, !exact.isAmbiguous { return refinePixelOffset(exact) }
        }

        func searchWithFixedEdgeFallback(_ lo: Int, _ hi: Int) -> OffsetMatch {
            let raw = search(lo, hi, inferUnknownEdges: false)
            // Most pages need one ordinary correlation only. Pay for candidate-specific
            // sticky-edge inference when fixed chrome actually prevented a confident
            // whole-viewport match.
            if (hTop == 0 || hBot == 0), raw.score > confidenceLimit {
                return search(lo, hi, inferUnknownEdges: true)
            }
            return raw
        }

        let initial: OffsetMatch
        if forceFullSearch {
            initial = searchWithFixedEdgeFallback(minD, maxD)
        } else if predicted >= minD {
            let slack = max(minD, Int(Double(predicted) * 0.6))
            let seeded = searchWithFixedEdgeFallback(predicted - slack, predicted + slack)
            // A low-contrast page can produce several merely-low seeded scores even
            // when it stopped short of the requested wheel delta. Only let the seed
            // narrow the result when it identifies one alignment; otherwise the full
            // search must get a chance to find the small, exact end-of-page remainder.
            if seeded.score <= confidenceLimit, !seeded.isAmbiguous {
                initial = seeded
            } else {
                initial = searchWithFixedEdgeFallback(minD, maxD)
            }
        } else {
            initial = searchWithFixedEdgeFallback(minD, maxD)
        }

        return refinePixelOffset(initial)
    }

    private func exactRowOffsets(_ previous: [UInt8], _ current: [UInt8], height: Int,
                                 minD: Int, maxD: Int) -> [Int] {
        func fingerprint(_ signature: [UInt8], _ row: Int) -> UInt64 {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for column in 0..<columns {
                hash = (hash ^ UInt64(signature[row * columns + column])) &* 1_099_511_628_211
            }
            return hash
        }
        var rows: [UInt64: [Int]] = [:]
        for row in 0..<height {
            rows[fingerprint(previous, row), default: []].append(row)
        }
        var votes = [Int](repeating: 0, count: maxD + 1)
        var participatingRows = 0
        for row in stride(from: 0, to: height - minD, by: 3) {
            guard let matches = rows[fingerprint(current, row)], matches.count <= 16 else { continue }
            var participated = false
            for oldRow in matches {
                let offset = oldRow - row
                guard offset >= minD, offset <= maxD else { continue }
                votes[offset] += 1
                participated = true
            }
            if participated { participatingRows += 1 }
        }
        guard let strongest = votes.max(), strongest >= max(6, participatingRows / 4) else { return [] }
        let candidates = (minD...maxD).filter { votes[$0] >= max(3, strongest / 4) }
        // A large periodic family needs the exhaustive ambiguity check.
        return candidates.count <= 24 ? candidates : []
    }

    // MARK: - Pixel helpers

    private func makeFrame(_ image: CGImage, predictedOffset: Int, settled: Bool) -> Frame? {
        guard let sig = rowSignature(image) else { return nil }
        return Frame(
            image: image, sig: sig, height: image.height, width: image.width,
            predictedOffset: predictedOffset, settled: settled
        )
    }

    private func rowSignature(_ image: CGImage) -> [UInt8]? {
        let h = image.height
        guard h > 0 else { return nil }
        if let signature = sampledRowSignature(image) { return signature }
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
        return withExtendedLifetime(ctx) {
            Array(UnsafeBufferPointer(start: ptr, count: columns * h))
        }
    }

    /// Read a small, distributed set of source pixels per row. Converting the entire
    /// Retina image through a grayscale CGContext cost more than a 120 Hz interval
    /// by itself. This preserves every vertical row and avoids that full-image pass.
    /// Unsupported pixel layouts retain the Core Graphics conversion above.
    private func sampledRowSignature(_ image: CGImage) -> [UInt8]? {
        guard image.bitsPerComponent == 8, image.width > 0,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              CFDataGetLength(data) >= image.bytesPerRow * image.height else { return nil }
        let bytesPerPixel: Int
        let channels: (Int, Int, Int)
        if image.bitsPerPixel == 8, image.colorSpace?.model == .monochrome {
            bytesPerPixel = 1
            channels = (0, 0, 0)
        } else if image.bitsPerPixel == 32, image.colorSpace?.model == .rgb {
            bytesPerPixel = 4
            let first = image.alphaInfo == .premultipliedFirst || image.alphaInfo == .first || image.alphaInfo == .noneSkipFirst
            let little = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
            channels = little ? (first ? (2, 1, 0) : (3, 2, 1)) : (first ? (1, 2, 3) : (0, 1, 2))
        } else { return nil }
        let samples = min(8, max(1, image.width / columns))
        var locations = [[Int]]()
        for column in 0..<columns {
            var offsets = [Int]()
            for sample in 0..<samples {
                let fraction = Double(column) + (Double(sample) + 0.5) / Double(samples)
                let pixel = min(image.width - 1, Int(fraction * Double(image.width) / Double(columns)))
                offsets.append(pixel * bytesPerPixel)
            }
            locations.append(offsets)
        }
        var result = [UInt8](repeating: 0, count: columns * image.height)
        for row in 0..<image.height {
            let base = bytes.advanced(by: row * image.bytesPerRow)
            for column in 0..<columns {
                var sum = 0
                for x in locations[column] {
                    sum += Int(base[x + channels.0]) * 77 + Int(base[x + channels.1]) * 150 + Int(base[x + channels.2]) * 29
                }
                result[row * columns + column] = UInt8(sum / (samples * 256))
            }
        }
        return result
    }

    /// The newly revealed content in `image`: the `offset` rows just above the footer.
    private func cropContent(_ image: CGImage, offset: Int, footerH: Int) -> CGImage? {
        let top = image.height - footerH - offset
        guard offset > 0, top >= 0 else { return nil }
        guard let cropped = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: offset)) else { return nil }
        return makeIndependentCopy(of: cropped)
    }

    /// Crops rows [y, y+height) — CGImage coordinates are top-left origin.
    private func crop(_ image: CGImage, y: Int, height: Int) -> CGImage? {
        guard height > 0, y >= 0, y + height <= image.height else { return nil }
        guard let cropped = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)) else { return nil }
        return makeIndependentCopy(of: cropped)
    }

    private func makeIndependentCopy(of image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        let bitsPerComponent = image.bitsPerComponent
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = image.bitmapInfo

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return image
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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
