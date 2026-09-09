import AppKit
import ScreenCaptureKit
import os

enum CaptureError: Error {
    case timeout
    case noDisplay
    case noWindow
    case displayConfigurationChanged
    case sckFailure(Error)
}

/// Thin wrappers around `SCScreenshotManager`, one call per capture kind.
enum ScreenshotService {
    private static let logger = Logger(subsystem: "dev.tavsan.camcord", category: "screenshot-service")
    private static let fetchTimeout: Duration = .seconds(2)

    /// Captures every attached display before any selection panel is presented. Each display is
    /// independent and runs concurrently; the immutable result is the sole pixel source for a
    /// later frozen region/window selection.
    @MainActor
    static func captureFrozenDesktop(resolutionScale: ResolutionScale) async throws -> FrozenDesktopSnapshot {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            throw CaptureError.noDisplay
        }
        let descriptors = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect)? in
            guard let id = screen.cgDirectDisplayID else { return nil }
            return (id, Geometry.appKitToCG(screen.frame, primaryScreenHeight: primaryHeight))
        }
        guard !descriptors.isEmpty else { throw CaptureError.noDisplay }

        // Sample z-order before capture and before our overlay exists. Screen pixels and window
        // metadata cannot be sampled atomically by public APIs, but both belong to this bounded
        // trigger-time phase.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = WindowSnapper.currentCandidates()
            .filter {
                $0.ownerPID != ownPID
                    && $0.layer == 0
                    && $0.bounds.width >= WindowSnapper.minimumSize
                    && $0.bounds.height >= WindowSnapper.minimumSize
            }
            .map { FrozenDesktopSnapshot.Window(id: $0.windowID, frame: $0.bounds) }

        let displays = try await withThrowingTaskGroup(of: FrozenDesktopSnapshot.Display.self) { group in
            for (id, frame) in descriptors {
                group.addTask {
                    let image = try await captureRegion(cgRect: frame)
                    return FrozenDesktopSnapshot.Display(id: id, cgFrame: frame, image: image)
                }
            }
            var captured: [FrozenDesktopSnapshot.Display] = []
            captured.reserveCapacity(descriptors.count)
            for try await display in group {
                captured.append(display)
            }
            return captured
        }

        // A hot-plug while capture was in flight invalidates every coordinate mapping. Cancel the
        // session rather than drawing one screen's pixels on another.
        let currentFrames = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            screen.cgDirectDisplayID.map {
                ($0, Geometry.appKitToCG(screen.frame, primaryScreenHeight: primaryHeight))
            }
        })
        let expectedFrames = Dictionary(uniqueKeysWithValues: descriptors)
        guard currentFrames.count == expectedFrames.count,
            expectedFrames.allSatisfy({ id, frame in
                guard let current = currentFrames[id] else { return false }
                return abs(current.minX - frame.minX) < 0.01
                    && abs(current.minY - frame.minY) < 0.01
                    && abs(current.width - frame.width) < 0.01
                    && abs(current.height - frame.height) < 0.01
            })
        else { throw CaptureError.displayConfigurationChanged }

        let order = Dictionary(uniqueKeysWithValues: descriptors.enumerated().map { ($0.element.0, $0.offset) })
        return FrozenDesktopSnapshot(
            displays: displays.sorted { order[$0.id, default: .max] < order[$1.id, default: .max] },
            windows: windows,
            resolutionScale: resolutionScale
        )
    }

    /// Captures an arbitrary screen-space rect, possibly spanning multiple displays.
    /// Uses `SCScreenshotManager.captureImage(in:)` -- NOT `SCContentFilter` + `sourceRect`,
    /// which is bound to a single display and returns an empty image for cross-display rects.
    /// Does not touch `ShareableContentCache` -- region capture needs no shareable content.
    static func captureRegion(cgRect: CGRect) async throws -> CGImage {
        try await withRetry {
            try await withTimeout {
                do {
                    return try await SCScreenshotManager.captureImage(in: cgRect)
                } catch {
                    throw CaptureError.sckFailure(error)
                }
            }
        }
    }

    /// Captures a single window without bringing it forward.
    static func captureWindow(
        _ window: SCWindow,
        resolutionScale: ResolutionScale = .native
    ) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        configuration.captureResolution = .best
        let scale = resolutionScale == .native ? CGFloat(filter.pointPixelScale) : 1
        configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        let box = FilterConfigurationBox(filter: filter, configuration: configuration)

        return try await withRetry {
            try await withTimeout {
                do {
                    return try await SCScreenshotManager.captureImage(contentFilter: box.filter, configuration: box.configuration)
                } catch {
                    throw CaptureError.sckFailure(error)
                }
            }
        }
    }

    /// Captures a single window downscaled to at most `maxWidth` points wide — a cheap
    /// thumbnail for the recording window picker (a full-res grab of a 4K game window would
    /// be wasteful when it renders into a ~240pt cell).
    static func captureWindowThumbnail(_ window: SCWindow, maxWidth: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        let contentRect = filter.contentRect
        let scale = contentRect.width > maxWidth ? maxWidth / contentRect.width : 1
        configuration.width = max(2, Int((contentRect.width * scale).rounded()))
        configuration.height = max(2, Int((contentRect.height * scale).rounded()))
        let box = FilterConfigurationBox(filter: filter, configuration: configuration)

        return try await withRetry {
            try await withTimeout {
                do {
                    return try await SCScreenshotManager.captureImage(contentFilter: box.filter, configuration: box.configuration)
                } catch {
                    throw CaptureError.sckFailure(error)
                }
            }
        }
    }

    /// Captures an entire display.
    static func captureDisplay(
        _ display: SCDisplay,
        resolutionScale: ResolutionScale = .native
    ) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.captureResolution = .best
        // SCDisplay.width/height are POINTS; the config wants PIXELS — without the
        // scale every Retina full-screen shot comes out at a quarter of the pixels.
        let scale = resolutionScale == .native ? CGFloat(filter.pointPixelScale) : 1
        configuration.width = max(1, Int((CGFloat(display.width) * scale).rounded()))
        configuration.height = max(1, Int((CGFloat(display.height) * scale).rounded()))
        let box = FilterConfigurationBox(filter: filter, configuration: configuration)

        return try await withRetry {
            try await withTimeout {
                do {
                    return try await SCScreenshotManager.captureImage(contentFilter: box.filter, configuration: box.configuration)
                } catch {
                    throw CaptureError.sckFailure(error)
                }
            }
        }
    }

    // MARK: - Timeout + retry

    private static func withRetry(_ operation: @escaping @Sendable () async throws -> CGImage) async throws -> CGImage {
        do {
            return try await operation()
        } catch {
            logger.error("Capture failed, retrying once: \(String(describing: error), privacy: .public)")
            return try await operation()
        }
    }

    /// Hard wall-clock bound: a hung SCK call is abandoned, not awaited (see
    /// `withHardTimeout` — task-group cancellation can't bound non-cooperative calls).
    private static func withTimeout(_ operation: @escaping @Sendable () async throws -> CGImage) async throws -> CGImage {
        try await withHardTimeout(fetchTimeout, onTimeout: CaptureError.timeout, operation: operation)
    }
}

/// `SCContentFilter`/`SCStreamConfiguration` are not `Sendable`-annotated in the SDK,
/// but each is created fresh per capture call, configured synchronously, then only
/// read (never mutated) by the single async `captureImage` call before being
/// discarded -- there is no concurrent access to guard against. This box lets that
/// single-owner, read-only value cross into the task-group child task.
private struct FilterConfigurationBox: @unchecked Sendable {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
}
