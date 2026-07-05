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

    /// One capture flow at a time: the overlay's own isPresenting only covers the
    /// on-screen phase, not the post-hide delay + SCK call after it — a re-press in
    /// that window would open a NEW overlay whose chrome gets baked into the still-
    /// pending shot. Also collapses double-clicks on the panel's tiles.
    private var isCapturing = false
    /// Bumped on every successful clipboard-writing capture. A fire-and-forget OCR snapshots
    /// it at launch and refuses to write if a newer capture has since claimed the clipboard,
    /// so a slow recognition can't clobber the user's latest result.
    private var clipboardEpoch = 0

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
        return await overlay.selectRegion(rightClickWholeScreen: true)?.0
    }

    // MARK: - Region screenshot

    /// Shows the region/window selection overlay, then captures whichever the user
    /// picked. Left button (mode `.screenshot`) copies a PNG; right button (`.text`)
    /// OCRs the selection to a string.
    func captureRegionInteractive() async {
        guard beginExclusiveCapture() else { return }
        defer { endExclusiveCapture() }
        guard preflightScreenCapture("captureRegionInteractive") else { return }
        guard let (result, mode) = await overlay.selectRegion() else { return }
        // The overlay has already ordered its panels out on this exit path (every
        // exit path does); give the compositor a couple of refresh cycles before we shoot.
        try? await Task.sleep(for: Self.postHideDelay)

        switch (result, mode) {
        case (.region(let cgRect), .screenshot):
            await performRegionScreenshot(cgRect)
        case (.region(let cgRect), .text):
            await performRegionText(cgRect)
        case (.window(let window), .screenshot):
            await performWindowCapture(window)
        case (.window(let window), .text):
            await performWindowText(window)
        }
    }

    // MARK: - Region OCR

    /// Same overlay, but the result is OCR'd and copied as a STRING instead of a
    /// PNG — the "grab this error message / code snippet" flow.
    func captureTextRegionInteractive() async {
        guard beginExclusiveCapture() else { return }
        defer { endExclusiveCapture() }
        guard preflightScreenCapture("captureTextRegion") else { return }
        // This entry point always OCRs, regardless of which button ended the selection.
        guard let (result, _) = await overlay.selectRegion() else { return }
        try? await Task.sleep(for: Self.postHideDelay)

        do {
            let image: CGImage
            switch result {
            case .region(let cgRect):
                image = try await ScreenshotService.captureRegion(cgRect: cgRect)
            case .window(let window):
                image = try await ScreenshotService.captureWindow(window)
            }
            startOCR(on: image)   // fire-and-forget: lock releases on return, OCR runs in bg
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

        // The stitched image is taller than the viewport; derive its point size from the
        // captured pixel scale so DPI-aware pastes stay correct.
        let scale = clampedRegion.width > 0 ? CGFloat(image.width) / clampedRegion.width : 2
        let pointSize = CGSize(width: clampedRegion.width, height: CGFloat(image.height) / max(scale, 0.01))
        guard await ClipboardWriter.copyPNG(image, pointSize: pointSize, saveTo: screenshotSaveURL()) else {
            fail("Scroll capture: clipboard write failed")
            return
        }
        succeeded(.fullScreenShot, toast: ToastRequest(text: "Kaydırmalı görüntü kopyalandı", thumbnail: toastThumbnail(image)))
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
        let started = overlay.beginHoldSelection(atCGPoint: cgPoint, mode: mode) { [weak self] result in
            guard let self else { return }
            guard case .region(let cgRect) = result else {
                endExclusiveCapture()
                return
            }
            Task { @MainActor in
                // Same compositor-flush wait as every other overlay exit.
                try? await Task.sleep(for: Self.postHideDelay)
                switch mode {
                case .screenshot:
                    await self.performRegionScreenshot(cgRect)
                case .text:
                    await self.performRegionText(cgRect)
                }
                self.endExclusiveCapture()
            }
        }
        // Overlay already up (a selection in flight): release the lock and tell the caller
        // NOT to track this gesture, so the event tap doesn't swallow it for nothing.
        guard started else {
            endExclusiveCapture()
            return false
        }
        return true
    }

    func updateHoldRegionSelection(toCGPoint cgPoint: CGPoint) {
        overlay.updateHoldSelection(toCGPoint: cgPoint)
    }

    func finishHoldRegionSelection(atCGPoint cgPoint: CGPoint) {
        overlay.finishHoldSelection(atCGPoint: cgPoint)
    }

    func cancelHoldRegionSelection() {
        overlay.cancelHoldSelection()
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
        let ownBundleID = Bundle.main.bundleIdentifier
        do {
            let content = try await cache.content()
            let isEligible: (SCWindow) -> Bool = { window in
                window.isOnScreen
                    && window.windowLayer == 0
                    && window.owningApplication?.bundleIdentifier != ownBundleID
                    && window.frame.width >= 40 && window.frame.height >= 40
            }

            let window: SCWindow?
            if let frontmost, frontmost.bundleIdentifier != ownBundleID {
                window = content.windows.first {
                    isEligible($0) && $0.owningApplication?.processID == frontmost.processIdentifier
                }
            } else {
                // content.windows is front-to-back: first eligible = topmost window.
                window = content.windows.first(where: isEligible)
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
            let image = try await ScreenshotService.captureDisplay(display)
            guard await ClipboardWriter.copyPNG(image, pointSize: screen.frame.size, saveTo: screenshotSaveURL()) else {
                fail("captureFullScreen: clipboard write failed")
                return
            }
            succeeded(.fullScreenShot, toast: ToastRequest(text: "Ekran panoya kopyalandı", thumbnail: toastThumbnail(image)))
        } catch {
            fail("captureFullScreen: capture failed: \(error)")
        }
    }

    // MARK: - Shared steps

    private func performRegionScreenshot(_ cgRect: CGRect) async {
        do {
            let image = try await ScreenshotService.captureRegion(cgRect: cgRect)
            guard await ClipboardWriter.copyPNG(image, pointSize: cgRect.size, saveTo: screenshotSaveURL()) else {
                fail("Region capture: clipboard write failed")
                return
            }
            succeeded(.regionShot, toast: ToastRequest(text: "Bölge panoya kopyalandı", thumbnail: toastThumbnail(image)))
        } catch {
            fail("Region capture failed: \(error)")
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
            let image = try await ScreenshotService.captureWindow(window)
            guard await ClipboardWriter.copyPNG(image, pointSize: window.frame.size, saveTo: screenshotSaveURL()) else {
                fail("Window capture: clipboard write failed")
                return
            }
            succeeded(.windowShot, toast: ToastRequest(text: "Pencere panoya kopyalandı", thumbnail: toastThumbnail(image)))
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
    private func startOCR(on image: CGImage) {
        let epoch = clipboardEpoch
        Task { @MainActor in
            let payload: String
            do {
                payload = try await TextRecognitionService.read(in: image).clipboardString
            } catch {
                fail("Text recognition failed: \(error)")
                return
            }
            // A newer capture claimed the clipboard while we were recognizing — don't
            // clobber the user's latest result with this now-stale OCR.
            guard clipboardEpoch == epoch else { return }
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
        guard !isCapturing else { return false }
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

    /// A file URL to also save the screenshot to, when disk-saving is enabled (nil
    /// otherwise). Screenshots save to their own folder, separate from recordings.
    private func screenshotSaveURL() -> URL? {
        ScreenshotSettings.load(from: .standard).uniqueSaveURL(date: Date())
    }

    /// Success feedback: the action's distinct sound + a brief status-glyph flash + an
    /// optional HUD toast (thumbnail of what landed on the clipboard).
    private func succeeded(_ sound: FeedbackSound, toast: ToastRequest? = nil) {
        clipboardEpoch &+= 1   // this capture now owns the clipboard (see startOCR)
        sound.play()
        onSuccess?()
        if let toast { onToast?(toast) }
    }

    /// A small NSImage thumbnail for the copy toast, from a captured CGImage.
    private func toastThumbnail(_ image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
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
