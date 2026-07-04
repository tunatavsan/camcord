import CoreGraphics
@preconcurrency import ScreenCaptureKit
import Foundation
import os

/// Company-grade scrolling capture: scroll a region, screenshot each SETTLED viewport,
/// measure the real pixel shift between frames, and stitch the newly revealed strips
/// into one tall image.
///
/// Lessons baked in (from how production tools do this):
///  • The hard problem is FRAME TIMING, not alignment — capturing mid-scroll yields a
///    blurry/partial frame that breaks matching. So after each scroll we poll (with
///    exponential backoff) until two consecutive captures are byte-identical (settled).
///  • Scroll DIRECTION is user/app dependent (natural scrolling, Electron/web remaps),
///    so we never hardcode a sign — we probe once and flip if the content didn't move
///    down, trusting the MEASURED shift.
///  • Every capture is a fresh one-shot `SCScreenshotManager.captureImage` with the
///    cursor excluded (a static cursor over the region pollutes both settlement and the
///    stitch).
///  • Two independent stop counters (no-match vs zero-shift) plus a hard height cap,
///    so a transient hiccup doesn't truncate and a non-scrolling area doesn't loop.
///  • The whole loop is cancellable via `Task` — `capture` returns whatever it has
///    stitched so far when cancelled.
enum ScrollingCaptureService {
    private static let logger = Logger(subsystem: "dev.tavsan.camcord", category: "scrolling-capture")

    // Tunables.
    private static let columns = 24              // row-signature downsample width
    private static let rowStride = 2
    private static let maxFrames = 200
    private static let maxTotalHeight = 30_000   // px safety cap
    private static let confidenceLimit = 22.0    // mean abs-diff above which a match is untrusted
    private static let settleInitial: Double = 0.012
    private static let settleCap: Double = 0.08
    private static let settleMaxPolls = 30
    private static let zeroShiftStop = 5
    private static let noMatchStop = 8

    private struct Frame {
        let image: CGImage
        let sig: [UInt8]
        let height: Int
        let width: Int
    }

    /// `region` in global CG points; `display` is the SCDisplay it lies on. Runs in the
    /// caller's Task and honours cancellation (returns the partial stitch).
    static func capture(region: CGRect, display: SCDisplay) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(
            x: region.minX - display.frame.minX,
            y: region.minY - display.frame.minY,
            width: region.width, height: region.height
        )
        config.width = RegionClamp.evenFloor(region.width * scale)
        config.height = RegionClamp.evenFloor(region.height * scale)
        config.showsCursor = false
        config.captureResolution = .best

        // Warp the pointer into the region so scroll events land on that window; restore
        // it when we're done. (CGEvent locations are top-left CG coordinates.)
        let originalPointer = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(CGPoint(x: region.midX, y: region.midY))
        defer { if let originalPointer { CGWarpMouseCursorPosition(originalPointer) } }

        guard let baseline = try await settledFrame(filter: filter, config: config) else {
            throw CaptureError.timeout
        }
        let step = Int(max(80, region.height * 0.55))
        let probe = Int(max(60, region.height * 0.3))

        // First-guess sign from the OS setting; calibration verifies + flips if wrong.
        let naturalScroll = UserDefaults.standard.bool(forKey: "com.apple.swipescrolldirection")
        var sign = naturalScroll ? 1 : -1
        var reference = baseline
        var strips: [CGImage] = []
        var totalHeight = baseline.height

        do {
            // Direction calibration: probe, and flip + undo if the content didn't move down.
            var firstMoveDone = false
            for attempt in 0..<2 {
                postScroll(sign * probe)
                guard let f = try await settledFrame(filter: filter, config: config) else { break }
                let (offset, score) = downOffset(reference.sig, f.sig, height: reference.height)
                if score <= confidenceLimit, offset >= minShift(reference.height) {
                    if let strip = crop(f.image, bottomRows: offset) {
                        strips.append(strip)
                        totalHeight += offset
                    }
                    reference = f
                    firstMoveDone = true
                    break
                }
                // Wrong direction / no scroll — undo and try the other sign next.
                postScroll(-sign * probe)
                if let rebaseline = try await settledFrame(filter: filter, config: config) {
                    reference = rebaseline
                }
                sign = -sign
                if attempt == 1 { break }
            }

            if firstMoveDone {
                var zeroShift = 0
                var noMatch = 0
                for _ in 0..<maxFrames {
                    try Task.checkCancellation()
                    postScroll(sign * step)
                    guard let f = try await settledFrame(filter: filter, config: config),
                        f.height == reference.height
                    else { break }

                    let (offset, score) = downOffset(reference.sig, f.sig, height: reference.height)
                    if score > confidenceLimit {
                        noMatch += 1
                        if noMatch >= noMatchStop { break }
                        continue
                    }
                    noMatch = 0
                    if offset < minShift(reference.height) {
                        zeroShift += 1
                        if zeroShift >= zeroShiftStop { break }
                        continue
                    }
                    zeroShift = 0
                    guard let strip = crop(f.image, bottomRows: offset) else { break }
                    strips.append(strip)
                    totalHeight += offset
                    reference = f
                    if totalHeight >= maxTotalHeight { break }
                }
            } else {
                logger.notice("Scroll capture: area does not scroll; returning single frame")
            }
        } catch is CancellationError {
            logger.notice("Scroll capture cancelled; stitching partial result")
        } catch {
            logger.error("Scroll capture error mid-run; stitching partial: \(String(describing: error), privacy: .public)")
        }

        return compose(top: baseline.image, strips: strips) ?? baseline.image
    }

    /// The smallest offset (px) that counts as "the page actually moved" — ~10% of the
    /// viewport, so momentum jitter and sub-line wheel steps don't register as content.
    private static func minShift(_ height: Int) -> Int { max(8, height / 10) }

    // MARK: - Capture + settlement

    private static func settledFrame(filter: SCContentFilter, config: SCStreamConfiguration) async throws -> Frame? {
        var previous = try await captureFrame(filter: filter, config: config)
        var interval = settleInitial
        for _ in 0..<settleMaxPolls {
            try Task.checkCancellation()
            try? await Task.sleep(for: .seconds(interval))
            let current = try await captureFrame(filter: filter, config: config)
            if current.sig == previous.sig {
                return current  // two identical polls: animation/inertia has settled
            }
            previous = current
            interval = min(interval * 1.5, settleCap)
        }
        return previous  // never fully settled; use the last (best-effort)
    }

    private static func captureFrame(filter: SCContentFilter, config: SCStreamConfiguration) async throws -> Frame {
        let image = try await withHardTimeout(.seconds(3), onTimeout: CaptureError.timeout) {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
        guard let sig = rowSignature(image, columns: columns) else {
            throw CaptureError.timeout
        }
        return Frame(image: image, sig: sig, height: image.height, width: image.width)
    }

    // MARK: - Scroll synthesis

    /// Positive `pixels` scrolls the wheel one way, negative the other — the caller
    /// (via calibration) decides which sign means "down".
    private static func postScroll(_ pixels: Int) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: Int32(pixels), wheel2: 0, wheel3: 0
        ) else { return }
        // Tag as ours so a user-input monitor can tell it apart from real scrolling.
        event.setIntegerValueField(.eventSourceUserData, value: scrollEventMarker)
        event.post(tap: .cghidEventTap)
    }

    static let scrollEventMarker: Int64 = 0x43_4D_43_44  // "CMCD"

    // MARK: - Row signatures + downward-offset detection

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
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)  // buffer row 0 == image top row
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: h))
        guard let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: columns * h)
        return Array(UnsafeBufferPointer(start: ptr, count: columns * h))
    }

    /// Best downward offset `d` (>0 means `new` == `prev` scrolled up by `d`, i.e. we
    /// scrolled DOWN) and its mean per-pixel abs-diff (lower = more confident). A frame
    /// that actually scrolled up (or didn't move) yields no good downward match → a
    /// high (untrusted) score.
    private static func downOffset(_ prev: [UInt8], _ new: [UInt8], height: Int) -> (offset: Int, score: Double) {
        var bestOffset = 0
        var bestScore = Double.greatestFiniteMagnitude
        var d = 4
        while d < height {
            let overlap = height - d
            if overlap <= height / 6 { break }
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

    // MARK: - Crop + compose

    private static func crop(_ image: CGImage, bottomRows: Int) -> CGImage? {
        let d = min(bottomRows, image.height)
        guard d > 0 else { return nil }
        return image.cropping(to: CGRect(x: 0, y: image.height - d, width: image.width, height: d))
    }

    private static func compose(top: CGImage, strips: [CGImage]) -> CGImage? {
        let width = top.width
        let totalHeight = top.height + strips.reduce(0) { $0 + $1.height }
        guard totalHeight > 0 else { return nil }
        let rgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Bottom-up context: the first piece belongs at the top (highest y).
        var yFromTop = 0
        for piece in [top] + strips {
            let yBottom = totalHeight - yFromTop - piece.height
            ctx.draw(piece, in: CGRect(x: 0, y: yBottom, width: width, height: piece.height))
            yFromTop += piece.height
        }
        return ctx.makeImage()
    }
}
