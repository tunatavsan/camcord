import AppKit
import CoreMedia
@preconcurrency import ScreenCaptureKit
import os

/// Main-actor ownership gate for every capture that can feed the scroll stitcher.
/// Tokens prevent an older completion from releasing a newer owner's slot.
@MainActor
final class ScrollCaptureSlot {
    struct Token: Equatable, Sendable {
        fileprivate let id: UInt64
    }

    private var nextID: UInt64 = 0
    private var owner: Token?

    var isOccupied: Bool { owner != nil }
    func owns(_ token: Token) -> Bool { owner == token }

    func acquireIfAvailable() -> Token? {
        guard owner == nil else { return nil }
        nextID &+= 1
        let token = Token(id: nextID)
        owner = token
        return token
    }

    func release(_ token: Token) {
        guard owner == token else { return }
        owner = nil
    }
}

/// Wheel input can arrive while a resting-frame capture is awaiting the image.
/// An older completion may not clear the new gesture's pending resting pixels.
struct ScrollCaptureDebt {
    var accumulatedDeltaPoints: CGFloat = 0
    var settleGeneration = 0
    var pendingCapture = false
    var pendingSettledCapture = false
    var needsSettledFrame = false

    @discardableResult
    mutating func resolveSettledFrame(succeeded: Bool, generation: Int) -> Bool {
        guard succeeded, generation == settleGeneration else { return false }
        needsSettledFrame = false
        return true
    }
}

/// Routes SCStream's async failure callback back to the session, so pumps fall back to
/// per-shot screenshots instead of stitching a frozen last frame forever.
private final class StreamFailureRelay: NSObject, SCStreamDelegate {
    private let onStop: @Sendable () -> Void
    init(onStop: @escaping @Sendable () -> Void) { self.onStop = onStop }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop() }
}

/// Serial pixel worker. Signature extraction, correlation, cropping, and preview
/// composition stay off the main actor while preserving strict frame order.
actor ScrollStitchWorker {
    struct Result: @unchecked Sendable {
        let outcome: ScrollStitcher.Outcome
        let preview: CGImage?
        let contentPixelHeight: Int
        let sectionCount: Int
        let hasUnresolvedContinuity: Bool
        let hasMissingBeginning: Bool
    }

    struct BatchResult: @unchecked Sendable {
        let lastSequence: UInt64
        let frameCount: Int
        let result: Result
    }

    struct RestingCaptureResult: @unchecked Sendable {
        let lastSequence: UInt64
        let result: Result?
        let error: Error?
    }

    private let stitcher = ScrollStitcher()
    private var missingInitialFrame = false
    private var previewDirty = false
    private var lastPreviewAt: ContinuousClock.Instant?

    /// Drain to a fixed sequence boundary, releasing each owned image as we go.
    func consumeFrames(from buffer: ScrollFrameBuffer, after sequence: UInt64, predictedOffset: Int) -> BatchResult? {
        guard let boundary = buffer.peekLatest()?.seq, boundary > sequence else { return nil }
        // Later evictions may still leave enough verified pixel overlap. Losing
        // the initial viewport is different: there is no retained top to recover.
        var lastSequence = sequence
        var count = 0
        var lastResult: Result?
        var newestPreview: CGImage?
        while let frame = buffer.takeNext(after: lastSequence, through: boundary) {
            if sequence == 0, count == 0, frame.seq != 1 { missingInitialFrame = true }
            let result = add(frame.image, predictedOffset: frame.seq == boundary && count == 0 ? predictedOffset : 0)
            if let preview = result.preview { newestPreview = preview }
            lastResult = result
            lastSequence = frame.seq
            count += 1
        }
        guard let result = lastResult else { return nil }
        return BatchResult(lastSequence: lastSequence, frameCount: count, result: Result(
            outcome: result.outcome, preview: newestPreview,
            contentPixelHeight: result.contentPixelHeight, sectionCount: result.sectionCount,
            hasUnresolvedContinuity: result.hasUnresolvedContinuity,
            hasMissingBeginning: result.hasMissingBeginning
        ))
    }

    /// Final verification keeps one temporal order: pending stream frames, then
    /// the fresh screenshot, then any frames accepted after intake resumes.
    /// The session capture slot prevents other writer calls during this await.
    func consumeRestingFrame(
        from buffer: ScrollFrameBuffer,
        after sequence: UInt64,
        predictedOffset: Int,
        capture: @Sendable () async throws -> CGImage
    ) async -> RestingCaptureResult {
        buffer.suspendIntake()
        defer { buffer.resumeIntake() }
        let batch = consumeFrames(from: buffer, after: sequence, predictedOffset: predictedOffset)
        let lastSequence = batch?.lastSequence ?? sequence
        do {
            let image = try await capture()
            return RestingCaptureResult(lastSequence: lastSequence,
                result: add(image, predictedOffset: 0, forcePreview: true, settled: true), error: nil)
        } catch {
            // Drained stream frames remain consumed even if the snapshot fails.
            return RestingCaptureResult(lastSequence: lastSequence, result: batch?.result, error: error)
        }
    }

    func add(_ image: CGImage, predictedOffset: Int, forcePreview: Bool = false, settled: Bool = false) -> Result {
        let outcome = stitcher.add(image, predictedOffset: predictedOffset, settled: settled)
        let changed = outcome == .appended || outcome == .baselined || outcome == .buffered
        previewDirty = previewDirty || changed
        let now = ContinuousClock.now
        let previewDue = lastPreviewAt.map { now - $0 >= .milliseconds(100) } ?? true
        let shouldRender = previewDirty && (forcePreview || previewDue)
        let preview = shouldRender ? stitcher.previewImage(maxWidth: 384) : nil
        if shouldRender {
            previewDirty = false
            lastPreviewAt = now
        }
        return Result(
            outcome: outcome,
            preview: preview,
            contentPixelHeight: stitcher.contentPixelHeight,
            sectionCount: stitcher.sectionCount,
            hasUnresolvedContinuity: missingInitialFrame || stitcher.hasUnresolvedContinuity,
            hasMissingBeginning: missingInitialFrame
        )
    }

    func state() -> (sections: Int, unresolved: Bool, missingBeginning: Bool) {
        (stitcher.sectionCount, missingInitialFrame || stitcher.hasUnresolvedContinuity, missingInitialFrame)
    }

    func finalImage() -> CGImage? { missingInitialFrame ? nil : stitcher.finalImage() }
}

/// Drives manual scrolling capture: the user can scroll the target window while we
/// collect each new cursor-free frame of the fixed region without waiting for a wheel
/// threshold, and stitch the ordered snapshots into one
/// tall image shown growing live in a side HUD. Ends on the HUD's Done (keep) or Esc /
/// Cancel (discard).
@MainActor
final class ScrollingCaptureSession {
    private let region: CGRect
    private let display: SCDisplay
    private let scale: CGFloat
    private let contentCache: ShareableContentCache
    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "scroll-session")

    private let stitcher = ScrollStitchWorker()
    private let indicator = CaptureAreaIndicator()
    private let preview = ScrollPreviewPanel()

    // Capture config — built in prepare() once our own HUD windows are on-screen so they
    // can be excluded from the capture. Optional (not IUO) so any capture attempted
    // before prepare() finishes safely no-ops instead of crashing on unwrap.
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?

    // Scroll monitoring + capture pump.
    private var scrollMonitors: [Any] = []
    private var captureDebt = ScrollCaptureDebt()
    private let captureSlot = ScrollCaptureSlot()
    private var prepared = false
    private var finished = false
    /// True from "Done" pressed until the final flush completes: blocks NEW captures
    /// while still letting the in-flight one finish and one last settled frame be grabbed.
    private var finishing = false
    /// Consecutive frame-capture failures; after a few in a row the session self-ends so
    /// it can't hang on-screen holding the app-wide exclusive-capture lock.
    private var captureFailures = 0
    private var hitHeightCap = false
    private let triggerPoints: CGFloat

    // Capture every refresh up to 120fps, including fast wheel/trackpad momentum.
    // The frame tap owns copies of pixels, so waiting for
    // stitching never retains ScreenCaptureKit's finite producer-surface pool.
    private var stream: SCStream?
    private var streamDelegate: StreamFailureRelay?
    /// Relay flagged a stop/failure. Set unconditionally (even before adoption): a stream
    /// that dies during the startup wait must never be adopted, or the session would
    /// stitch its frozen last frame forever with no fallback.
    private var streamFailed = false
    /// Sequence of the last stream frame fed to the stitcher — a re-peek of the same
    /// frame is skipped (stitching it again fakes a miss and defeats band voting).
    private var lastStitchedSeq: UInt64 = 0
    private lazy var frameTap = ScrollFrameBuffer { [weak self] in
        Task { @MainActor [weak self] in self?.streamFrameAvailable() }
    }
    private let tapQueue = DispatchQueue(label: "dev.tavsan.camcord.scroll-frames", qos: .userInitiated)

    private var continuation: CheckedContinuation<CGImage?, Never>?

    // MARK: - Diagnostics

    /// Field-diagnosable breadcrumbs: unified logging plus a small plain-text log at
    /// ~/Library/Logs/Camcord-scroll.log (Console.app picks it up), because `log show`
    /// access can't be assumed when someone needs to see why a capture went wrong.
    private static let diagURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Camcord-scroll.log")
    private static let diagnosticsQueue = DispatchQueue(label: "dev.tavsan.camcord.scroll-diagnostics", qos: .utility)

    private func diag(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let url = Self.diagURL
        let timestamp = Date()
        // A diagnostic disk write must never delay the scroll pump or input handling.
        // The serial utility queue also preserves event order across sessions.
        Self.diagnosticsQueue.async {
            let stamp = ISO8601DateFormatter().string(from: timestamp)
            let data = Data("\(stamp) \(message)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    init(region: CGRect, display: SCDisplay, contentCache: ShareableContentCache) {
        self.region = region
        self.display = display
        self.scale = CGFloat(SCContentFilter(display: display, excludingWindows: []).pointPixelScale)
        self.contentCache = contentCache
        // Only the slower per-shot fallback uses wheel thresholds. Live streaming
        // consumes every delivered frame independently of event distance.
        self.triggerPoints = max(60, region.height * 0.4)
    }

    /// Runs to completion. Returns the stitched image on Done, or nil if cancelled
    /// (Esc / İptal) or nothing usable was captured.
    func run() async -> CGImage? {
        indicator.show(cgRect: region, color: .systemBlue, label: nil, onStop: nil)
        preview.show(
            near: region,
            onDone: { [weak self] in self?.finish(keep: true) },
            onCancel: { [weak self] in self?.finish(keep: false) }
        )
        installMonitors()

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<CGImage?, Never>) in
                self.continuation = c
                // Build the capture filter (now the HUD windows exist, so they're excluded),
                // then take the baseline frame. Launched as a task so an immediate Cancel
                // during prepare still resolves `c` and can't deadlock.
                Task { @MainActor in
                    await self.prepare()
                    if !self.finished { self.pump(force: true) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(keep: false)
            }
        }
        teardown()
        return result
    }

    /// Builds the display filter EXCLUDING our own HUD/indicator windows (so they never
    /// bleed into the capture) and the region source-rect config.
    private func prepare() async {
        var excluded: [SCWindow] = []
        // Force-refresh: the HUD/preview windows were JUST created in run(), so a cached
        // (≤5s-old) snapshot predates them and the filter would fail to exclude them —
        // baking the HUD into every stitched frame. One refresh per session, still
        // bounded by the cache's own hard timeout.
        let content = try? await contentCache.content(forceRefresh: true)
        guard !finished else { return }
        if let content {
            let ownBundleID = Bundle.main.bundleIdentifier
            excluded = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleID }
        }
        filter = SCContentFilter(display: display, excludingWindows: excluded)

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
        // Stream-only knobs — SCScreenshotManager ignores them, so the per-shot
        // fallback shares this exact config (identical output dimensions matter: the
        // stitcher drops frames whose height differs from the reference).
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // One explicit profile for streamed pixels, the final screenshot and export.
        config.colorSpaceName = CGColorSpace.sRGB
        self.config = config
        await startStreamIfPossible()
        prepared = true
        diag("ready: size=\(config.width)x\(config.height) source=\(stream == nil ? "snapshot" : "stream")")
    }

    /// Starts the continuous frame stream and waits briefly for its first frame, so the
    /// baseline comes from the stream too. Any failure leaves `stream` nil — every pump
    /// then falls back to per-shot screenshots (slower, but the session still works).
    private func startStreamIfPossible() async {
        guard let filter, let config else { return }
        let relay = StreamFailureRelay { [weak self] in
            Task { @MainActor in self?.streamDidFail() }
        }
        let candidate = SCStream(filter: filter, configuration: config, delegate: relay)
        do {
            try candidate.addStreamOutput(frameTap, type: .screen, sampleHandlerQueue: tapQueue)
            try await withHardTimeout(.seconds(2), onTimeout: CaptureError.timeout) {
                try await candidate.startCapture()
            }
        } catch {
            diag("stream start failed — per-shot fallback: \(error)")
            frameTap.close()
            // The hard-timeout ABANDONS an in-flight startCapture(): it can still succeed
            // later and leave the stream capturing with nothing owning it. Stop it
            // explicitly — the call queues behind the pending start and is a harmless
            // no-op if the stream never started.
            Task.detached { try? await candidate.stopCapture() }
            return
        }
        for _ in 0..<20 where frameTap.peekLatest() == nil {
            try? await Task.sleep(for: .milliseconds(30))
        }
        // No frame in time, the session ended meanwhile, or the stream already DIED
        // during the wait (its failure callback runs while `stream` is still nil, so
        // only this flag can catch it): don't adopt.
        guard frameTap.peekLatest() != nil, !finished, !streamFailed else {
            diag(finished ? "session ended during stream start"
                : streamFailed ? "stream failed during start — per-shot fallback"
                : "stream produced no frame — per-shot fallback")
            frameTap.close()
            Task.detached { try? await candidate.stopCapture() }
            return
        }
        streamDelegate = relay
        stream = candidate
    }

    private func streamDidFail() {
        streamFailed = true
        guard stream != nil else { return }
        diag("stream failed mid-session — per-shot fallback")
        stream = nil
        frameTap.close()
        preview.flashHint("Ekran akışı kesildi · yeniden başlatabilirsiniz")
    }

    // MARK: - Scroll monitoring

    private func installMonitors() {
        let onScroll: @MainActor (NSEvent) -> Void = { [weak self] event in
            self?.handleScroll(event)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { event in
            Task { @MainActor in onScroll(event) }
        }) {
            scrollMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { event in
            MainActor.assumeIsolated { onScroll(event) }
            return event
        }) {
            scrollMonitors.append(local)
        }
        // Esc cancels (best-effort — a global key monitor needs Accessibility; the HUD's
        // İptal button is the always-available path).
        if let esc = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    self?.finish(keep: false)
                }
            }
        }) {
            scrollMonitors.append(esc)
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard !finished, !finishing else { return }
        captureDebt.accumulatedDeltaPoints += abs(event.scrollingDeltaY)
        captureDebt.needsSettledFrame = true
        armSettle()
        // The live path is driven by arriving pixels, not wheel-event thresholds.
        // Fallback still coalesces per-shot requests to avoid queuing expensive grabs.
        if stream == nil, captureDebt.accumulatedDeltaPoints >= triggerPoints { pump() }
    }

    /// After a short quiet period, grab one more frame so the last bit scrolled (and any
    /// inertial glide) is captured — the only settle signal for classic wheel mice, which
    /// carry no scroll phase.
    private func armSettle() {
        captureDebt.settleGeneration &+= 1
        let generation = captureDebt.settleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            Task { @MainActor in
                guard let self, self.captureDebt.settleGeneration == generation,
                    !self.finished, !self.finishing
                else { return }
                if self.captureDebt.needsSettledFrame { self.pump(force: true, settled: true) }
            }
        }
    }

    // MARK: - Capture pump

    private func streamFrameAvailable() {
        guard prepared, stream != nil, !finished, !finishing else { return }
        pump(force: true)
    }

    /// Serialises captures: only one SCScreenshotManager call in flight, with a single
    /// pending follow-up so bursts of scroll events don't pile up.
    private func pump(force: Bool = false, settled: Bool = false) {
        guard !finished, !finishing else { return }
        // Scrolls can arrive before the filter is built; remember them so the baseline
        // capture (fired the instant prepare() finishes) picks them up.
        guard prepared else {
            captureDebt.pendingCapture = true
            return
        }
        guard let token = captureSlot.acquireIfAvailable() else {
            captureDebt.pendingCapture = true
            captureDebt.pendingSettledCapture = captureDebt.pendingSettledCapture || settled
            return
        }
        guard force || captureDebt.accumulatedDeltaPoints > 0 else {
            captureSlot.release(token)
            return
        }
        let predictedPoints = captureDebt.accumulatedDeltaPoints
        let settleGeneration = captureDebt.settleGeneration
        captureDebt.accumulatedDeltaPoints = 0
        Task { @MainActor in
            let evaluated = await self.captureAndStitch(
                owning: token,
                predictedPoints: predictedPoints
            )
            if settled {
                self.captureDebt.resolveSettledFrame(succeeded: evaluated, generation: settleGeneration)
            }
            if !evaluated { self.captureDebt.accumulatedDeltaPoints += predictedPoints }
            self.captureSlot.release(token)
            // Persistent failures (permission lost mid-session, wedged replayd) must not
            // strand the HUD holding the exclusive lock — end the session.
            if self.captureFailures >= 3, !self.finished, !self.finishing {
                self.logger.error("scroll capture: repeated frame failures; ending session")
                self.finish(keep: false)
                return
            }
            if self.captureDebt.pendingCapture, !self.finished, !self.finishing {
                let pendingWasSettled = self.captureDebt.pendingSettledCapture
                self.captureDebt.pendingCapture = false
                self.captureDebt.pendingSettledCapture = false
                self.pump(force: self.stream != nil || pendingWasSettled, settled: pendingWasSettled)
            }
        }
    }

    @discardableResult
    private func captureAndStitch(
        owning token: ScrollCaptureSlot.Token,
        predictedPoints: CGFloat,
        requireFreshFallback: Bool = false
    ) async -> Bool {
        guard captureSlot.owns(token) else { return false }
        // Never attempt a capture before the filter/config exist (a very fast Done can
        // reach the flush before prepare() finished) — safe no-op instead of a crash.
        guard let filter, let config else { return false }
        let predictedPx = Int((predictedPoints * scale).rounded())
        // Ordinary wheel settling stays on the continuous source. Final
        // verification owns an intake barrier while awaiting its fresh snapshot.
        if stream != nil, requireFreshFallback {
            let captured = await stitcher.consumeRestingFrame(
                from: frameTap, after: lastStitchedSeq, predictedOffset: predictedPx
            ) {
                try await withHardTimeout(.seconds(2), onTimeout: CaptureError.timeout) {
                    try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                }
            }
            guard !finished else { return false }
            lastStitchedSeq = captured.lastSequence
            if let result = captured.result { apply(result) }
            if let error = captured.error {
                logger.error("scroll final capture failed: \(String(describing: error), privacy: .public)")
                captureFailures += 1
                return false
            }
            captureFailures = 0
            return true
        }
        if stream != nil {
            if let batch = await stitcher.consumeFrames(from: frameTap, after: lastStitchedSeq, predictedOffset: predictedPx) {
                guard !finished else { return false }
                lastStitchedSeq = batch.lastSequence
                captureFailures = 0
                apply(batch.result)
                let stats = frameTap.stats
                diag("stream batch: frames=\(batch.frameCount) through=\(batch.lastSequence) pending=\(stats.pendingFrameCount) dropped=\(stats.droppedFrames) stitchedPx=\(batch.result.contentPixelHeight) outcome=\(batch.result.outcome) unresolved=\(batch.result.hasUnresolvedContinuity)")
                return true
            }
            return false
        }

        let image: CGImage
        do {
            image = try await withHardTimeout(.seconds(2), onTimeout: CaptureError.timeout) {
                try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            }
        } catch {
            logger.error("scroll frame capture failed: \(String(describing: error), privacy: .public)")
            captureFailures += 1
            return false
        }
        captureFailures = 0
        await consume(image, predictedPx: predictedPx, forcePreview: requireFreshFallback, settled: requireFreshFallback)
        return true
    }

    private func consume(_ image: CGImage, predictedPx: Int, forcePreview: Bool = false, settled: Bool = false) async {
        guard !finished else { return }
        let result = await stitcher.add(image, predictedOffset: predictedPx, forcePreview: forcePreview, settled: settled)
        guard !finished else { return }
        diag("frame: \(String(describing: result.outcome)) predictedPx=\(predictedPx) stitchedPx=\(result.contentPixelHeight) sections=\(result.sectionCount)")
        apply(result)
    }

    private func apply(_ result: ScrollStitchWorker.Result) {
        if let image = result.preview { preview.update(image: image, sections: result.sectionCount) }
        if result.hasMissingBeginning {
            preview.setBlockingHint("İlk kare kaçtı · İptal edip yeniden başlat")
            return
        }
        if !result.hasUnresolvedContinuity, !hitHeightCap { preview.setBlockingHint(nil) }
        if result.hasUnresolvedContinuity {
            preview.setBlockingHint(result.outcome == .ambiguous
                ? "Tekrarlı içerik · daha kısa kaydır" : "Boşluk var · biraz geri kaydır")
        }
        switch result.outcome {
        case .appended, .baselined, .buffered:
            if !result.hasUnresolvedContinuity { preview.setBlockingHint(nil) }
        case .ignored, .movedUp:
            break
        case .lost:
            preview.setBlockingHint("Boşluk var · biraz geri kaydır")
        case .ambiguous:
            preview.setBlockingHint("Tekrarlı içerik · daha kısa kaydır")
        case .atCap:
            hitHeightCap = true
            preview.setBlockingHint("40.000 px sınırı · İptal edip alanı küçült")
        }
    }

    // MARK: - Finish

    private func finish(keep: Bool) {
        guard !finished else { return }
        // Cancel remains immediate while the final screenshot/merge is awaiting work.
        // Only a second Done is redundant during that verification.
        guard !keep || !finishing else { return }
        // Cancel is immediate — discard whatever's stitched.
        guard keep else {
            finished = true
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }
        // Done flushes outstanding work so the last frame isn't lost: wait out any
        // in-flight capture, then grab one final settled frame if the user scrolled since.
        finishing = true
        preview.setFinishing(true)
        Task { @MainActor in await self.flushAndFinalize() }
    }

    private func flushAndFinalize() async {
        // Bounded wait for the in-flight capture (itself hard-timeout'd at 2s).
        var spins = 0
        while captureSlot.isOccupied, spins < 200, !finished {
            try? await Task.sleep(for: .milliseconds(16))
            spins += 1
        }
        guard !finished else { return }
        guard let token = captureSlot.acquireIfAvailable() else {
            finishing = false
            preview.setFinishing(false)
            preview.setBlockingHint("Kare hâlâ işleniyor · yeniden Bitti")
            return
        }
        // One last frame at the resting position if anything scrolled since the last grab
        // (or nothing has been captured yet). captureAndStitch itself guards prepared/nil.
        var stitchState = await stitcher.state()
        guard !finished else {
            captureSlot.release(token)
            return
        }
        guard prepared else {
            captureSlot.release(token)
            finishing = false
            preview.setFinishing(false)
            preview.setBlockingHint("Yakalama hazırlanamadı · yeniden deneyin")
            return
        }
        let evaluated = await captureAndStitch(
            owning: token,
            predictedPoints: captureDebt.accumulatedDeltaPoints,
            requireFreshFallback: true
        )
        captureSlot.release(token)
        guard !finished else { return }
        guard evaluated else {
            finishing = false
            preview.setFinishing(false)
            preview.setBlockingHint("Son kare alınamadı · yeniden Bitti")
            return
        }
        captureDebt.accumulatedDeltaPoints = 0
        captureDebt.needsSettledFrame = false
        stitchState = await stitcher.state()
        let final = await stitcher.finalImage()
        guard !finished else { return }
        guard !captureDebt.needsSettledFrame, !hitHeightCap, !stitchState.unresolved,
            let final
        else {
            finishing = false
            preview.setFinishing(false)
            preview.setBlockingHint(stitchState.missingBeginning
                ? "İlk kare kaçtı · İptal edip yeniden başlat"
                : hitHeightCap
                ? "40.000 px sınırı · İptal edip alanı küçült"
                : "Eksik bağlantı · geri kaydırıp yeniden Bitti")
            return
        }
        finished = true
        continuation?.resume(returning: final)
        continuation = nil
    }

    private func teardown() {
        captureDebt.settleGeneration &+= 1
        if let stream {
            self.stream = nil
            Task.detached { try? await stream.stopCapture() }
        }
        streamDelegate = nil
        frameTap.close()
        for monitor in scrollMonitors { NSEvent.removeMonitor(monitor) }
        scrollMonitors = []
        indicator.hide()
        preview.hide()
    }
}
