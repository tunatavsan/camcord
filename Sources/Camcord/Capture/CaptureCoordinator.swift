import AppKit
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

    /// One capture flow at a time: the overlay's own isPresenting only covers the
    /// on-screen phase, not the post-hide delay + SCK call after it — a re-press in
    /// that window would open a NEW overlay whose chrome gets baked into the still-
    /// pending shot. Also collapses double-clicks on the panel's tiles.
    private var isCapturing = false

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
    /// user's pick. The overlay tears its panels down before returning on every path.
    func selectCaptureTarget() async -> SelectionResult? {
        await overlay.selectRegion()
    }

    // MARK: - Region screenshot

    /// Shows the region/window selection overlay, then captures whichever the user picked.
    func captureRegionInteractive() async {
        guard beginExclusiveCapture() else { return }
        defer { endExclusiveCapture() }
        guard preflightScreenCapture("captureRegionInteractive") else { return }
        guard let result = await overlay.selectRegion() else { return }
        // The overlay has already ordered its panels out on this exit path (every
        // exit path does); give the compositor a couple of refresh cycles before we shoot.
        try? await Task.sleep(for: Self.postHideDelay)

        switch result {
        case .region(let cgRect):
            await performRegionScreenshot(cgRect)
        case .window(let window):
            await performWindowCapture(window)
        }
    }

    // MARK: - Region OCR

    /// Same overlay, but the result is OCR'd and copied as a STRING instead of a
    /// PNG — the "grab this error message / code snippet" flow.
    func captureTextRegionInteractive() async {
        guard beginExclusiveCapture() else { return }
        defer { endExclusiveCapture() }
        guard preflightScreenCapture("captureTextRegion") else { return }
        guard let result = await overlay.selectRegion() else { return }
        try? await Task.sleep(for: Self.postHideDelay)

        do {
            let image: CGImage
            switch result {
            case .region(let cgRect):
                image = try await ScreenshotService.captureRegion(cgRect: cgRect)
            case .window(let window):
                image = try await ScreenshotService.captureWindow(window)
            }
            await ocrToClipboard(image)
        } catch {
            fail("Text capture failed: \(error)")
        }
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
        overlay.beginHoldSelection(atCGPoint: cgPoint) { [weak self] result in
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
            guard await ClipboardWriter.copyPNG(image, pointSize: screen.frame.size) else {
                fail("captureFullScreen: clipboard write failed")
                return
            }
            succeeded(.fullScreenShot)
        } catch {
            fail("captureFullScreen: capture failed: \(error)")
        }
    }

    // MARK: - Shared steps

    private func performRegionScreenshot(_ cgRect: CGRect) async {
        do {
            let image = try await ScreenshotService.captureRegion(cgRect: cgRect)
            guard await ClipboardWriter.copyPNG(image, pointSize: cgRect.size) else {
                fail("Region capture: clipboard write failed")
                return
            }
            succeeded(.regionShot)
        } catch {
            fail("Region capture failed: \(error)")
        }
    }

    private func performRegionText(_ cgRect: CGRect) async {
        do {
            let image = try await ScreenshotService.captureRegion(cgRect: cgRect)
            await ocrToClipboard(image)
        } catch {
            fail("Text capture failed: \(error)")
        }
    }

    private func performWindowCapture(_ window: SCWindow) async {
        do {
            let image = try await ScreenshotService.captureWindow(window)
            guard await ClipboardWriter.copyPNG(image, pointSize: window.frame.size) else {
                fail("Window capture: clipboard write failed")
                return
            }
            succeeded(.windowShot)
        } catch {
            fail("Window capture failed: \(error)")
        }
    }

    /// Runs OCR on an already-captured image and writes the recognized text as a
    /// clipboard string. Shared by the interactive OCR flow and the hold OCR gesture.
    private func ocrToClipboard(_ image: CGImage) async {
        do {
            let text = try await TextRecognitionService.recognizeText(in: image)
            guard !text.isEmpty else {
                fail("Text capture: no readable text in the selection")
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                fail("Text capture: clipboard write failed")
                return
            }
            succeeded(.textOCR)
        } catch {
            fail("Text recognition failed: \(error)")
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

    /// Success feedback: the action's distinct sound + a brief status-glyph flash.
    private func succeeded(_ sound: FeedbackSound) {
        sound.play()
        onSuccess?()
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
