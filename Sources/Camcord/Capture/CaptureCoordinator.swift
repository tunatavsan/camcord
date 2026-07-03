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

    private static let lastRegionDefaultsKey = "lastCaptureRegion"
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

    // MARK: - Flows

    /// Shows the region/window selection overlay, then captures whichever the user picked.
    func captureRegionInteractive() async {
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

    /// Re-captures the last region with no overlay; falls back to the interactive
    /// flow if there is no stored region yet.
    func captureLastRegion() async {
        guard let cgRect = readLastRegion() else {
            await captureRegionInteractive()
            return
        }
        await performRegionCapture(cgRect, storeAsLastRegion: false)
    }

    /// Captures the frontmost app's first on-screen, normal-layer window.
    func captureActiveWindow() async {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            fail("captureActiveWindow: no frontmost application")
            return
        }
        do {
            let content = try await cache.content()
            guard
                let window = content.windows.first(where: { window in
                    window.owningApplication?.processID == frontmost.processIdentifier
                        && window.isOnScreen
                        && window.windowLayer == 0
                })
            else {
                fail("captureActiveWindow: no on-screen window found for \(frontmost.localizedName ?? "frontmost app")")
                return
            }
            await performWindowCapture(window)
        } catch {
            fail("captureActiveWindow: failed to fetch shareable content: \(error)")
        }
    }

    /// Captures the entire display containing the mouse pointer.
    func captureFullScreen() async {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            fail("captureFullScreen: no screen under the pointer")
            return
        }
        guard let displayID = screenNumber(of: screen) else {
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
            _ = await ClipboardWriter.copyPNG(image)
        } catch {
            fail("captureFullScreen: capture failed: \(error)")
        }
    }

    // MARK: - Shared steps

    private func performRegionCapture(_ cgRect: CGRect, storeAsLastRegion: Bool) async {
        do {
            let image = try await ScreenshotService.captureRegion(cgRect: cgRect)
            _ = await ClipboardWriter.copyPNG(image)
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
            _ = await ClipboardWriter.copyPNG(image)
        } catch {
            fail("Window capture failed: \(error)")
        }
    }

    private func fail(_ message: String) {
        logger.error("\(message, privacy: .public)")
        NSSound.beep()
    }

    private func screenNumber(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let value = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(value.uint32Value)
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
