import AppKit
@preconcurrency import ScreenCaptureKit
import os

/// Owns the shareable-content cache and selection overlay, and wires them into the
/// four user-facing capture flows. Every flow ends in a clipboard write; nothing here
/// ever crashes -- failures log + beep.
@MainActor
final class CaptureCoordinator {
    private let cache: ShareableContentCache
    private let overlay: SelectionOverlayController
    private let invalidator: ShareableContentCacheInvalidator
    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "capture-coordinator")

    /// Wired by AppDelegate to the status item's failure flash — a visual "that
    /// didn't work" to pair with the beep. Fired after the failure is known, so it
    /// costs nothing on the capture hot path.
    var onFailure: (() -> Void)?

    /// One capture flow at a time: the overlay's own isPresenting only covers the
    /// on-screen phase, not the post-hide delay + SCK call after it — a re-press in
    /// that window would open a NEW overlay whose chrome gets baked into the still-
    /// pending shot. Also collapses double-clicks on the panel's tiles.
    private var isCapturing = false

    private nonisolated static let lastRegionDefaultsKey = "lastCaptureRegion"
    /// After hiding the overlay, wait ~2 display refresh cycles before capturing so
    /// the compositor has actually flushed the hide -- otherwise the screenshot
    /// contains our own dimming/selection chrome.
    private static let postHideDelay: Duration = .milliseconds(80)

    /// The AppKit/CG global coordinate grid re-anchors when the primary display
    /// changes, so a stored last-region silently points at different content after
    /// a rearrange — clear it on any screen-parameter change (repeat-last then
    /// falls back to the interactive flow).
    private nonisolated(unsafe) var screenChangeObserver: NSObjectProtocol?

    init() {
        let cache = ShareableContentCache()
        self.cache = cache
        overlay = SelectionOverlayController(shareableContentCache: cache)
        invalidator = ShareableContentCacheInvalidator(cache: cache)
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            UserDefaults.standard.removeObject(forKey: Self.lastRegionDefaultsKey)
        }
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
    }

    // MARK: - Shared surfaces (recording reuses the same cache + overlay)

    var contentCache: ShareableContentCache { cache }

    /// Presents the same selection overlay the screenshot flow uses and returns the
    /// user's pick. The overlay tears its panels down before returning on every path.
    func selectCaptureTarget() async -> SelectionResult? {
        await overlay.selectRegion()
    }

    // MARK: - Flows

    /// Shows the region/window selection overlay, then captures whichever the user picked.
    func captureRegionInteractive() async {
        guard beginExclusiveCapture() else { return }
        defer { endExclusiveCapture() }
        await runRegionInteractive()
    }

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
            CaptureFeedback.playCaptureSound()
        } catch {
            fail("Text capture failed: \(error)")
        }
    }

    /// Re-captures the last region with no overlay; falls back to the interactive
    /// flow if there is no stored region yet — or if the stored region no longer
    /// intersects any live display (the display it was captured on was unplugged or
    /// rearranged; blindly capturing an off-screen rect would copy an empty/black
    /// image to the clipboard and chirp success).
    func captureLastRegion() async {
        guard beginExclusiveCapture() else { return }
        defer { endExclusiveCapture() }
        guard let cgRect = readLastRegion(), intersectsAnyDisplay(cgRect) else {
            await runRegionInteractive()
            return
        }
        await performRegionCapture(cgRect, storeAsLastRegion: false)
    }

    /// Shared body for the interactive region flow (called with the exclusive-capture
    /// guard already held, so the last-region fallback can nest into it).
    private func runRegionInteractive() async {
        guard preflightScreenCapture("captureRegionInteractive") else { return }
        guard let result = await overlay.selectRegion() else { return }
        // The overlay has already ordered its panels out on this exit path (every
        // exit path does); give the compositor a couple of refresh cycles before we shoot.
        try? await Task.sleep(for: Self.postHideDelay)

        switch result {
        case .region(let cgRect):
            await performRegionCapture(cgRect, storeAsLastRegion: true)
        case .window(let window):
            await performWindowCapture(window)
        }
    }

    /// The OS eyedropper loupe: samples one pixel, copies "#RRGGBB". Uses no
    /// ScreenCaptureKit and no TCC permission at all.
    func sampleColorToClipboard() async {
        guard beginExclusiveCapture() else { return }
        defer { endExclusiveCapture() }

        let sampler = NSColorSampler()
        let picked = await withCheckedContinuation { (continuation: CheckedContinuation<NSColor?, Never>) in
            // The closure captures the sampler so it stays alive until the user
            // picks or cancels — a deallocated sampler would dismiss the loupe.
            sampler.show { [sampler] color in
                _ = sampler
                continuation.resume(returning: color)
            }
        }
        // nil = user pressed Esc; that's a cancel, not a failure.
        guard let picked else { return }
        guard let srgb = picked.usingColorSpace(.sRGB) else {
            fail("Color sample: could not convert to sRGB")
            return
        }
        let hex = String(
            format: "#%02X%02X%02X",
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded())
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(hex, forType: .string) else {
            fail("Color sample: clipboard write failed")
            return
        }
        CaptureFeedback.playCaptureSound()
    }

    /// Restores the last screenshot's exact pixels to the clipboard (no re-shoot) —
    /// the undo for "captured, then Cmd-C'd something else before pasting".
    func recopyLastCapture() {
        guard ClipboardWriter.recopyLastCapture() else {
            fail("Re-copy: no capture taken yet this run")
            return
        }
        CaptureFeedback.playCaptureSound()
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

    private func intersectsAnyDisplay(_ cgRect: CGRect) -> Bool {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return false }
        return NSScreen.screens.contains { screen in
            let screenCGFrame = Geometry.appKitToCG(screen.frame, primaryScreenHeight: primaryHeight)
            return !screenCGFrame.intersection(cgRect).isEmpty
        }
    }

    /// Captures the frontmost app's first on-screen, normal-layer window. If WE are
    /// frontmost (the panel's shortcuts page activates the app), fall back to the
    /// topmost other app's window — "active window" never means Camcord itself.
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
            CaptureFeedback.playCaptureSound()
        } catch {
            fail("captureFullScreen: capture failed: \(error)")
        }
    }

    // MARK: - Shared steps

    private func performRegionCapture(_ cgRect: CGRect, storeAsLastRegion: Bool) async {
        do {
            let image = try await ScreenshotService.captureRegion(cgRect: cgRect)
            guard await ClipboardWriter.copyPNG(image, pointSize: cgRect.size) else {
                fail("Region capture: clipboard write failed")
                return
            }
            CaptureFeedback.playCaptureSound()
            if storeAsLastRegion {
                storeLastRegion(cgRect)
            }
        } catch {
            fail("Region capture failed: \(error)")
        }
    }

    private func performWindowCapture(_ window: SCWindow) async {
        do {
            let image = try await ScreenshotService.captureWindow(window)
            guard await ClipboardWriter.copyPNG(image, pointSize: window.frame.size) else {
                fail("Window capture: clipboard write failed")
                return
            }
            CaptureFeedback.playCaptureSound()
        } catch {
            fail("Window capture failed: \(error)")
        }
    }

    private func fail(_ message: String) {
        logger.error("\(message, privacy: .public)")
        NSSound.beep()
        onFailure?()
        // If the failure was really a lost Screen Recording grant (macOS 15+ periodic
        // re-approval), take the user to the fix once instead of beeping forever.
        PermissionRecovery.noteCaptureFailure()
    }

    // MARK: - Last-region persistence

    private func storeLastRegion(_ cgRect: CGRect) {
        let values: [Double] = [cgRect.origin.x, cgRect.origin.y, cgRect.width, cgRect.height]
        UserDefaults.standard.set(values, forKey: Self.lastRegionDefaultsKey)
    }

    private func readLastRegion() -> CGRect? {
        guard
            let values = UserDefaults.standard.array(forKey: Self.lastRegionDefaultsKey) as? [Double],
            values.count == 4
        else {
            return nil
        }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
}
