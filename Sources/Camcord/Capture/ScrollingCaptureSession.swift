import AppKit
import ApplicationServices
@preconcurrency import ScreenCaptureKit
import os

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
    private let region: CGRect
    private let display: SCDisplay
    private let scale: CGFloat
    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "scroll-session")

    private let stitcher = ScrollStitcher()
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
    /// Bumped whenever an auto-scroll segment starts or stops, so a capture launched under
    /// one segment can't feed its outcome into a later segment's freshly-reset progress.
    private var autoGeneration = 0

    private var continuation: CheckedContinuation<CGImage?, Never>?

    init(region: CGRect, display: SCDisplay) {
        self.region = region
        self.display = display
        self.scale = CGFloat(SCContentFilter(display: display, excludingWindows: []).pointPixelScale)
        // Capture roughly every ~40% of a viewport so consecutive frames always overlap,
        // even if the user scrolls briskly.
        self.triggerPoints = max(60, region.height * 0.4)
    }

    /// Runs to completion. Returns the stitched image on Done, or nil if cancelled
    /// (Esc / İptal) or nothing usable was captured.
    func run() async -> CGImage? {
        indicator.show(cgRect: region, color: .systemBlue, label: nil, onStop: nil)
        preview.show(
            near: region,
            onDone: { [weak self] in self?.finish(keep: true) },
            onCancel: { [weak self] in self?.finish(keep: false) },
            onToggleAuto: { [weak self] in self?.toggleAuto() }
        )
        installMonitors()

        let result = await withCheckedContinuation { (c: CheckedContinuation<CGImage?, Never>) in
            self.continuation = c
            // Build the capture filter (now the HUD windows exist, so they're excluded),
            // then take the baseline frame. Launched as a task so an immediate Cancel
            // during prepare still resolves `c` and can't deadlock.
            Task { @MainActor in
                await self.prepare()
                if !self.finished { self.pump(force: true) }
            }
        }
        teardown()
        return result
    }

    /// Builds the display filter EXCLUDING our own HUD/indicator windows (so they never
    /// bleed into the capture) and the region source-rect config.
    private func prepare() async {
        var excluded: [SCWindow] = []
        // Bounded like every other SCK call in the app — a wedged content query must not
        // hang the session (and the app-wide exclusive-capture lock) forever.
        let content = try? await withHardTimeout(.seconds(2), onTimeout: CaptureError.timeout) {
            try await SCShareableContent.current
        }
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
        config.colorSpaceName = CGColorSpace.sRGB
        self.config = config
        prepared = true
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
        // Synthesized events only reach other apps when we're an Accessibility-trusted
        // process (same requirement as the app's event tap).
        guard AXIsProcessTrusted() else {
            preview.flashHint("Otomatik için Erişilebilirlik izni gerekli")
            return
        }
        guard prepared, stitcher.firstFrame != nil else {
            preview.flashHint("Sayfa hazırlanıyor · yeniden dene")
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
                preview.flashHint("Sayfa kaydırılamıyor")
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
                  let baseline = stitcher.firstFrame else { return }
            let burst = region.height * 0.15
            scroller.start(at: CGPoint(x: region.midX, y: region.midY), region: region, burstPoints: burst)
            try? await Task.sleep(for: .milliseconds(250))
            guard autoGeneration == generation else { return }
            scroller.stop()
            try? await Task.sleep(for: .milliseconds(180))
            guard autoGeneration == generation, ContinuousClock.now < deadline else { return }
            captureInFlight = true
            let image = await captureAndStitch(predictedPoints: burst, timeout: ContinuousClock.now.duration(to: deadline))
            captureInFlight = false
            guard autoGeneration == generation, ContinuousClock.now < deadline,
                  let image, let frame = ScrollStitcher.makeFrame(image) else { return }
            let bands = stitcher.detectedBands
            let motion = ScrollStitcher.motion(from: baseline, to: frame,
                                               headerH: bands.header, footerH: bands.footer,
                                               predicted: Int((burst * scale).rounded()))
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
            // spend the run's single allowed flip before it starts, so the first three
            // stalled frames would report "page end" without ever having advanced.
            if case .down = motion { _ = autoProgress.record(motion) }
            calibrating = false
            accumulatedDeltaPoints = 0
            pendingCapture = false
            scroller.start(at: CGPoint(x: region.midX, y: region.midY), region: region)
            return
        }
    }

    private func stopAutoScroll(reachedEnd: Bool) {
        guard autoScrolling else { return }
        autoScrolling = false
        calibrating = false
        autoGeneration &+= 1   // captures launched under the old segment must not feed the next
        autoScroller?.stop()
        autoProgress = AutoScrollProgress()
        preview.setAuto(running: false, reachedEnd: reachedEnd)
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
            if self.captureFailures >= 3, !self.finished, !self.finishing {
                self.logger.error("scroll capture: repeated frame failures; ending session")
                self.finish(keep: false)
                return
            }
            if self.pendingCapture, !self.finished, !self.finishing {
                self.pendingCapture = false
                self.pump()
            }
        }
    }

    @discardableResult
    private func captureAndStitch(predictedPoints: CGFloat, timeout: Duration = .seconds(2)) async -> CGImage? {
        // Never attempt a capture before the filter/config exist (a very fast Done can
        // reach the flush before prepare() finished) — safe no-op instead of a crash.
        guard let filter, let config else { return nil }
        // Which auto-scroll segment launched this capture — captured before the await so a
        // slow frame that resolves after auto is toggled off/on can't feed the next segment.
        let capturedGeneration = autoGeneration
        let predictedPx = Int((predictedPoints * scale).rounded())
        let image: CGImage
        do {
            image = try await withHardTimeout(timeout, onTimeout: CaptureError.timeout) {
                try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            }
        } catch {
            logger.notice("scroll outcome=failed offset=0 score=nan pending=\(self.stitcher.hasPending) rebaselines=\(self.stitcher.rebaselineCount) error=\(String(describing: error), privacy: .public)")
            captureFailures += 1
            return nil
        }
        captureFailures = 0
        guard !finished else { return nil }
        let rebaselines = stitcher.rebaselineCount
        let outcome = stitcher.add(image, predictedOffset: predictedPx)
        logger.notice("scroll outcome=\(String(describing: outcome), privacy: .public) offset=\(self.stitcher.lastOffset) score=\(self.stitcher.lastScore) pending=\(self.stitcher.hasPending) rebaselines=\(self.stitcher.rebaselineCount)")
        if stitcher.rebaselineCount > rebaselines { preview.flashHint("Kopukluk · yavaş kaydır") }
        // Only recompose the (O(n)) preview when the composite actually changed —
        // .appended/.baselined grows or seeds it, .buffered shows the newest warm-up frame;
        // .ignored (a pause / over-scroll / static frame) leaves it untouched, so skip.
        switch outcome {
        case .appended, .baselined, .buffered:
            preview.update(image: stitcher.previewImage(maxWidth: 384), sections: stitcher.sectionCount)
        case .ignored, .noMotion, .movedUp:
            break
        case .atCap:
            finish(keep: true)
            return nil
        }
        if autoScrolling, !calibrating, capturedGeneration == autoGeneration {
            let motion = stitcher.lastMotion
            if case .down = motion { autoScroller?.confirmDirection() }
            switch autoProgress.record(motion) {
            case .keepScrolling: break
            case .flipDirection: autoScroller?.flipDirection()
            case .reachedEnd: stopAutoScroll(reachedEnd: true)
            }
        }
        return image
    }

    // MARK: - Finish

    private func finish(keep: Bool) {
        guard !finished, !finishing else { return }
        // Stop auto-scroll through the shared helper so the HUD button/status revert
        // immediately (Done during a long flush must not leave it stuck on "running").
        stopAutoScroll(reachedEnd: false)
        // Cancel is immediate — discard whatever's stitched.
        guard keep else {
            finished = true
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }
        // Done flushes outstanding work so the last frame isn't lost: wait out any
        // in-flight capture, then grab one final settled frame to resolve a pending bounce.
        finishing = true
        Task { @MainActor in await self.flushAndFinalize() }
    }

    private func flushAndFinalize() async {
        // Bounded wait for the in-flight capture (itself hard-timeout'd at 2s).
        var spins = 0
        while captureInFlight, spins < 200 {
            try? await Task.sleep(for: .milliseconds(16))
            spins += 1
        }
        // Always resolve the last pending strip with a frame at rest.
        try? await Task.sleep(for: .milliseconds(180))
        if prepared, !captureInFlight {
            accumulatedDeltaPoints = 0
            await captureAndStitch(predictedPoints: 0)
        }
        finished = true
        continuation?.resume(returning: stitcher.finalImage())
        continuation = nil
    }

    private func teardown() {
        settleGeneration &+= 1
        autoScrolling = false
        autoScroller?.stop()
        autoScroller = nil
        for monitor in scrollMonitors { NSEvent.removeMonitor(monitor) }
        scrollMonitors = []
        indicator.hide()
        preview.hide()
    }
}
