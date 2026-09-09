import AppKit
import ImageIO
@preconcurrency import ScreenCaptureKit
import os

/// Owns the shareable-content cache and selection overlay, and wires them into the
/// user-facing capture flows. Every flow ends in a clipboard write; nothing here ever
/// crashes -- failures log, play the error cue, and flash the status glyph.
@MainActor
final class CaptureCoordinator {
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

    /// Wired by AppDelegate to the bottom-left screenshot preview card. Screenshots surface
    /// here instead of the center toast: the framed preview IS their "copied" confirmation,
    /// and it's clickable (opens for editing) / draggable. `fileURL` is the on-disk PNG when
    /// disk-saving is on, else nil (the card writes a temp file on demand).
    var onScreenshotPreview: ((CGImage, URL?) -> Void)?
    var onScreenshotSaved: ((CGImage, URL) -> Void)?

    /// One capture flow at a time: the overlay's own isPresenting only covers the
    /// on-screen phase, not the post-hide delay + SCK call after it — a re-press in
    /// that window would open a NEW overlay whose chrome gets baked into the still-
    /// pending shot. Also collapses double-clicks on the panel's tiles.
    private var isCapturing = false
    /// Newest accepted OCR/capture owns future clipboard writes. Generation is allocated at
    /// request acceptance, so two concurrent OCR jobs cannot complete out of order and let the
    /// older one overwrite the newer result.
    private var clipboardRequests = LatestRequestGate()

    private final class FrozenHoldRequest {
        let token: UInt64
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
            anchor: CGPoint,
            mode: HoldCaptureMode,
            resolutionScale: ResolutionScale,
            displayFrame: CGRect
        ) {
            self.token = token
            self.anchor = anchor
            self.latest = anchor
            self.mode = mode
            self.resolutionScale = resolutionScale
            self.displayFrame = displayFrame
        }
    }

    private var holdRequests = LatestRequestGate()
    private var frozenHoldRequest: FrozenHoldRequest?
    private var pendingHoldSnapshots = 0
    private static let maximumPendingHoldSnapshots = 2
    private static let holdDragThreshold: CGFloat = 4

    /// After hiding the overlay, wait ~2 display refresh cycles before capturing so
    /// the compositor has actually flushed the hide -- otherwise the screenshot
    /// contains our own dimming/selection chrome.
    private static let postHideDelay: Duration = .milliseconds(80)

    init() {
        let cache = ShareableContentCache()
        self.cache = cache
        overlay = SelectionOverlayController(shareableContentCache: cache)
        invalidator = ShareableContentCacheInvalidator(cache: cache)
    }

    // MARK: - Shared surfaces (recording reuses the same cache + overlay)

    var contentCache: ShareableContentCache { cache }

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
        let settings = ScreenshotSettings.load(from: .standard)
        do {
            guard let cursorPoint = currentCursorCGPoint() else {
                fail("Frozen region capture: no display under the pointer")
                return
            }
            let snapshot = try await ScreenshotService.captureFrozenDesktop(
                resolutionScale: settings.resolutionScale,
                atCGPoint: cursorPoint
            )
            guard let (selection, mode) = await overlay.selectFrozen(snapshot: snapshot) else { return }
            switch mode {
            case .screenshot:
                switch selection {
                case .region(let cgRect):
                    await performFrozenScreenshot(snapshot, cgRect: cgRect)
                case .window(let window):
                    await performWindowCapture(window)
                }
            case .text:
                let cgRect: CGRect
                switch selection {
                case .region(let region): cgRect = region
                case .window(let window): cgRect = window.frame
                }
                performFrozenText(snapshot, cgRect: cgRect)
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
            performFrozenText(snapshot, cgRect: cgRect)
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

        let image = await ScrollingCaptureSession(region: clampedRegion, display: display).run()
        guard let image else { return }  // cancelled by the user — no chirp
        let acceptedToken = clipboardRequests.begin()

        // The stitched image is taller than the viewport; derive its point size from the
        // captured pixel scale so DPI-aware pastes stay correct.
        let scale = clampedRegion.width > 0 ? CGFloat(image.width) / clampedRegion.width : 2
        var pointSize = CGSize(width: clampedRegion.width, height: CGFloat(image.height) / max(scale, 0.01))
        let resolutionScale = ScreenshotSettings.load(from: .standard).resolutionScale
        let outputImage: CGImage
        if resolutionScale == .native {
            outputImage = image
        } else {
            let maximumPixels: CGFloat = 50_000_000
            let requestedPixels = max(1, pointSize.width * pointSize.height)
            let capScale = min(1, sqrt(maximumPixels / requestedPixels))
            let cappedSize = CGSize(
                width: max(1, floor(pointSize.width * capScale)),
                height: max(1, floor(pointSize.height * capScale))
            )
            if capScale < 1 { pointSize = cappedSize }
            let scaled = await Task.detached(priority: .userInitiated) {
                FrozenDesktopSnapshot.scaledImage(image, pointSize: cappedSize, resolutionScale: .oneX)
            }.value
            guard let scaled else {
                fail("Scroll capture: output scaling failed")
                return
            }
            outputImage = scaled
        }
        guard let copied = await copyScreenshot(outputImage, pointSize: pointSize, acceptedToken: acceptedToken) else { return }
        guard copied else {
            fail("Scroll capture: clipboard write failed")
            return
        }
        succeeded(.fullScreenShot, preview: (outputImage, nil))
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
            anchor: anchor,
            mode: mode,
            resolutionScale: ScreenshotSettings.load(from: .standard).resolutionScale,
            displayFrame: displayFrame
        )
        frozenHoldRequest = request
        pendingHoldSnapshots += 1
        request.captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingHoldSnapshots = max(0, self.pendingHoldSnapshots - 1) }
            do {
                try Task.checkCancellation()
                let snapshot = try await ScreenshotService.captureFrozenDesktop(
                    resolutionScale: request.resolutionScale,
                    atCGPoint: request.anchor
                )
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
                await self.performFrozenScreenshot(snapshot, cgRect: cgRect)
            case .text:
                self.performFrozenText(snapshot, cgRect: cgRect)
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
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let point = NSEvent.mouseLocation
        return Geometry.appKitToCG(
            CGRect(origin: point, size: .zero),
            primaryScreenHeight: primaryHeight
        ).origin
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
            await performWindowCapture(window)
        } catch {
            fail("captureActiveWindow: failed to fetch shareable content: \(error)")
        }
    }

    // MARK: - Full-screen screenshot

    /// Captures the entire display containing the mouse pointer.
    func captureFullScreen() async {
        guard beginExclusiveCapture() else { return }
        defer { endExclusiveCapture() }
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
            let settings = ScreenshotSettings.load(from: .standard)
            let image = try await ScreenshotService.captureDisplay(
                display,
                resolutionScale: settings.resolutionScale
            )
            guard let copied = await copyScreenshot(image, pointSize: screen.frame.size) else { return }
            guard copied else {
                fail("captureFullScreen: clipboard write failed")
                return
            }
            succeeded(.fullScreenShot, preview: (image, nil))
        } catch {
            fail("captureFullScreen: capture failed: \(error)")
        }
    }

    // MARK: - Shared steps

    private func performRegionScreenshot(_ cgRect: CGRect) async {
        do {
            let image = try await ScreenshotService.captureRegion(cgRect: cgRect)
            guard let copied = await copyScreenshot(image, pointSize: cgRect.size) else { return }
            guard copied else {
                fail("Region capture: clipboard write failed")
                return
            }
            succeeded(.regionShot, preview: (image, nil))
        } catch {
            fail("Region capture failed: \(error)")
        }
    }

    private func performFrozenScreenshot(
        _ snapshot: FrozenDesktopSnapshot,
        cgRect: CGRect
    ) async {
        let acceptedToken = clipboardRequests.begin()
        let cropped = await Task.detached(priority: .userInitiated) { snapshot.crop(cgRect: cgRect) }.value
        guard let crop = cropped else {
            fail("Frozen region capture: selection did not intersect a display")
            return
        }
        guard let copied = await copyScreenshot(crop.image, pointSize: crop.pointSize, acceptedToken: acceptedToken) else { return }
        guard copied else {
            fail("Frozen region capture: clipboard write failed")
            return
        }
        succeeded(.regionShot, preview: (crop.image, nil))
    }

    private func performFrozenText(_ snapshot: FrozenDesktopSnapshot, cgRect: CGRect) {
        let token = clipboardRequests.begin()
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

    private func performRegionText(_ cgRect: CGRect) async {
        do {
            let image = try await ScreenshotService.captureRegion(cgRect: cgRect)
            startOCR(on: image)   // fire-and-forget: lock releases now, OCR finishes in bg
        } catch {
            fail("Text capture failed: \(error)")
        }
    }

    private func performWindowCapture(_ window: SCWindow) async {
        do {
            let settings = ScreenshotSettings.load(from: .standard)
            let image = try await ScreenshotService.captureWindow(
                window,
                resolutionScale: settings.resolutionScale
            )
            guard let copied = await copyScreenshot(image, pointSize: window.frame.size) else { return }
            guard copied else {
                fail("Window capture: clipboard write failed")
                return
            }
            succeeded(.windowShot, preview: (image, nil))
        } catch {
            fail("Window capture failed: \(error)")
        }
    }

    private func performWindowText(_ window: SCWindow) async {
        do {
            let image = try await ScreenshotService.captureWindow(window)
            startOCR(on: image)   // fire-and-forget: lock releases now, OCR finishes in bg
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
            let payload: String
            do {
                payload = try await TextRecognitionService.read(in: image).clipboardString
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
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(payload, forType: .string) else {
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
            NSSound.beep()
            return false
        }
        isCapturing = true
        return true
    }

    private func endExclusiveCapture() {
        isCapturing = false
    }

    private func preflightScreenCapture(_ flow: String) -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            fail("\(flow): Screen Recording permission missing")
            return false
        }
        return true
    }

    /// nil means a newer accepted result superseded this clipboard publication.
    private func copyScreenshot(_ image: CGImage, pointSize: CGSize, acceptedToken: UInt64? = nil) async -> Bool? {
        let token = acceptedToken ?? clipboardRequests.begin()
        let copied = await ClipboardWriter.copyPNG(
            image, pointSize: pointSize,
            saveSettings: ScreenshotSettings.load(from: .standard),
            shouldPublish: { self.clipboardRequests.isCurrent(token) }
        ) { [weak self] result in
            switch result {
            case .success(let url): self?.onScreenshotSaved?(image, url)
            case .failure:
                self?.onToast?(ToastRequest(text: "Görüntü dosyaya kaydedilemedi — kayıt konumunu kontrol et", systemSymbol: "externaldrive.badge.exclamationmark", tint: .systemOrange, important: true))
            }
        }
        return clipboardRequests.isCurrent(token) ? copied : nil
    }

    /// Success feedback: the action's distinct sound + a brief status-glyph flash, plus
    /// EITHER a HUD toast (OCR text, which has no image) OR the bottom-left screenshot
    /// preview card (`preview` — the image that just landed on the clipboard, + its saved
    /// URL when disk-saving is on).
    private func succeeded(_ sound: FeedbackSound, toast: ToastRequest? = nil, preview: (image: CGImage, url: URL?)? = nil) {
        sound.play()
        onSuccess?()
        if let toast { onToast?(toast) }
        if let preview { onScreenshotPreview?(preview.image, preview.url) }
    }

    private func fail(_ message: String) {
        logger.error("\(message, privacy: .public)")
        FeedbackSound.error.play()
        onFailure?()
        // If the failure was really a lost Screen Recording grant (macOS 15+ periodic
        // re-approval), take the user to the fix once instead of chirping forever.
        PermissionRecovery.noteCaptureFailure()
    }
}
