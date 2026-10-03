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
    private var stitcher: ScrollStitcher
    private let workHook: (@Sendable () -> Void)?
    private let caps: (height: Int, pixels: Int)

    init(maxTotalHeight: Int = 40_000, maxTotalPixels: Int = 50_000_000,
         workHook: (@Sendable () -> Void)? = nil) {
        stitcher = ScrollStitcher(maxTotalHeight: maxTotalHeight, maxTotalPixels: maxTotalPixels)
        caps = (maxTotalHeight, maxTotalPixels)
        self.workHook = workHook
    }

    /// Starts the stitch over: auto-scroll climbed to the page top and captures down from there.
    func reset() {
        stitcher = ScrollStitcher(maxTotalHeight: caps.height, maxTotalPixels: caps.pixels)
    }

    /// How a frame sits against the stitch's own reference, changing nothing.
    func probe(_ image: CGImage, predicted: Int) -> (still: Bool, motion: ScrollStitcher.Motion)? {
        workHook?()
        return stitcher.probe(image, predicted: predicted)
    }

    /// How `to` sits relative to `from`: the same view (still), or moved, measured the way `add`
    /// measures it.
    func compare(_ from: CGImage, _ to: CGImage, header: Int, footer: Int,
                 predicted: Int) -> (still: Bool, motion: ScrollStitcher.Motion) {
        workHook?()
        guard let a = ScrollStitcher.makeFrame(from), let b = ScrollStitcher.makeFrame(to) else { return (false, .none) }
        if ScrollStitcher.isStill(a, b, headerH: header, footerH: footer) { return (true, .none) }
        // A toolbar or sticky band the two frames share stays out of the measurement.
        let bands = ScrollStitcher.staticBands(a, b)
        return (false, ScrollStitcher.motion(from: a, to: b, headerH: max(header, bands.header),
                                             footerH: max(footer, bands.footer), predicted: predicted, minimumShift: 2))
    }

    func add(_ image: CGImage, predictedOffset: Int) -> Update {
        workHook?()
        let outcome = stitcher.add(image, predictedOffset: predictedOffset)
        let preview: CGImage?
        switch outcome {
        case .appended, .baselined, .buffered: preview = stitcher.previewImage(maxWidth: 480)
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
        /// Moves the scripted page for an auto scroll.
        var actuator: (any ScrollActuator)?
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

    // Optional auto-scroll: one calm step at a time, each frame settled before it is stitched.
    // Manual scrolling always works too; auto is a toggle on top of it.
    private var autoTask: Task<Void, Never>?
    private var autoScrolling = false
    /// Set once auto has run its course: it never runs again in this session. Manual
    /// scrolling stays available.
    private var autoEnded = false
    /// Bumped whenever an auto-scroll run starts or stops, so a run that is still awaiting a
    /// frame can never act after it was stopped or replaced.
    private var autoGeneration = 0
    /// The newest settled frame of the run, the reference for the next comparison.
    private var autoFrame: CGImage?
    private static let maxClimbSteps = 120
    private static let maxAutoSteps = 600

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
                    indicator.show(cgRect: region, color: Theme.Palette.ink.ns, onStop: nil)
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
        if WheelScrollActuator.isOwnEvent(event.cgEvent) { return }
        // While auto drives, it is the sole delta source — ignore genuine manual scroll too.
        guard !autoScrolling else { return }
        accumulatedDeltaPoints += abs(event.scrollingDeltaY)
        armSettle()
        if accumulatedDeltaPoints >= triggerPoints { pump() }
    }

    // MARK: - Auto-scroll
    //
    // The owner scrolls to where the capture should end, then lets Camcord scroll: it climbs
    // to the top of the page and captures down, one settled step at a time, until it is back
    // where the owner started — or, started at the top, until the page ends. Then it
    // finishes by itself.

    private func toggleAuto() {
        if autoScrolling { stopAutoScroll(reachedEnd: false); return }
        guard !finished, !finishing else { return }
        guard !autoEnded else {
            flashHint(String(localized: "End of page"), warning: false)
            return
        }
        // Synthesized scrolling (and the scroll bar route) need the Accessibility permission.
        guard hooks != nil || AXIsProcessTrusted() else {
            flashHint(String(localized: "Needs Accessibility permission"))
            return
        }
        guard prepared, stitchState.firstFrame != nil, !captureInFlight else {
            flashHint(String(localized: "Not ready yet · Try again"), warning: false)
            return
        }
        autoScrolling = true
        autoGeneration &+= 1
        settleGeneration &+= 1   // a manual settle capture still pending must not fire
        accumulatedDeltaPoints = 0
        pendingCapture = false
        let run = autoGeneration
        if hooks == nil { preview.setAuto(running: true, reachedEnd: false) }
        autoTask = Task { @MainActor [weak self] in await self?.runAuto(run) }
    }

    private func autoAlive(_ run: Int) -> Bool {
        autoScrolling && autoGeneration == run && !finished && !finishing && !Task.isCancelled
    }

    private func runAuto(_ run: Int) async {
        let actuator: any ScrollActuator
        if let scripted = hooks?.actuator { actuator = scripted }
        else if let bar = await AXScrollActuator.resolve(region: region) { actuator = bar }
        else { actuator = WheelScrollActuator(region: region) }
        guard autoAlive(run) else { return }
        logAuto("start route=\(actuator.route) sections=\(stitchState.sections)")
        guard let start = await settledFrame(run) else { return }
        autoFrame = start
        var boundary: Boundary?
        // A fresh capture starts from the top; one the owner has already scrolled on carries on.
        if stitchState.sections <= 1 {
            if hooks == nil { preview.setClimbing(true) }
            let climb = await climbToTop(actuator, from: start, run: run)
            if hooks == nil { preview.setClimbing(false) }
            guard autoAlive(run) else { return }
            if let climb {
                logAuto("climbed points=\(Int(climb.distance)) exact=\(climb.exact)")
                boundary = Boundary(frame: start, distance: climb.distance, exact: climb.exact)
                await worker.reset()
                guard autoAlive(run) else { return }
                stitchState = ScrollStitchWorker.State()
                guard await stitch(climb.top, predictedPx: 0, sessionGeneration: generation) != nil else { return }
                autoFrame = climb.top
            }
        }
        await descend(actuator, to: boundary, run: run)
    }

    /// Where the owner started: the frame, and how far above it the top was.
    private struct Boundary {
        let frame: CGImage
        let distance: CGFloat
        /// Measured step by step (or read from the scroll bar), not estimated.
        let exact: Bool
    }

    /// Up to the top of the page: one jump where the scroll bar takes it, otherwise overlapping
    /// steps, each measured, until the view stops changing. Nil when the page was already at
    /// its top.
    private func climbToTop(_ actuator: any ScrollActuator, from start: CGImage, run: Int)
        async -> (top: CGImage, distance: CGFloat, exact: Bool)? {
        let startPosition = actuator.position()
        if await actuator.jumpToTop() {
            guard let top = await settledFrame(run) else { return nil }
            if await worker.compare(start, top, header: 0, footer: 0, predicted: 0).still { return nil }
            return (top, startPosition ?? 0, startPosition != nil)
        }
        // Half the region: a toolbar or a sticky header still leaves overlap to measure.
        let stepPoints = region.height * 0.5
        var previous = start
        var distance: CGFloat = 0
        var exact = true
        var stillSteps = 0
        var first = true
        for _ in 0..<Self.maxClimbSteps {
            // The first step is short: it tells which way the wheel runs here.
            let length = first ? region.height * 0.3 : stepPoints
            guard autoAlive(run), let frame = await step(actuator, by: -length, run: run) else { return nil }
            // Measured from the higher view down to the lower one: a downward shift, which the
            // stitcher finds seeded by the step, however long.
            let predicted = Int((length * scale).rounded())
            let measured = await worker.compare(frame, previous, header: 0, footer: 0, predicted: predicted)
            guard autoAlive(run) else { return nil }
            if measured.still {
                if first { return nil }
                stillSteps += 1
                if stillSteps >= 2 { return (frame, distance, exact) }
                continue
            }
            stillSteps = 0
            if case .down(let pixels, _) = measured.motion {
                distance += CGFloat(pixels) / scale
            } else if first, case .down(let pixels, _) = await worker.compare(previous, frame, header: 0, footer: 0,
                                                                              predicted: predicted).motion {
                // The wheel runs the other way here: the start is that much further up now.
                actuator.reverse()
                logAuto("reversed")
                distance -= CGFloat(pixels) / scale
            } else {
                distance += length
                exact = false
            }
            first = false
            previous = frame
        }
        logAuto("climb-budget")
        return (previous, distance, false)
    }

    /// Down one settled step at a time, back to where the owner started (or, started at the
    /// top, to the page end). Each frame is measured against the stitch before it is committed,
    /// so a step that went wrong is taken back instead of stitched. The last step is exactly
    /// what remains, and the frame it lands on is checked against the one the owner started from.
    private func descend(_ actuator: any ScrollActuator, to boundary: Boundary?, run: Int) async {
        // Steps are a share of what actually scrolls: the region less its fixed bands. Small
        // until the stitch has found those bands, then longer.
        let cruise: CGFloat = actuator.route == "ax" ? 0.6 : 0.5
        var share: CGFloat = 0.35
        var descended: CGFloat = 0
        var stalls = 0
        var verified = false
        var searching = false
        for _ in 0..<Self.maxAutoSteps {
            guard autoAlive(run) else { return }
            let scrolling = max(region.height * 0.3,
                                region.height - CGFloat(stitchState.header + stitchState.footer) / scale)
            let stepPoints = max(8, scrolling * share)
            var length = stepPoints
            var last = false
            if let boundary, !searching {
                // The scroll bar reads exactly where the page is; otherwise the measured steps say.
                let remaining = actuator.position().map { boundary.distance - $0 } ?? (boundary.distance - descended)
                if remaining <= stepPoints {
                    length = max(1, remaining)
                    last = true
                } else if remaining < stepPoints * 1.4 {
                    // Never leave a sliver for the end: split what remains in two.
                    length = remaining / 2
                }
            }
            if searching { length = scrolling * 0.25 }
            guard let frame = await step(actuator, by: length, run: run), autoAlive(run) else { return }
            var measured = await worker.probe(frame, predicted: Int((length * scale).rounded()))
            if let first = measured, !first.still, first.motion == .none {
                // The page moved other than asked (its end clamped the step): look without a guess.
                measured = await worker.probe(frame, predicted: 0)
            }
            guard autoAlive(run), let measured else { return }
            if measured.still {
                stalls += 1
                if stalls >= 2 { finishAuto(reason: "page-end"); return }
                // A page may still be loading what comes next.
                try? await Task.sleep(for: .milliseconds(900))
                continue
            }
            switch measured.motion {
            case .down(let pixels, _):
                guard let outcome = await stitch(frame, predictedPx: pixels, sessionGeneration: generation),
                      autoAlive(run) else { return }
                if outcome == .atCap { return }
                stalls = 0
                verified = true
                descended += CGFloat(pixels) / scale
                if outcome == .appended { share = max(share, cruise) }
            case .up:
                // Before the first measured advance this can only be a wheel running the other way.
                if !verified { actuator.reverse(); verified = true; logAuto("reversed") }
                continue
            case .none:
                // Too far to place: take the step back and try a shorter one.
                logAuto("step-back points=\(Int(length))")
                guard await step(actuator, by: -length, run: run) != nil, autoAlive(run) else { return }
                share = max(0.15, share * 0.5)
                continue
            }
            guard let boundary, last || searching else { continue }
            let atStart = await worker.compare(frame, boundary.frame, header: stitchState.header,
                                               footer: stitchState.footer, predicted: 0).still
            if atStart || boundary.exact && !searching {
                finishAuto(reason: atStart ? "start-reached" : "start-measured")
                return
            }
            // An estimated climb: walk on in short steps until the start comes back into view,
            // but never far past where it should have been.
            searching = true
            if descended > boundary.distance + region.height * 1.5 {
                finishAuto(reason: "start-approx")
                return
            }
        }
        finishAuto(reason: "step-budget")
    }

    /// One step and the frame it settles on. While the pointer is away from the region the
    /// wheel route waits instead of scrolling whatever is under it now.
    private func step(_ actuator: any ScrollActuator, by points: CGFloat, run: Int) async -> CGImage? {
        while autoAlive(run) {
            if await actuator.scroll(by: points) { return await settledFrame(run) }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return nil
    }

    /// The page as it rests: frames are taken until two in a row agree (a fading scroll bar
    /// or a blinking caret stay under the threshold), or a short cap passes for a page that
    /// never rests (video, animation).
    private func settledFrame(_ run: Int) async -> CGImage? {
        guard var previous = await captureImage(), autoAlive(run) else { return nil }
        let deadline = ContinuousClock.now + .milliseconds(1200)
        var pause = 40
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(pause))
            pause = min(90, pause + 20)
            guard autoAlive(run), let next = await captureImage() else { return nil }
            if await worker.compare(previous, next, header: 0, footer: 0, predicted: 0).still { return next }
            previous = next
        }
        logAuto("unsettled")
        return previous
    }

    /// The run has done its job: Camcord finishes the capture by itself.
    private func finishAuto(reason: String) {
        stopAutoScroll(reachedEnd: true, reason: reason)
        finish(keep: true)
    }

    private func stopAutoScroll(reachedEnd: Bool, reason: String = "manual") {
        guard autoScrolling else { return }
        // The owner reads the file log to explain a run that ended early.
        logAuto("stop reason=\(reason) end=\(reachedEnd) sections=\(stitchState.sections)")
        if reachedEnd { autoEnded = true }
        autoScrolling = false
        autoGeneration &+= 1
        autoTask?.cancel()
        autoTask = nil
        autoFrame = nil
        if hooks == nil { preview.setAuto(running: false, reachedEnd: reachedEnd) }
    }

    private func logAuto(_ message: String) {
        let line = "scroll auto " + message
        logger.notice("\(line, privacy: .public)")
        if hooks == nil { DiagnosticsLog.append(line) }
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
        guard !finished, !finishing, !autoScrolling else { return }
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
    private func captureAndStitch(predictedPoints: CGFloat, timeout: Duration = .seconds(2)) async -> CGImage? {
        guard hooks != nil || (filter != nil && config != nil) else { return nil }
        defer { hooks?.captureCompleted() }
        let sessionGeneration = generation
        guard let image = await captureImage(timeout: timeout) else { return nil }
        guard await stitch(image, predictedPx: Int((predictedPoints * scale).rounded()),
                           sessionGeneration: sessionGeneration) != nil else { return nil }
        return image
    }

    /// One cursor-free frame of the region, or nil (failures are counted; the session ends
    /// itself after a few in a row).
    private func captureImage(timeout: Duration = .seconds(2)) async -> CGImage? {
        // Never attempt a capture before the filter/config exist (a very fast Done can
        // reach the flush before prepare() finished) — safe no-op instead of a crash.
        guard hooks != nil || (filter != nil && config != nil) else { return nil }
        let sessionGeneration = generation
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
        return image
    }

    /// Feeds one settled frame to the stitcher and shows what changed.
    private func stitch(_ image: CGImage, predictedPx: Int, sessionGeneration: Int) async -> ScrollStitcher.Outcome? {
        let rebaselines = stitchState.rebaselines
        let update = await worker.add(image, predictedOffset: predictedPx)
        guard !finished, generation == sessionGeneration else { return nil }
        stitchState = update.state
        let outcome = update.outcome
        logCapture(String(describing: outcome), offset: stitchState.offset, score: stitchState.score)
        if stitchState.rebaselines > rebaselines { flashHint(String(localized: "Gap · Scroll more slowly")) }
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
        }
        return outcome
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
        // The last frame and the final image take a moment; the HUD says so and takes no
        // second Done.
        if hooks == nil { preview.setFinishing() }
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
        autoTask?.cancel()
        autoTask = nil
        for monitor in scrollMonitors { NSEvent.removeMonitor(monitor) }
        scrollMonitors = []
        if let hooks { hooks.hide() }
        else { indicator.hide(); preview.hide() }
    }

    var readyForCaptureForTesting: Bool { prepared && !captureInFlight }

    /// A transient line in the HUD's status; a warning carries the warning mark.
    private func flashHint(_ message: String, warning: Bool = true) {
        if let hooks { hooks.hint(message) } else { preview.flashHint(message, warning: warning) }
    }

    /// Starts or stops auto-scroll as the HUD's control does.
    func toggleAutoForTesting() { toggleAuto() }
    var autoScrollingForTesting: Bool { autoScrolling }
    /// Cancel, as the HUD's ×; scripted sessions only.
    func cancelForTesting() {
        guard hooks != nil else { return }
        finish(keep: false)
    }

    func captureNextFrameForTesting(predictedPoints: CGFloat = 0) async {
        guard hooks != nil, !finished, !finishing, prepared, !captureInFlight else { return }
        captureInFlight = true
        await captureAndStitch(predictedPoints: predictedPoints)
        captureInFlight = false
        finishAfterRepeatedCaptureFailures()
    }
}
