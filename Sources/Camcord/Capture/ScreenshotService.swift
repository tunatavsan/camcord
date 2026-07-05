import AppKit
import ScreenCaptureKit
import os

enum CaptureError: Error {
    case timeout
    case noDisplay
    case noWindow
    case sckFailure(Error)
}

/// Thin wrappers around `SCScreenshotManager`, one call per capture kind.
enum ScreenshotService {
    private static let logger = Logger(subsystem: "dev.tavsan.camcord", category: "screenshot-service")
    private static let fetchTimeout: Duration = .seconds(2)

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
    static func captureWindow(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
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
    static func captureDisplay(_ display: SCDisplay) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.width = Int(CGFloat(display.width) * CGFloat(filter.pointPixelScale))
        configuration.height = Int(CGFloat(display.height) * CGFloat(filter.pointPixelScale))
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
