import AppKit
import ApplicationServices
@preconcurrency import ScreenCaptureKit
import os

/// Serial ownership of the existing matcher and raster composition. Only immutable
/// snapshots cross back to the main actor; captures remain single-flight in the session.
actor ScrollStitchWorker {
    struct State: Sendable {
        var firstFrame: ScrollStitcher.Frame?
        var header = 0
        var footer = 0
        var sections = 0
        var hasPending = false
        var rebaselines = 0
        var motion: ScrollStitcher.Motion = .none
        var offset = 0
        var score = 0.0
        var tailRepeated = false
    }
    struct Update: Sendable {
        let outcome: ScrollStitcher.Outcome
        let state: State
        let preview: CGImage?
    }
    private let stitcher: ScrollStitcher
    private let workHook: (@Sendable () -> Void)?

    init(maxTotalHeight: Int = 40_000, maxTotalPixels: Int = 50_000_000,
         workHook: (@Sendable () -> Void)? = nil) {
        stitcher = ScrollStitcher(maxTotalHeight: maxTotalHeight, maxTotalPixels: maxTotalPixels)
        self.workHook = workHook
    }

    func add(_ image: CGImage, predictedOffset: Int) -> Update {
        workHook?()
        let outcome = stitcher.add(image, predictedOffset: predictedOffset)
        let preview: CGImage?
        switch outcome {
        case .appended, .baselined, .buffered: preview = stitcher.previewImage(maxWidth: 384)
        default: preview = nil
        }
        let bands = stitcher.detectedBands
        return Update(outcome: outcome, state: State(
            firstFrame: stitcher.firstFrame, header: bands.header, footer: bands.footer,
            sections: stitcher.sectionCount, hasPending: stitcher.hasPending,
            rebaselines: stitcher.rebaselineCount, motion: stitcher.lastMotion,
            offset: stitcher.lastOffset, score: stitcher.lastScore,
            tailRepeated: stitcher.tailRepeated), preview: preview)
    }

    func motion(from baseline: ScrollStitcher.Frame, to image: CGImage,
                header: Int, footer: Int, predicted: Int, minimumShift: Int) -> ScrollStitcher.Motion {
        workHook?()
        guard let frame = ScrollStitcher.makeFrame(image) else { return .none }
        return ScrollStitcher.motion(from: baseline, to: frame, headerH: header, footerH: footer,
                                    predicted: predicted, minimumShift: minimumShift)
    }

    func finalImage() -> CGImage? {
        workHook?()
        return stitcher.finalImage()
    }
}

/// Drives a **manual** scrolling capture: the user scrolls the target window while we
/// watch the real scroll stream, grab a cursor-free frame of the fixed region each time
/// enough was scrolled (and once more when scrolling settles), and stitch them into one
/// tall image shown growing live in a side HUD. Ends on the HUD's Done (keep) or Esc /
/// Cancel (discard).
///
/// This replaces synthesized-scroll auto-capture, which is unreliable on macOS:
/// synthesized wheel events trigger momentum you can't pixel-control, and captured
/// frames re-render with sub-pixel anti-aliasing, so the two things auto-capture needs —
/// a known displacement and byte-stable frames — are both absent. Manual scroll gives a
/// real displacement and guaranteed overlap; the live preview makes progress legible and
/// failures visible.
@MainActor
final class ScrollingCaptureSession {
    enum Notice: Equatable, Sendable {
        case captureFailed, preparationFailed, outputLimit
    }
    enum Outcome: Sendable {
        case cancelled
        case completed(CGImage, notice: Notice?)
        case failed(Notice)
    }

    /// Inert presenters and scripted queries/captures exercise the real preparation,
    /// pump and completion paths without creating windows, monitors or device requests.
    struct Hooks {
        var prepare: () async throws -> Void
        var capture: (Duration) async throws -> CGImage
        var show: (@escaping () -> Void, @escaping () -> Void) -> Void = { _, _ in }
        var hide: () -> Void = {}
        var update: (CGImage?, Int) -> Void = { _, _ in }
        var hint: (String) -> Void = { _ in }
        var preparationCompleted: () -> Void = {}
        var captureCompleted: () -> Void = {}
    }
    private let region: CGRect
    private let display: SCDisplay?
    private let scale: CGFloat
    private let hooks: Hooks?
    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "scroll-session")

    private let worker: ScrollStitchWorker
    private var stitchState = ScrollStitchWorker.State()
    private var generation = 0
    private let indicator = CaptureAreaIndicator()
    private let preview = ScrollPreviewPanel()

    // Capture config — built in prepare() once our own HUD windows are on-screen so they
    // can be excluded from the capture. Optional (not IUO) so any capture attempted
    // before prepare() finishes safely no-ops instead of crashing on unwrap.
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?

    // Scroll monitoring + capture pump.
    private var scrollMonitors: [Any] = []
    private var accumulatedDeltaPoints: CGFloat = 0   // scrolled since the last accepted frame
    private var settleGeneration = 0
    private var captureInFlight = false
    private var pendingCapture = false
    private var prepared = false
    private var finished = false
    /// True from "Done" pressed until the final flush completes: blocks NEW captures
    /// while still letting the in-flight one finish and one last settled frame be grabbed.
    private var finishing = false
    private var completionNotice: Notice?
    /// Consecutive frame-capture failures; after a few in a row the session self-ends so
    /// it can't hang on-screen holding the app-wide exclusive-capture lock.
    private var captureFailures = 0
    private let triggerPoints: CGFloat

    // Optional auto-scroll: synthesizes smooth scrolling so the page advances by itself.
    // Manual scrolling always works too; auto is a toggle on top of it.
    private var autoScroller: AutoScroller?
    private var autoScrolling = false
    private var calibrating = false
    private var autoProgress = AutoScrollProgress()
    /// Set once the page end was reached: auto must never post again in this session, or the
    /// bottom gets stitched again on every restart. Manual scrolling stays available.
    private var autoEnded = false
    /// Bumped whenever an auto-scroll segment starts or stops, so a capture launched under
    /// one segment can't feed its outcome into a later segment's freshly-reset progress.
    private var autoGeneration = 0

    private var continuation: CheckedContinuation<Outcome, Never>?

    init(region: CGRect, display: SCDisplay) {
        self.region = region
        self.display = display
        hooks = nil
        worker = ScrollStitchWorker()
        self.scale = CGFloat(SCContentFilter(display: display, excludingWindows: []).pointPixelScale)
        // Capture roughly every ~40% of a viewport so consecutive frames always overlap,
        // even if the user scrolls briskly.
        self.triggerPoints = max(60, region.height * 0.4)
    }

    init(region: CGRect, scale: CGFloat = 1, hooks: Hooks,
         maxTotalHeight: Int = 40_000, maxTotalPixels: Int = 50_000_000,
         workHook: (@Sendable () -> Void)? = nil) {
        self.region = region
        display = nil
        self.scale = scale
        self.hooks = hooks
        worker = ScrollStitchWorker(maxTotalHeight: maxTotalHeight, maxTotalPixels: maxTotalPixels, workHook: workHook)
        triggerPoints = max(60, region.height * 0.4)
    }

    /// Runs to completion, distinguishing user cancellation from failures and useful partial output.
    func run() async -> Outcome {
        guard !Task.isCancelled else { return .cancelled }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Outcome, Never>) in
                continuation = c
                if let hooks {
                    hooks.show({ [weak self] in self?.finish(keep: true) },
                               { [weak self] in self?.finish(keep: false) })
                } else {
                    indicator.show(cgRect: region, color: .systemBlue, onStop: nil)
                    preview.show(
                        near: region,
                        onDone: { [weak self] in self?.finish(keep: true) },
                        onCancel: { [weak self] in self?.finish(keep: false) },
                        onToggleAuto: { [weak self] in self?.toggleAuto() }
                    )
                    installMonitors()
                }
                guard !finished else { return }
                // Immediate Cancel can resolve c while the bounded exclusion query awaits.
                Task { @MainActor in
                    await self.prepare()
                    if !self.finished, !self.finishing { self.pump(force: true) }
                }
            }
        } onCancel: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.finish(keep: false) }
        }
        teardown()
        return result
    }

    /// Builds the display filter EXCLUDING our own HUD/indicator windows (so they never
    /// bleed into the capture) and the region source-rect config.
    private func prepare() async {
        defer { hooks?.preparationCompleted() }
        let token = generation
        do {
            if let hooks {
                try await hooks.prepare()
                guard !finished, generation == token else { return }
                prepared = true
                return
            }
            guard let display else { throw CaptureError.timeout }
            // Fail closed: without a trustworthy exclusion list, our HUD can contaminate
            // the baseline. A bounded query failure ends preparation before any capture.
            let content = try await withHardTimeout(.seconds(2), onTimeout: CaptureError.timeout) {
                try await SCShareableContent.current
            }
            guard !finished, generation == token else { return }
            let ownBundleID = Bundle.main.bundleIdentifier
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let excluded = content.windows.filter {
                $0.owningApplication?.processID == ownPID ||
                (ownBundleID != nil && $0.owningApplication?.bundleIdentifier == ownBundleID)
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
            config.colorSpaceName = CGColorSpace.sRGB
            self.config = config
            prepared = true
        } catch {
            guard !finished, generation == token else { return }
            finish(keep: true, notice: .preparationFailed, flush: false)
        }
    }

    // MARK: - Scroll monitoring

    private func installMonitors() {
        let onScroll: (NSEvent) -> Void = { [weak self] event in self?.handleScroll(event) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: onScroll) {
            scrollMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { event in
            onScroll(event); return event
        }) {
            scrollMonitors.append(local)
        }
        // Esc cancels (best-effort — a global key monitor needs Accessibility; the HUD's
        // İptal button is the always-available path).
        if let esc = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.finish(keep: false) }
        }) {
            scrollMonitors.append(esc)
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard !finished, !finishing else { return }
        // Drop our OWN synthesized auto-scroll events, which echo back through the global
        // monitor asynchronously — we already counted them at post time (autoScrollAdvance).
        // Match by source identity, not the `autoScrolling` flag, so a late echo arriving
        // after auto has stopped is still dropped (else its delta is counted twice).
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == AutoScroller.echoSentinel {
            return
        }
        // While auto drives, it is the sole delta source — ignore genuine manual scroll too.
        guard !autoScrolling else { return }
        accumulatedDeltaPoints += abs(event.scrollingDeltaY)
        armSettle()
        if accumulatedDeltaPoints >= triggerPoints { pump() }
    }

    /// Fed by the AutoScroller each posting tick with the scroll amount (in points — a
    /// `.pixel` wheel event reports the same unit `NSEvent.scrollingDeltaY` does, so this
    /// mirrors handleScroll exactly). The single delta source while auto is on.
    private func autoScrollAdvance(points: CGFloat) {
        guard !finished, !finishing, autoScrolling, !calibrating else { return }
        accumulatedDeltaPoints += points
        armSettle()
        if accumulatedDeltaPoints >= triggerPoints { pump() }
    }

    // MARK: - Auto-scroll

    private func toggleAuto() {
        if autoScrolling { stopAutoScroll(reachedEnd: false); return }
        guard !finished, !finishing else { return }
        guard !autoEnded else {
            flashHint("Sayfa sonu")
            return
        }
        // Synthesized events only reach other apps when we're an Accessibility-trusted
        // process (same requirement as the app's event tap).
        guard AXIsProcessTrusted() else {
            flashHint("Otomatik için Erişilebilirlik izni gerekli")
            return
        }
        guard prepared, stitchState.firstFrame != nil else {
            flashHint("Sayfa hazırlanıyor · yeniden dene")
            return
        }
        autoScrolling = true
        calibrating = true
        settleGeneration &+= 1
        autoGeneration &+= 1   // start of a new auto segment; stale captures won't feed it
        autoProgress = AutoScrollProgress()
        let scroller = autoScroller ?? {
            let s = AutoScroller()
            s.onTick = { [weak self] points in self?.autoScrollAdvance(points: points) }
            autoScroller = s
            return s
        }()
        preview.setAuto(running: true, reachedEnd: false)
        let generation = autoGeneration
        Task { @MainActor in await self.calibrate(scroller, generation: generation) }
    }

    private func calibrate(_ scroller: AutoScroller, generation: Int) async {
        defer {
            if calibrating, autoGeneration == generation {
                stopAutoScroll(reachedEnd: false)
                flashHint("Sayfa kaydırılamıyor")
            }
        }
        let ready = ContinuousClock.now.advanced(by: .milliseconds(500))
        while captureInFlight, ContinuousClock.now < ready, autoGeneration == generation {
            try? await Task.sleep(for: .milliseconds(16))
        }
        for attempt in 0..<2 {
            // Per ATTEMPT, not per calibration: one shared 1 s budget could never fit the
            // second burst (430 ms of sleeps + a screenshot each), so the flip-and-retry
            // branch — the whole point of measuring — was unreachable.
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(1200))
            guard autoGeneration == generation, !captureInFlight,
                  let baseline = stitchState.firstFrame else { return }
            // 5 % of the viewport: enough to measure the sign, small enough that a wrong
            // first guess is barely visible (the persisted sign is tried FIRST).
            let burst = region.height * 0.05
            scroller.start(at: CGPoint(x: region.midX, y: region.midY), region: region, burstPoints: burst)
            try? await Task.sleep(for: .milliseconds(250))
            guard autoGeneration == generation else { return }
            scroller.stop()
            try? await Task.sleep(for: .milliseconds(180))
            guard autoGeneration == generation, ContinuousClock.now < deadline else { return }
            captureInFlight = true
            // Probe only: a 5 % burst is below the stitcher's motion floor, so feeding it
            // would just look like a lost alignment and flash a spurious gap warning.
            let image = await captureAndStitch(
                predictedPoints: burst,
                timeout: ContinuousClock.now.duration(to: deadline),
                stitch: false
            )
            captureInFlight = false
            guard autoGeneration == generation, ContinuousClock.now < deadline,
                  let image else { return }
            let predictedPx = Int((burst * scale).rounded())
            let motion = await worker.motion(from: baseline, to: image,
                                             header: stitchState.header, footer: stitchState.footer,
                                             predicted: predictedPx, minimumShift: max(4, predictedPx / 2))
            guard autoGeneration == generation, !finished, !finishing else { return }
            switch motion {
            case .down:
                scroller.confirmDirection()
            case .up:
                // The flip IS the measurement: the corrected sign is exactly as proven as
                // a `.down` under the current one, so remember it (S.3).
                scroller.flipDirection()
                scroller.confirmDirection()
            case .none:
                if attempt == 0 { scroller.flipDirection(); continue }
                return
            }
            // Only a measured advance seeds the run. Recording a calibration `.up` would
            // spend the run's single allowed flip before it starts, so the first two
            // stalled frames would report "page end" without ever having advanced.
            if case .down = motion { _ = autoProgress.record(motion) }
            calibrating = false
            accumulatedDeltaPoints = 0
            pendingCapture = false
            scroller.start(at: CGPoint(x: region.midX, y: region.midY), region: region)
            return
        }
    }

    private func stopAutoScroll(reachedEnd: Bool, reason: String = "manual") {
        guard autoScrolling else { return }
        // The owner reads the file log to explain a run that ended early, so the reason the
        // end-of-page rules fired has to be in it — the per-capture line cannot show it.
        let line = "scroll auto-stop reason=\(reason) end=\(reachedEnd) sections=\(stitchState.sections)"
        logger.notice("\(line, privacy: .public)")
        if hooks == nil { DiagnosticsLog.append(line) }
        if reachedEnd { autoEnded = true }
        autoScrolling = false
        calibrating = false
        autoGeneration &+= 1   // captures launched under the old segment must not feed the next
        autoScroller?.stop()
        autoProgress = AutoScrollProgress()
        if hooks == nil { preview.setAuto(running: false, reachedEnd: reachedEnd) }
    }

    /// After a short quiet period, grab one more frame so the last bit scrolled (and any
    /// inertial glide) is captured — the only settle signal for classic wheel mice, which
    /// carry no scroll phase.
    private func armSettle() {
        settleGeneration &+= 1
        let generation = settleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            Task { @MainActor in
                guard let self, self.settleGeneration == generation, !self.finished, !self.finishing else { return }
                if self.accumulatedDeltaPoints > 0 { self.pump() }
            }
        }
    }

    // MARK: - Capture pump

    /// Serialises captures: only one SCScreenshotManager call in flight, with a single
    /// pending follow-up so bursts of scroll events don't pile up.
    private func pump(force: Bool = false) {
        guard !finished, !finishing, !calibrating else { return }
        // Scrolls can arrive before the filter is built; remember them so the baseline
        // capture (fired the instant prepare() finishes) picks them up.
        guard prepared else {
            pendingCapture = true
            return
        }
        if captureInFlight {
            pendingCapture = true
            return
        }
        guard force || accumulatedDeltaPoints > 0 else { return }
        captureInFlight = true
        let predictedPoints = accumulatedDeltaPoints
        accumulatedDeltaPoints = 0
        Task { @MainActor in
            await self.captureAndStitch(predictedPoints: predictedPoints)
            self.captureInFlight = false
            // Persistent failures (permission lost mid-session, wedged replayd) must not
            // strand the HUD holding the exclusive lock — end the session.
            self.finishAfterRepeatedCaptureFailures()
            guard !self.finished, !self.finishing else { return }
            if self.pendingCapture, !self.finished, !self.finishing {
                self.pendingCapture = false
                self.pump()
            }
        }
    }

    private func finishAfterRepeatedCaptureFailures() {
        guard captureFailures >= 3, !finished, !finishing else { return }
        logger.error("scroll capture: repeated frame failures; ending session")
        finish(keep: true, notice: .captureFailed, flush: false)
    }

    /// Auto-scroll state for the per-capture diagnostics line.
    private var autoState: String {
        if calibrating { return "calibrating" }
        if autoScrolling { return "running" }
        return autoEnded ? "ended" : "off"
    }

    /// One line per capture, to the FILE sink as well as `Logger`: the installed app's
    /// `os_log` output is not retrievable with `log show`, so the file is the only record.
    private func logCapture(_ outcome: String, offset: Int, score: Double, extra: String = "") {
        guard hooks == nil else { return }
        let line = "scroll outcome=\(outcome) offset=\(offset) score=\(score) "
            + "pending=\(stitchState.hasPending) rebaselines=\(stitchState.rebaselines) auto=\(autoState)"
            + (extra.isEmpty ? "" : " " + extra)
        logger.notice("\(line, privacy: .public)")
        DiagnosticsLog.append(line)
    }

    @discardableResult
    private func captureAndStitch(
        predictedPoints: CGFloat, timeout: Duration = .seconds(2), stitch: Bool = true
    ) async -> CGImage? {
        // Never attempt a capture before the filter/config exist (a very fast Done can
        // reach the flush before prepare() finished) — safe no-op instead of a crash.
        guard hooks != nil || (filter != nil && config != nil) else { return nil }
        defer { hooks?.captureCompleted() }
        // Which auto-scroll segment launched this capture — captured before the await so a
        // slow frame that resolves after auto is toggled off/on can't feed the next segment.
        let sessionGeneration = generation
        let capturedGeneration = autoGeneration
        let predictedPx = Int((predictedPoints * scale).rounded())
        let image: CGImage
        do {
            if let hooks {
                image = try await hooks.capture(timeout)
            } else if let filter, let config {
                image = try await withHardTimeout(timeout, onTimeout: CaptureError.timeout) {
                    try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                }
            } else {
                return nil
            }
        } catch {
            guard !finished, generation == sessionGeneration else { return nil }
            logCapture("failed", offset: 0, score: .nan, extra: "error=\(String(describing: error))")
            captureFailures += 1
            return nil
        }
        guard !finished, generation == sessionGeneration else { return nil }
        captureFailures = 0
        guard !finished else { return nil }
        guard stitch else {
            logCapture("probe", offset: 0, score: .nan)
            return image
        }
        let rebaselines = stitchState.rebaselines
        let update = await worker.add(image, predictedOffset: predictedPx)
        guard !finished, generation == sessionGeneration else { return nil }
        stitchState = update.state
        let outcome = update.outcome
        logCapture(String(describing: outcome), offset: stitchState.offset, score: stitchState.score)
        if stitchState.rebaselines > rebaselines { flashHint("Kopukluk · yavaş kaydır") }
        // Only recompose the (O(n)) preview when the composite actually changed —
        // .appended/.baselined grows or seeds it, .buffered shows the newest warm-up frame;
        // .ignored (a pause / over-scroll / static frame) leaves it untouched, so skip.
        switch outcome {
        case .appended, .baselined, .buffered:
            let image = update.preview
            if let hooks { hooks.update(image, stitchState.sections) }
            else { preview.update(image: image, sections: stitchState.sections) }
        case .ignored, .noMotion, .movedUp:
            break
        case .atCap:
            finish(keep: true, notice: .outputLimit, flush: false)
            return nil
        }
        // A lost alignment (`.ignored`) is neither an advance nor a stall: the stitcher
        // re-baselines itself after two of them, and counting them as stalls would end the
        // run mid-page at exactly the count where that recovery starts.
        if autoScrolling, !calibrating, capturedGeneration == autoGeneration, outcome != .ignored {
            let motion = stitchState.motion
            if case .down = motion { autoScroller?.confirmDirection() }
            // A strip that merely repeats the band above it means the page bottom was just
            // stitched twice — the end, however the motion happened to classify.
            if stitchState.tailRepeated {
                stopAutoScroll(reachedEnd: true, reason: "tail-dup")
            } else {
                switch autoProgress.record(motion) {
                case .keepScrolling: break
                case .flipDirection: autoScroller?.flipDirection()
                case .reachedEnd: stopAutoScroll(reachedEnd: true, reason: autoProgress.endReason)
                }
            }
        }
        return image
    }

    // MARK: - Finish

    private func finish(keep: Bool, notice: Notice? = nil, flush: Bool = true) {
        guard !finished else { return }
        stopAutoScroll(reachedEnd: false)
        // Cancel remains immediate even during Done/final raster work. Invalidate every
        // suspended capture/worker publication before resolving the continuation.
        guard keep else {
            generation &+= 1
            finished = true
            continuation?.resume(returning: .cancelled)
            continuation = nil
            return
        }
        if let notice { completionNotice = notice }
        guard !finishing else { return }
        finishing = true
        let token = generation
        Task { @MainActor in await self.flushAndFinalize(token: token, notice: notice, flush: flush) }
    }

    private func flushAndFinalize(token: Int, notice: Notice?, flush: Bool) async {
        var finalNotice = notice
        if flush {
            // Existing bounded settled-frame flush, with cancellation checked after every
            // suspension. Single-flight ownership includes matcher/preview work now.
            var spins = 0
            while captureInFlight, spins < 200, !finished, generation == token {
                try? await Task.sleep(for: .milliseconds(16))
                spins += 1
            }
            guard !finished, generation == token else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !finished, generation == token else { return }
            if prepared, !captureInFlight {
                accumulatedDeltaPoints = 0
                await captureAndStitch(predictedPoints: 0)
                if captureFailures > 0 { finalNotice = .captureFailed }
            }
        }
        guard !finished, generation == token else { return }
        let image = await worker.finalImage()
        guard !finished, generation == token else { return }
        finished = true
        continuation?.resume(returning: image.map { .completed($0, notice: completionNotice ?? finalNotice) }
                             ?? .failed(completionNotice ?? finalNotice ?? .captureFailed))
        continuation = nil
    }

    private func teardown() {
        settleGeneration &+= 1
        autoScrolling = false
        autoScroller?.stop()
        autoScroller = nil
        for monitor in scrollMonitors { NSEvent.removeMonitor(monitor) }
        scrollMonitors = []
        if let hooks { hooks.hide() }
        else { indicator.hide(); preview.hide() }
    }

    var readyForCaptureForTesting: Bool { prepared && !captureInFlight }

    private func flashHint(_ message: String) {
        if let hooks { hooks.hint(message) } else { preview.flashHint(message) }
    }

    /// Inert auto producer for generation tests; never creates/posts an AutoScroller.
    func resetAutoSegmentForTesting() {
        guard hooks != nil else { return }
        autoScrolling = true
        autoGeneration &+= 1
        autoProgress = AutoScrollProgress()
    }
    var autoProgressForTesting: AutoScrollProgress { autoProgress }

    func captureNextFrameForTesting(predictedPoints: CGFloat = 0) async {
        guard hooks != nil, !finished, !finishing, prepared, !captureInFlight else { return }
        captureInFlight = true
        await captureAndStitch(predictedPoints: predictedPoints)
        captureInFlight = false
        finishAfterRepeatedCaptureFailures()
    }
}
