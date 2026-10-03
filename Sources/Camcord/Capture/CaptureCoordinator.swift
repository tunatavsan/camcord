import AppKit
import ImageIO
@preconcurrency import ScreenCaptureKit
import os

/// Owns the shareable-content cache and selection overlay, and wires them into the
/// user-facing capture flows. Every flow ends in a clipboard write; nothing here ever
/// crashes -- failures log, play the error cue, and flash the status glyph.
@MainActor
final class CaptureCoordinator {
    @MainActor struct Operations {
        var screenCaptureAuthorized: () -> Bool = { CGPreflightScreenCaptureAccess() }
        var screenshotSettings: () -> ScreenshotSettings = { ScreenshotSettings.load(from: .standard) }
        var fullScreen: (() async throws -> (image: CGImage, pointSize: CGSize))?
        var fullScreenDisplayID: () -> CGDirectDisplayID? = {
            let mouse = NSEvent.mouseLocation
            return (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.cgDirectDisplayID
        }
        var captureFrozenDesktop: (ResolutionScale, CGPoint) async throws -> FrozenDesktopSnapshot = { scale, anchor in
            try await ScreenshotService.captureFrozenDesktop(resolutionScale: scale, atCGPoint: anchor)
        }
        var regionCursorPoint: () -> CGPoint? = {
            guard let height = NSScreen.screens.first?.frame.height else { return nil }
            return Geometry.appKitToCG(CGRect(origin: NSEvent.mouseLocation, size: .zero),
                                       primaryScreenHeight: height).origin
        }
        var regionFullscreenContext: () -> FullscreenContext = { FullscreenContext.current() }
        var regionSnapshotLog: (Int) -> Void = { DiagnosticsLog.append("region frozen-snapshot ms=\($0)") }
        var regionFallbackLog: (FullscreenContext) -> Void = {
            TriggerLog.overlay("UI-less capture allowed by fullscreen context \($0.logLine)")
        }
        var recognize: (CGImage) async throws -> String = { try await TextRecognitionService.read(in: $0).clipboardString }
        var recognitionFinished: () -> Void = {}
        var tagScrollCapture: @Sendable (URL) -> Bool = { CaptureFileRules.tagScrollCapture($0) }
        var publishText: (String) -> Bool = { payload in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(payload, forType: .string)
        }
        var copyPNG: (CGImage, CGSize, ScreenshotSettings, @escaping @MainActor () -> Bool,
                      @escaping @MainActor (Result<URL, Error>) -> Void) async -> Bool = {
            await ClipboardWriter.copyPNG($0, pointSize: $1, saveSettings: $2,
                                          shouldPublish: $3, onSaveComplete: $4)
        }
        var feedback = true
    }
    private let operations: Operations
    private let cache: ShareableContentCache
    private let overlay: SelectionOverlayController
    private let invalidator: ShareableContentCacheInvalidator
    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "capture-coordinator")

    /// Wired by AppDelegate to the status item's failure flash — a visual "that
    /// didn't work" to pair with the error sound. Fired after the failure is known,
    /// so it costs nothing on the capture hot path.
    var onFailure: (() -> Void)?

    /// Wired to the status item's success flash — a visual "it landed" to pair with
    /// the capture sound.
    var onSuccess: (() -> Void)?

    /// Wired by AppDelegate to the HUD toast — a transient thumbnail + "copied" confirmation.
    var onToast: ((ToastRequest) -> Void)?

    /// Stable typed screenshot delivery; AppDelegate owns Library and card fanout.
    var onScreenshotDelivery: ((ScreenshotDeliveryEvent) -> Void)?

    /// One capture flow at a time: the overlay's own isPresenting only covers the
    /// on-screen phase, not the post-hide delay + SCK call after it — a re-press in
    /// that window would open a NEW overlay whose chrome gets baked into the still-
    /// pending shot. Also collapses double-clicks on the panel's tiles.
    let captureTransition = CaptureTransitionState()
    var isCaptureTransitionActive: Bool { captureTransition.isActive }
    private var isCapturing = false {
        didSet { updateCaptureTransition() }
    }
    /// Newest accepted OCR/capture owns future clipboard writes. Generation is allocated at
    /// request acceptance, so two concurrent OCR jobs cannot complete out of order and let the
    /// older one overwrite the newer result.
    private var clipboardRequests = LatestRequestGate()

    /// Claims publication at the user action, before an asynchronous renderer or encoder starts.
    func claimClipboardPublication() -> (@MainActor () -> Bool) {
        let token = clipboardRequests.begin()
        return { [weak self] in self?.clipboardRequests.isCurrent(token) == true }
    }


    private final class FrozenHoldRequest {
        let token: UInt64
        let clipboardToken: UInt64
        let anchor: CGPoint
        let mode: HoldCaptureMode
        let resolutionScale: ResolutionScale
        let displayFrame: CGRect
        var latest: CGPoint
        var moved = false
        var releasedAt: CGPoint?
        var selectedRect: CGRect?
        var snapshot: FrozenDesktopSnapshot?
        var overlayStarted = false
        var captureTask: Task<Void, Never>?

        init(
            token: UInt64,
            clipboardToken: UInt64,
            anchor: CGPoint,
            mode: HoldCaptureMode,
            resolutionScale: ResolutionScale,
            displayFrame: CGRect
        ) {
            self.token = token
            self.clipboardToken = clipboardToken
            self.anchor = anchor
            self.latest = anchor
            self.mode = mode
            self.resolutionScale = resolutionScale
            self.displayFrame = displayFrame
        }
    }

    private var holdRequests = LatestRequestGate()
    private var frozenHoldRequest: FrozenHoldRequest?
    private var pendingHoldSnapshots = 0 {
        didSet { updateCaptureTransition() }
    }
    private func updateCaptureTransition() {
        captureTransition.update(exclusiveCapture: isCapturing, pendingHoldSnapshots: pendingHoldSnapshots)
    }
    private static let maximumPendingHoldSnapshots = 2
    private static let holdDragThreshold: CGFloat = 4

    /// After hiding the overlay, wait ~2 display refresh cycles before capturing so
    /// the compositor has actually flushed the hide -- otherwise the screenshot
    /// contains our own dimming/selection chrome.
    private static let postHideDelay: Duration = .milliseconds(80)

    init(operations: Operations = Operations(), selectionOverlay: SelectionOverlayController? = nil) {
        self.operations = operations
        let cache = ShareableContentCache()
        self.cache = cache
        overlay = selectionOverlay ?? SelectionOverlayController(shareableContentCache: cache)
        invalidator = ShareableContentCacheInvalidator(cache: cache)
    }

    // MARK: - Shared surfaces (recording reuses the same cache + overlay)

    var contentCache: ShareableContentCache { cache }

    /// The first `SCShareableContent` query of a process pays for the window enumeration AND
    /// the capture-server handshake, and today it lands on the critical path of the FIRST
    /// trigger — which is exactly the "it hangs once, then never again" the owner sees.
    /// Doing it at launch moves that cost off the gesture. No pixels are captured.
    func prewarm() {
        Task.detached(priority: .utility) { [cache] in
            let started = ContinuousClock.now
            let ok = (try? await cache.content()) != nil
            DiagnosticsLog.append("prewarm shareable-content ok=\(ok) ms=\(Self.elapsedMs(since: started))")
        }
    }

    nonisolated static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let elapsed = (ContinuousClock.now - start).components
        return Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }

    /// Presents the same selection overlay the screenshot flow uses and returns the
    /// user's pick, for RECORDING. The overlay tears its panels down before returning on
    /// every path. Left button = region drag / window click; right button = the whole
    /// screen under the pointer (one-gesture full-screen record).
    func selectCaptureTarget() async -> SelectionResult? {
        // Hold the same exclusive lock every capture flow uses, so a screenshot hotkey
        // (which may not touch the overlay at all — e.g. full-screen capture) can't fire
        // while the recording target overlay is up and bake its chrome into the shot.
        guard beginExclusiveCapture() else { return nil }
        defer { endExclusiveCapture() }
        // Recording target selection is red; screenshot selection stays blue.
        return await overlay.selectRegion(rightClickWholeScreen: true, accent: .recording)?.0
    }

    // MARK: - Region screenshot

    /// Shows the region/window selection overlay, then captures whichever the user
    /// picked. Left button (mode `.screenshot`) copies a PNG; right button (`.text`)
    /// OCRs the selection to a string.
    func captureRegionInteractive() async {
        guard beginExclusiveCapture() else { return }
        defer { endExclusiveCapture() }
        guard preflightScreenCapture("captureRegionInteractive") else { return }
        let acceptedToken = clipboardRequests.begin()
        let settings = operations.screenshotSettings()
        // Measure before any await or overlay ordering changes the app/window in front.
        let fullscreenContext = operations.regionFullscreenContext()
        do {
            guard let cursorPoint = currentCursorCGPoint() else {
                fail("Frozen region capture: no display under the pointer")
                return
            }
            // Timed because the first one of these in a process is a suspect for the
            // one-off stall; the file says whether the wait was here or in the overlay.
            let snapshotStart = ContinuousClock.now
            let snapshot = try await operations.captureFrozenDesktop(settings.resolutionScale, cursorPoint)
            operations.regionSnapshotLog(Self.elapsedMs(since: snapshotStart))
            guard let (selection, mode) = await overlay.selectFrozen(snapshot: snapshot) else {
                if overlay.consumeBlindPresentation() {
                    if fullscreenContext.isGameLike || fullscreenContext.coversDisplay {
                        operations.regionFallbackLog(fullscreenContext)
                        await performFrozenScreenshot(snapshot, cgRect: snapshot.desktopBounds, sound: .fullScreenShot, acceptedToken: acceptedToken)
                    } else {
                        fail("Region selection could not appear; fullscreen fallback refused")
                        onToast?(ToastRequest(text: String(localized: "The selection could not appear. Try the capture again."),
                                              systemSymbol: "exclamationmark.triangle", tint: .systemOrange, important: true))
                    }
                }
                return
            }
            switch mode {
            case .screenshot:
                switch selection {
                case .region(let cgRect):
                    await performFrozenScreenshot(snapshot, cgRect: cgRect, acceptedToken: acceptedToken)
                case .window(let window):
                    let origin = Self.originDisplayID(for: window.frame, displays: Self.currentDisplayFrames())
                    await performWindowCapture(window, originDisplayID: origin, acceptedToken: acceptedToken)
                }
            case .text:
                let cgRect: CGRect
                switch selection {
                case .region(let region): cgRect = region
                case .window(let window): cgRect = window.frame
                }
                performFrozenText(snapshot, cgRect: cgRect, acceptedToken: acceptedToken)
            }
        } catch {
            fail("Frozen region capture failed: \(error)")
        }
    }

    // MARK: - Region OCR

    /// Same overlay, but the result is OCR'd and copied as a STRING instead of a
    /// PNG — the "grab this error message / code snippet" flow.
    func captureTextRegionInteractive() async {
        guard beginExclusiveCapture() else { return }
        defer { endExclusiveCapture() }
        guard preflightScreenCapture("captureTextRegion") else { return }
        let acceptedToken = clipboardRequests.begin()
        do {
            guard let cursorPoint = currentCursorCGPoint() else {
                fail("Text capture: no display under the pointer")
                return
            }
            let snapshot = try await ScreenshotService.captureFrozenDesktop(
                resolutionScale: .native,
                atCGPoint: cursorPoint
            )
            // This entry point always OCRs, regardless of which button ended the selection.
            guard let (selection, _) = await overlay.selectFrozen(snapshot: snapshot) else { return }
            let cgRect: CGRect
            switch selection {
            case .region(let region): cgRect = region
            case .window(let window): cgRect = window.frame
            }
            performFrozenText(snapshot, cgRect: cgRect, acceptedToken: acceptedToken)
        } catch {
            fail("Text capture failed: \(error)")
        }
    }

    // MARK: - Scrolling capture (manual scroll + live stitch → one tall image)

    /// Pick a scroll area (region or window), then let the user scroll it while we stitch
    /// each settled viewport into one tall PNG, shown growing live in a side HUD. Ends on
    /// the HUD's Done (keep) or Esc / Cancel (discard, silently — not a failure).
    func captureScrollingInteractive() async {
        guard beginExclusiveCapture() else { return }
        defer { endExclusiveCapture() }
        guard preflightScreenCapture("scrollingCapture") else { return }
        let acceptedToken = clipboardRequests.begin()
        guard let (result, _) = await overlay.selectRegion() else { return }
        try? await Task.sleep(for: Self.postHideDelay)

        let region: CGRect
        switch result {
        case .region(let r): region = r
        case .window(let window): region = window.frame
        }
        guard region.width >= 1, region.height >= 1 else {
            fail("Scroll capture: empty selection")
            return
        }
        guard let display = await displayForRegion(region) else {
            fail("Scroll capture: no display for the selection")
            return
        }
        // Scroll capture uses SCContentFilter(display:)+sourceRect, which is bound to ONE
        // display — clamp the selection to that display so a region spanning two screens
        // can't produce an empty/garbage sourceRect (same single-display constraint
        // ScreenshotService documents for region shots).
        let clampedRegion = region.intersection(display.frame)
        guard clampedRegion.width >= 1, clampedRegion.height >= 1 else {
            fail("Scroll capture: selection is not on a single display")
            return
        }

        // This is the display bound to the actual scroll sourceRect. Preserve its identity
        // before the session or output scaling can suspend and the cursor can move.
        let originDisplayID = display.displayID
        let scrollResult = await ScrollingCaptureSession(region: clampedRegion, display: display).run()
        let image: CGImage
        var notice: ScrollingCaptureSession.Notice?
        switch scrollResult {
        case .cancelled: return
        case .failed(let reason):
            fail("Scroll capture failed")
            showScrollNotice(reason, keptContent: false)
            return
        case .completed(let captured, let reason): image = captured; notice = reason
        }

        // The stitched image is taller than the viewport; derive its point size from the
        // captured pixel scale so DPI-aware pastes stay correct.
        let scale = clampedRegion.width > 0 ? CGFloat(image.width) / clampedRegion.width : 2
        let pointSize = CGSize(width: clampedRegion.width, height: CGFloat(image.height) / max(scale, 0.01))
        let resolutionScale = operations.screenshotSettings().resolutionScale
        let outputImage: CGImage
        if resolutionScale == .native {
            outputImage = image
        } else {
            guard let cappedSize = Self.boundedScrollRasterSize(pointSize) else {
                fail("Scroll capture: invalid output dimensions")
                return
            }
            if pointSize.width * pointSize.height > 50_000_000 { notice = notice ?? .outputLimit }
            let scaled = await Task.detached(priority: .userInitiated) {
                FrozenDesktopSnapshot.scaledImage(image, pointSize: cappedSize, resolutionScale: .oneX)
            }.value
            guard let scaled else {
                fail("Scroll capture: output scaling failed")
                return
            }
            outputImage = scaled
        }
        guard let copied = await copyScreenshot(outputImage, pointSize: pointSize, acceptedToken: acceptedToken,
                                               kind: .scrollCapture, originDisplayID: originDisplayID) else { return }
        guard copied else {
            fail("Scroll capture: clipboard write failed")
            return
        }
        if let notice { showScrollNotice(notice, keptContent: true) }
        succeeded(.fullScreenShot)
    }

    /// The SCDisplay whose frame contains the region's center.
    private func displayForRegion(_ region: CGRect) async -> SCDisplay? {
        let center = CGPoint(x: region.midX, y: region.midY)
        guard let content = try? await cache.content() else { return nil }
        return content.displays.first { $0.frame.contains(center) } ?? content.displays.first
    }

    // MARK: - Hold-to-capture region (side button held; release = shoot)

    /// Begins a hold session at the button-down location. The EventTapEngine drives
    /// updates/finish from swallowed drag/up events; the overlay's onEnd fires
    /// exactly once on every exit path, which is where the exclusive-capture lock is
    /// released. `mode` decides screenshot vs OCR (the tap-then-hold variant).
    /// Returns whether the session actually started, so the caller only tracks/swallows
    /// the hold when it did.
    @discardableResult
    func beginHoldRegionSelection(atCGPoint cgPoint: CGPoint, mode: HoldCaptureMode) -> Bool {
        guard beginExclusiveCapture() else { return false }
        guard preflightScreenCapture("holdRegionCapture") else {
            endExclusiveCapture()
            return false
        }
        guard pendingHoldSnapshots < Self.maximumPendingHoldSnapshots else {
            endExclusiveCapture()
            NSSound.beep()
            return false
        }
        guard let displayFrame = displayFrame(containingCGPoint: cgPoint) else {
            endExclusiveCapture()
            return false
        }
        let anchor = Self.clampedPoint(cgPoint, to: displayFrame)
        let token = holdRequests.begin()
        let request = FrozenHoldRequest(
            token: token,
            clipboardToken: clipboardRequests.begin(),
            anchor: anchor,
            mode: mode,
            resolutionScale: operations.screenshotSettings().resolutionScale,
            displayFrame: displayFrame
        )
        frozenHoldRequest = request
        pendingHoldSnapshots += 1
        request.captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingHoldSnapshots = max(0, self.pendingHoldSnapshots - 1) }
            do {
                try Task.checkCancellation()
                let snapshot = try await self.operations.captureFrozenDesktop(request.resolutionScale, request.anchor)
                try Task.checkCancellation()
                self.holdSnapshotDidFinish(snapshot, request: request)
            } catch is CancellationError {
                // A no-drag release or explicit cancel normally cleaned this request up.
                // If cancellation came from below us, do the same cleanup here.
                self.abandonFrozenHold(request)
            } catch {
                self.holdSnapshotDidFail(error, request: request)
            }
        }
        // Snapshot acquisition and all later crop/OCR work run asynchronously. The event-tap
        // callback returns immediately, preserving side-button tap-versus-hold recognition.
        return true
    }

    func updateHoldRegionSelection(toCGPoint cgPoint: CGPoint) {
        guard let request = frozenHoldRequest else { return }
        let point = Self.clampedPoint(cgPoint, to: request.displayFrame)
        request.latest = point
        if !request.moved {
            request.moved = hypot(
                point.x - request.anchor.x,
                point.y - request.anchor.y
            ) >= Self.holdDragThreshold
        }
        guard request.moved else { return }
        if request.overlayStarted {
            overlay.updateHoldSelection(toCGPoint: point)
        } else {
            startFrozenHoldOverlay(request)
        }
    }

    func finishHoldRegionSelection(atCGPoint cgPoint: CGPoint) {
        guard let request = frozenHoldRequest else { return }
        let point = Self.clampedPoint(cgPoint, to: request.displayFrame)
        request.latest = point
        request.releasedAt = point
        if !request.moved {
            request.moved = hypot(
                point.x - request.anchor.x,
                point.y - request.anchor.y
            ) >= Self.holdDragThreshold
        }
        if request.overlayStarted {
            overlay.finishHoldSelection(atCGPoint: point)
            return
        }
        guard request.moved else {
            abandonFrozenHold(request)
            return
        }
        if request.snapshot != nil {
            completeFrozenHoldWithoutOverlay(request)
        }
    }

    func cancelHoldRegionSelection() {
        guard let request = frozenHoldRequest else { return }
        if request.overlayStarted {
            overlay.cancelHoldSelection()
        } else {
            abandonFrozenHold(request)
        }
    }

    private func holdSnapshotDidFinish(
        _ snapshot: FrozenDesktopSnapshot,
        request: FrozenHoldRequest
    ) {
        guard frozenHoldRequest === request, holdRequests.isCurrent(request.token) else { return }
        request.snapshot = snapshot
        if request.overlayStarted {
            overlay.setFrozenDesktopSnapshot(snapshot)
        } else if let selectedRect = request.selectedRect {
            finishFrozenHold(request, cgRect: selectedRect)
        } else if request.releasedAt != nil {
            completeFrozenHoldWithoutOverlay(request)
        } else if request.moved {
            startFrozenHoldOverlay(request)
        }
    }

    private func holdSnapshotDidFail(_ error: Error, request: FrozenHoldRequest) {
        guard frozenHoldRequest === request, holdRequests.isCurrent(request.token) else { return }
        if request.overlayStarted {
            overlay.cancelHoldSelection()
        } else {
            abandonFrozenHold(request)
        }
        fail("Hold capture snapshot failed: \(error)")
    }

    private func startFrozenHoldOverlay(_ request: FrozenHoldRequest) {
        guard frozenHoldRequest === request, !request.overlayStarted else { return }
        let started = overlay.beginHoldSelection(
            atCGPoint: request.anchor,
            mode: request.mode,
            frozenSnapshot: request.snapshot,
            constrainedToCGFrame: request.displayFrame
        ) { [weak self, weak request] result in
            guard let self, let request else { return }
            guard self.frozenHoldRequest === request else { return }
            request.overlayStarted = false
            guard case .region(let cgRect) = result else {
                self.abandonFrozenHold(request)
                return
            }
            request.selectedRect = cgRect
            if request.snapshot != nil {
                self.finishFrozenHold(request, cgRect: cgRect)
            }
        }
        guard started else {
            abandonFrozenHold(request)
            return
        }
        request.overlayStarted = true
        overlay.updateHoldSelection(toCGPoint: request.latest)
    }

    private func completeFrozenHoldWithoutOverlay(_ request: FrozenHoldRequest) {
        guard let releasedAt = request.releasedAt else { return }
        let rect = Geometry.normalizedRect(from: request.anchor, to: releasedAt)
        guard rect.width >= 1, rect.height >= 1 else {
            abandonFrozenHold(request)
            return
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        finishFrozenHold(request, cgRect: rect)
    }

    private func finishFrozenHold(_ request: FrozenHoldRequest, cgRect: CGRect) {
        guard frozenHoldRequest === request, let snapshot = request.snapshot else { return }
        request.captureTask?.cancel()
        request.captureTask = nil
        frozenHoldRequest = nil
        holdRequests.invalidate()
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch request.mode {
            case .screenshot:
                await self.performFrozenScreenshot(snapshot, cgRect: cgRect, acceptedToken: request.clipboardToken)
            case .text:
                self.performFrozenText(snapshot, cgRect: cgRect, acceptedToken: request.clipboardToken)
            }
            self.endExclusiveCapture()
        }
    }

    private func abandonFrozenHold(_ request: FrozenHoldRequest) {
        guard frozenHoldRequest === request else { return }
        request.captureTask?.cancel()
        request.captureTask = nil
        frozenHoldRequest = nil
        holdRequests.invalidate()
        if request.overlayStarted { overlay.cancelHoldSelection() }
        endExclusiveCapture()
    }

    private func currentCursorCGPoint() -> CGPoint? {
        operations.regionCursorPoint()
    }

    private func displayFrame(containingCGPoint point: CGPoint) -> CGRect? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let frames = NSScreen.screens.map {
            Geometry.appKitToCG($0.frame, primaryScreenHeight: primaryHeight)
        }
        return frames.first { $0.contains(point) } ?? frames.first
    }

    private static func clampedPoint(_ point: CGPoint, to frame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, frame.minX), frame.maxX),
            y: min(max(point.y, frame.minY), frame.maxY)
        )
    }

    // MARK: - OCR on an existing image (file / dropped / Services)

    /// Extracts text (+ any QR/barcodes) from an image FILE the user already has and
    /// copies it to the clipboard — the "I have a screenshot, pull the text out of it"
    /// flow. Independent of live screen capture, so it needs no Screen Recording grant.
    func captureTextFromImageFile(_ url: URL) {
        guard let image = Self.loadCGImage(from: url) else {
            fail("OCR from file: could not read an image at \(url.path)")
            return
        }
        startOCR(on: image)
    }

    /// Same, for an image already in memory (e.g. from the Services pasteboard).
    func captureTextFromImage(_ image: CGImage) {
        startOCR(on: image)
    }

    /// Decodes the first image in a file via ImageIO — handles PNG/JPEG/HEIC/TIFF/etc.
    private static func loadCGImage(from url: URL) -> CGImage? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return image
    }

    // MARK: - Window screenshot

    /// Captures the frontmost app's first on-screen, normal-layer window. If WE are
    /// frontmost, fall back to the topmost other app's window — "active window" never
    /// means Camcord itself.
    func captureActiveWindow() async {
        guard beginExclusiveCapture() else { return }
        defer { endExclusiveCapture() }
        guard preflightScreenCapture("captureActiveWindow") else { return }
        let acceptedToken = clipboardRequests.begin()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            fail("captureActiveWindow: no display")
            return
        }
        let displayFrames = NSScreen.screens.map {
            Geometry.appKitToCG($0.frame, primaryScreenHeight: primaryHeight)
        }
        let ordered = WindowSnapper.currentCandidates()
        let originFrames = Self.currentDisplayFrames()
        // Cache enumeration may suspend or refresh. Source geometry comes from the same
        // trigger-time WindowServer candidates used to choose both the preferred and fallback
        // target, so a later cursor movement or hotplug cannot reassign this request.
        let originIDs = Dictionary(ordered.map {
            ($0.windowID, Self.originDisplayID(for: $0.bounds, displays: originFrames))
        }, uniquingKeysWith: { first, _ in first })
        let preferredID = WindowSnapper.activeWindowID(
            ordered: ordered,
            frontmostPID: frontmost?.processIdentifier,
            ownPID: ownPID,
            displayFrames: displayFrames
        )
        do {
            var content = try await cache.content()
            var window = preferredID.flatMap { id in
                content.windows.first { $0.windowID == id && $0.isOnScreen }
            }
            // A new or newly-visible window can precede the cache by a few seconds. One forced
            // refresh is the bounded fallback; target order still comes from WindowServer.
            if window == nil {
                content = try await cache.content(forceRefresh: true)
                let capturableIDs = Set(content.windows.filter(\.isOnScreen).map(\.windowID))
                let fallbackID = WindowSnapper.activeWindowID(
                    ordered: ordered.filter { capturableIDs.contains($0.windowID) },
                    frontmostPID: frontmost?.processIdentifier,
                    ownPID: ownPID,
                    displayFrames: displayFrames
                )
                window = fallbackID.flatMap { id in
                    content.windows.first { $0.windowID == id && $0.isOnScreen }
                }
            }

            guard let window else {
                fail("captureActiveWindow: no eligible on-screen window found")
                return
            }
            await performWindowCapture(window, originDisplayID: originIDs[window.windowID] ?? nil,
                                       acceptedToken: acceptedToken)
        } catch {
            fail("captureActiveWindow: failed to fetch shareable content: \(error)")
        }
    }

    // MARK: - Full-screen screenshot

    /// Captures the entire display containing the mouse pointer.
    func captureFullScreen() async {
        guard beginExclusiveCapture() else { return }
        defer { endExclusiveCapture() }
        guard preflightScreenCapture("captureFullScreen") else { return }
        let acceptedToken = clipboardRequests.begin()
        if let capture = operations.fullScreen {
            let originDisplayID = operations.fullScreenDisplayID()
            do {
                let pixels = try await capture()
                guard !Task.isCancelled else { return }
                guard let copied = await copyScreenshot(pixels.image, pointSize: pixels.pointSize, acceptedToken: acceptedToken,
                                                       originDisplayID: originDisplayID) else { return }
                if copied { succeeded(.fullScreenShot) }
                else { fail("captureFullScreen: clipboard write failed") }
            } catch { fail("captureFullScreen: capture failed: \(error)") }
            return
        }
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            fail("captureFullScreen: no screen under the pointer")
            return
        }
        guard let displayID = screen.cgDirectDisplayID else {
            fail("captureFullScreen: could not resolve CGDirectDisplayID for screen")
            return
        }
        do {
            let content = try await cache.content()
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                fail("captureFullScreen: no SCDisplay match for display \(displayID)")
                return
            }
            let settings = operations.screenshotSettings()
            let image = try await ScreenshotService.captureDisplay(
                display,
                resolutionScale: settings.resolutionScale
            )
            guard let copied = await copyScreenshot(image, pointSize: screen.frame.size, acceptedToken: acceptedToken,
                                                   originDisplayID: displayID) else { return }
            guard copied else {
                fail("captureFullScreen: clipboard write failed")
                return
            }
            succeeded(.fullScreenShot)
        } catch {
            fail("captureFullScreen: capture failed: \(error)")
        }
    }

    // MARK: - Shared steps

    private func performRegionScreenshot(_ cgRect: CGRect, acceptedToken: UInt64? = nil) async {
        let token = acceptedToken ?? clipboardRequests.begin()
        let originDisplayID = Self.originDisplayID(for: cgRect, displays: Self.currentDisplayFrames())
        do {
            let image = try await ScreenshotService.captureRegion(cgRect: cgRect)
            guard let copied = await copyScreenshot(image, pointSize: cgRect.size, acceptedToken: token,
                                                   originDisplayID: originDisplayID) else { return }
            guard copied else {
                fail("Region capture: clipboard write failed")
                return
            }
            succeeded(.regionShot)
        } catch {
            fail("Region capture failed: \(error)")
        }
    }

    private func performFrozenScreenshot(
        _ snapshot: FrozenDesktopSnapshot,
        cgRect: CGRect,
        sound: FeedbackSound = .regionShot,
        acceptedToken: UInt64? = nil
    ) async {
        let acceptedToken = acceptedToken ?? clipboardRequests.begin()
        let originDisplayID = snapshot.displays.first?.id
        let cropped = await Task.detached(priority: .userInitiated) { snapshot.crop(cgRect: cgRect) }.value
        guard let crop = cropped else {
            fail("Frozen region capture: selection did not intersect a display")
            return
        }
        guard let copied = await copyScreenshot(crop.image, pointSize: crop.pointSize, acceptedToken: acceptedToken,
                                               originDisplayID: originDisplayID) else { return }
        guard copied else {
            fail("Frozen region capture: clipboard write failed")
            return
        }
        succeeded(sound)
    }

    private func performFrozenText(_ snapshot: FrozenDesktopSnapshot, cgRect: CGRect, acceptedToken: UInt64? = nil) {
        let token = acceptedToken ?? clipboardRequests.begin()
        Task { @MainActor in
            // Cross-display composition stays off the input thread, as does recognition.
            let crop = await Task.detached(priority: .userInitiated) {
                snapshot.crop(cgRect: cgRect, resolutionScale: .native)
            }.value
            guard clipboardRequests.isCurrent(token) else { return }
            guard let crop else {
                fail("Frozen text capture: selection did not intersect a display")
                return
            }
            startOCR(on: crop.image, acceptedToken: token)
        }
    }

    private func performRegionText(_ cgRect: CGRect, acceptedToken: UInt64? = nil) async {
        let token = acceptedToken ?? clipboardRequests.begin()
        do {
            let image = try await ScreenshotService.captureRegion(cgRect: cgRect)
            startOCR(on: image, acceptedToken: token)   // fire-and-forget: lock releases now, OCR finishes in bg
        } catch {
            fail("Text capture failed: \(error)")
        }
    }

    private func performWindowCapture(_ window: SCWindow, originDisplayID: CGDirectDisplayID?,
                                      acceptedToken: UInt64? = nil) async {
        let token = acceptedToken ?? clipboardRequests.begin()
        do {
            let settings = operations.screenshotSettings()
            let image = try await ScreenshotService.captureWindow(
                window,
                resolutionScale: settings.resolutionScale
            )
            guard let copied = await copyScreenshot(image, pointSize: window.frame.size, acceptedToken: token,
                                                   originDisplayID: originDisplayID) else { return }
            guard copied else {
                fail("Window capture: clipboard write failed")
                return
            }
            succeeded(.windowShot)
        } catch {
            fail("Window capture failed: \(error)")
        }
    }

    private func performWindowText(_ window: SCWindow, acceptedToken: UInt64? = nil) async {
        let token = acceptedToken ?? clipboardRequests.begin()
        do {
            let image = try await ScreenshotService.captureWindow(window)
            startOCR(on: image, acceptedToken: token)   // fire-and-forget: lock releases now, OCR finishes in bg
        } catch {
            fail("Window text capture failed: \(error)")
        }
    }

    /// Reads an already-captured image as text (OCR) + any QR/barcodes and writes the
    /// combined payload to the clipboard — FIRE-AND-FORGET, so a slow recognition never
    /// holds the exclusive-capture lock (the caller releases it as soon as the image is
    /// grabbed) and the app stays responsive to the next gesture. `read` runs the Vision
    /// work off the main actor; only the fast clipboard write + feedback hop back to it.
    /// Shared by the interactive OCR flow and the hold OCR gesture.
    private func startOCR(on image: CGImage, acceptedToken: UInt64? = nil) {
        let token = acceptedToken ?? clipboardRequests.begin()
        Task { @MainActor in
            defer { operations.recognitionFinished() }
            let payload: String
            do {
                payload = try await operations.recognize(image)
            } catch {
                guard clipboardRequests.isCurrent(token) else { return }
                fail("Text recognition failed: \(error)")
                return
            }
            // A newer capture claimed the clipboard while we were recognizing — don't
            // clobber the user's latest result with this now-stale OCR.
            guard clipboardRequests.isCurrent(token) else { return }
            guard !payload.isEmpty else {
                fail("Text capture: no readable text or code in the selection")
                return
            }
            guard operations.publishText(payload) else {
                fail("Text capture: clipboard write failed")
                return
            }
            succeeded(.textOCR, toast: ToastRequest(text: "Metin panoya kopyalandı", systemSymbol: "doc.on.clipboard.fill"))
        }
    }

    private func beginExclusiveCapture() -> Bool {
        guard !isCapturing else {
            // Another capture/session is active: an audible bonk beats a dead trigger —
            // without it the second attempt no-ops with zero feedback and reads as broken.
            if operations.feedback { NSSound.beep() }
            return false
        }
        isCapturing = true
        return true
    }

    private func endExclusiveCapture() {
        isCapturing = false
    }

    private func preflightScreenCapture(_ flow: String) -> Bool {
        guard operations.screenCaptureAuthorized() else {
            fail("\(flow): Screen Recording permission missing")
            return false
        }
        return true
    }

    /// nil means a newer accepted result superseded this clipboard publication.
    private func copyScreenshot(_ image: CGImage, pointSize: CGSize, acceptedToken: UInt64,
                                kind: CaptureItem.Kind = .screenshot,
                                originDisplayID: CGDirectDisplayID? = nil) async -> Bool? {
        let token = acceptedToken
        let settings = operations.screenshotSettings()
        let copies = settings.copyToClipboard
        let delivery = CapturedScreenshot(id: UUID(), image: image, pointSize: pointSize,
                                           kind: kind, saveToDiskRequested: settings.saveToDisk,
                                           originDisplayID: originDisplayID, copiedToClipboard: copies)
        let tagScrollCapture = operations.tagScrollCapture
        let copied = await operations.copyPNG(
            image, pointSize, settings,
            { copies && !Task.isCancelled && self.clipboardRequests.isCurrent(token) }
        ) { [weak self] result in
            switch result {
            case .success(let url):
                if delivery.kind == .scrollCapture {
                    Task { @MainActor [weak self] in
                        let tagged = await Task { @concurrent in tagScrollCapture(url) }.value
                        self?.onScreenshotDelivery?(.saved(delivery, url))
                        if !tagged {
                            self?.onToast?(ToastRequest(
                                text: String(localized: "Scroll capture saved, but its capture type could not be recorded"),
                                systemSymbol: "exclamationmark.triangle", tint: .systemOrange, important: true
                            ))
                        }
                    }
                } else {
                    self?.onScreenshotDelivery?(.saved(delivery, url))
                }
            case .failure:
                self?.onScreenshotDelivery?(.saveFailed(delivery))
                self?.onToast?(ToastRequest(text: "Görüntü dosyaya kaydedilemedi — kayıt konumunu kontrol et", systemSymbol: "externaldrive.badge.exclamationmark", tint: .systemOrange, important: true))
            }
        }
        guard !Task.isCancelled, clipboardRequests.isCurrent(token) else { return nil }
        // A Library-only capture is delivered without touching the clipboard.
        let delivered = copies ? copied : true
        if delivered { onScreenshotDelivery?(.ready(delivery)) }
        return delivered
    }

    /// Plans 1× output dimensions before raster allocation. The physical point size
    /// remains in delivery metadata even when the pixel budget requires downscaling.
    nonisolated static func boundedScrollRasterSize(_ pointSize: CGSize,
                                                    maximumPixels: Int = 50_000_000) -> CGSize? {
        guard pointSize.width.isFinite, pointSize.height.isFinite,
              pointSize.width >= 1, pointSize.height >= 1, maximumPixels > 0 else { return nil }
        let budget = min(maximumPixels, 50_000_000)
        let scale = min(1, sqrt(CGFloat(budget) / (pointSize.width * pointSize.height)))
        let width = min(CGFloat(budget), max(1, floor(pointSize.width * scale)))
        let height = min(CGFloat(budget / Int(width)), max(1, floor(pointSize.height * scale)))
        return CGSize(width: width, height: height)
    }

    private func showScrollNotice(_ notice: ScrollingCaptureSession.Notice, keptContent: Bool) {
        let text: String
        switch notice {
        case .captureFailed:
            text = keptContent ? String(localized: "Scroll capture stopped — captured content was kept")
                               : String(localized: "Scroll capture failed")
        case .preparationFailed:
            text = String(localized: "Scroll capture could not prepare a clean image")
        case .outputLimit:
            text = String(localized: "Scroll capture reached the image size limit")
        }
        onToast?(ToastRequest(text: text, systemSymbol: "exclamationmark.triangle", tint: .systemOrange, important: true))
    }

    func deliverScreenshotForTesting(_ image: CGImage, pointSize: CGSize,
                                     kind: CaptureItem.Kind = .screenshot,
                                     originDisplayID: CGDirectDisplayID? = nil) async -> Bool? {
        await copyScreenshot(image, pointSize: pointSize, acceptedToken: clipboardRequests.begin(),
                             kind: kind, originDisplayID: originDisplayID)
    }

    private static func currentDisplayFrames() -> [(id: CGDirectDisplayID, frame: CGRect)] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.cgDirectDisplayID else { return nil }
            return (id, CGDisplayBounds(id))
        }
    }

    /// Cross-display source rectangles belong to the display containing the most source area.
    /// CG coordinates preserve displays above or left of the primary screen. Equal areas choose
    /// the lowest display ID, so enumeration order cannot change the result.
    nonisolated static func originDisplayID(for sourceRect: CGRect,
                                           displays: [(id: CGDirectDisplayID, frame: CGRect)]) -> CGDirectDisplayID? {
        guard !sourceRect.isNull, !sourceRect.isInfinite,
              [sourceRect.minX, sourceRect.minY, sourceRect.width, sourceRect.height].allSatisfy(\.isFinite),
              sourceRect.width > 0, sourceRect.height > 0 else { return nil }
        var selectedID: CGDirectDisplayID?
        var selectedArea: CGFloat = 0
        for display in displays {
            let intersection = sourceRect.intersection(display.frame)
            let area = intersection.width * intersection.height
            guard !intersection.isNull, area.isFinite, area > 0 else { continue }
            if area > selectedArea || (area == selectedArea && display.id < (selectedID ?? .max)) {
                selectedID = display.id
                selectedArea = area
            }
        }
        return selectedID
    }

    /// Success feedback: the action's distinct sound + a brief status-glyph flash, plus
    /// optional OCR toast. Screenshot cards receive the separate typed delivery event.
    private func succeeded(_ sound: FeedbackSound, toast: ToastRequest? = nil) {
        if operations.feedback { sound.play() }
        onSuccess?()
        if let toast { onToast?(toast) }
    }

    private func fail(_ message: String) {
        logger.error("\(message, privacy: .public)")
        if operations.feedback { FeedbackSound.error.play() }
        onFailure?()
        // If the failure was really a lost Screen Recording grant (macOS 15+ periodic
        // re-approval), take the user to the fix once instead of chirping forever.
        if operations.feedback { PermissionRecovery.noteCaptureFailure() }
    }
}
