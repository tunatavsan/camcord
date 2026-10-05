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
    private static let fetchTimeoutNanoseconds: UInt64 = 2_000_000_000

    /// Captures only the display under the trigger pointer, excluding selection panels while
    /// retaining the other Camcord windows visible on that display.
    @MainActor
    static func captureFrozenDesktop(
        resolutionScale: ResolutionScale,
        atCGPoint anchor: CGPoint? = nil
    ) async throws -> FrozenDesktopSnapshot {
        try Task.checkCancellation()
        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            throw CaptureError.noDisplay
        }
        let descriptors = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect)? in
            guard let id = screen.cgDirectDisplayID else { return nil }
            return (id, Geometry.appKitToCG(screen.frame, primaryScreenHeight: primaryHeight))
        }
        guard !descriptors.isEmpty else { throw CaptureError.noDisplay }
        let cgAnchor = anchor ?? {
            let mouse = NSEvent.mouseLocation
            return CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        }()
        guard let descriptor = descriptors.first(where: { $0.1.contains(cgAnchor) }) else {
            throw CaptureError.noDisplay
        }

        // Screen pixels and window metadata cannot be sampled atomically by public APIs, but both
        // belong to this bounded trigger-time phase.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = WindowSnapper.currentCandidates()
            .filter {
                $0.ownerPID != ownPID
                    && $0.layer == 0
                    && $0.bounds.width >= WindowSnapper.minimumSize
                    && $0.bounds.height >= WindowSnapper.minimumSize
                    && $0.bounds.intersects(descriptor.1)
            }
            .map { FrozenDesktopSnapshot.Window(id: $0.windowID, frame: $0.bounds) }

        let image = try await captureWithRetry {
            do {
                let content = try await SCShareableContent.current
                try Task.checkCancellation()
                guard let display = content.displays.first(where: { $0.displayID == descriptor.0 }) else {
                    throw CaptureError.displayConfigurationChanged
                }
                let selectionWindowIDs = await MainActor.run {
                    Set(NSApplication.shared.windows.compactMap { window -> CGWindowID? in
                        guard window is SelectionPanel, window.windowNumber > 0 else { return nil }
                        return CGWindowID(window.windowNumber)
                    })
                }
                let filter = SCContentFilter(
                    display: display,
                    excludingWindows: content.windows.filter { selectionWindowIDs.contains($0.windowID) }
                )
                let configuration = SCStreamConfiguration()
                configuration.showsCursor = false
                configuration.captureResolution = .best
                let scale = resolutionScale == .native ? CGFloat(filter.pointPixelScale) : 1
                configuration.width = max(1, Int((descriptor.1.width * scale).rounded()))
                configuration.height = max(1, Int((descriptor.1.height * scale).rounded()))
                let box = FilterConfigurationBox(filter: filter, configuration: configuration)
                return try await SCScreenshotManager.captureImage(
                    contentFilter: box.filter,
                    configuration: box.configuration
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CaptureError {
                throw error
            } catch {
                throw CaptureError.sckFailure(error)
            }
        }
        try Task.checkCancellation()

        // Other displays may be attached or removed while this one is captured; only the selected
        // display's frame affects the frozen coordinate mapping.
        let currentFrames = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            screen.cgDirectDisplayID.map {
                ($0, Geometry.appKitToCG(screen.frame, primaryScreenHeight: primaryHeight))
            }
        })
        let (id, frame) = descriptor
        guard let current = currentFrames[id], framesMatch(current, frame) else {
            throw CaptureError.displayConfigurationChanged
        }

        return FrozenDesktopSnapshot(
            displays: [.init(id: id, cgFrame: frame, image: image)],
            windows: windows,
            resolutionScale: resolutionScale
        )
    }

    /// Captures an arbitrary screen-space rect, possibly spanning multiple displays.
    /// Uses `SCScreenshotManager.captureImage(in:)` -- NOT `SCContentFilter` + `sourceRect`,
    /// which is bound to a single display and returns an empty image for cross-display rects.
    /// Does not touch `ShareableContentCache` -- region capture needs no shareable content.
    static func captureRegion(cgRect: CGRect) async throws -> CGImage {
        try await captureWithRetry {
            do {
                return try await SCScreenshotManager.captureImage(in: cgRect)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CaptureError.sckFailure(error)
            }
        }
    }

    /// Captures a single window without bringing it forward, the way it looks on screen. A window
    /// captured on its own leaves out what shows through it: a translucent terminal or a sidebar
    /// with a blurred backdrop came out flat and lighter than on screen. So its colours come from
    /// the display with only the windows above it left out, and its shape (rounded corners,
    /// anti-aliased edges) from the window on its own. A window that is not wholly on one display
    /// is taken on its own, as before.
    static func captureWindow(
        _ window: SCWindow,
        resolutionScale: ResolutionScale = .native
    ) async throws -> CGImage {
        let alone = try await captureWindowAlone(window, resolutionScale: resolutionScale)
        guard let seen = try? await captureWindowAsSeen(window, width: alone.width, height: alone.height),
              let composed = WindowAppearance.composite(seen: seen.image, at: seen.placement, shape: alone) else {
            DiagnosticsLog.append("window shot as-seen=false")
            return alone
        }
        return composed
    }

    /// The part of the window on its display, with every window above it left out, and where it
    /// sits in the window's own `width` by `height` pixels (bottom-left origin). A window a point
    /// past the screen's edge, as a zoomed one is, keeps the part that is on it.
    private static func captureWindowAsSeen(_ window: SCWindow, width: Int, height: Int)
        async throws -> (image: CGImage, placement: CGRect)? {
        guard window.isOnScreen, window.frame.width > 0, window.frame.height > 0 else { return nil }
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(window.frame) }) else {
            return nil
        }
        let visible = window.frame.intersection(display.frame)
        guard visible.width >= 1, visible.height >= 1 else { return nil }
        let scale = CGFloat(width) / window.frame.width
        let placement = CGRect(x: ((visible.minX - window.frame.minX) * scale).rounded(),
                               y: ((window.frame.maxY - visible.maxY) * scale).rounded(),
                               width: (visible.width * scale).rounded(), height: (visible.height * scale).rounded())
        let above = Set(WindowAppearance.windowsAbove(window.windowID))
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.windows.filter { above.contains($0.windowID) || $0.owningApplication?.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.sourceRect = visible.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = Int(placement.width)
        configuration.height = Int(placement.height)
        let box = FilterConfigurationBox(filter: filter, configuration: configuration)
        let image = try await withHardTimeout(.seconds(2), onTimeout: CaptureError.timeout) {
            try await SCScreenshotManager.captureImage(contentFilter: box.filter, configuration: box.configuration)
        }
        return (image, placement)
    }

    /// The window on its own, with what shows through it left transparent.
    private static func captureWindowAlone(
        _ window: SCWindow,
        resolutionScale: ResolutionScale
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

        return try await captureWithRetry {
            do {
                return try await SCScreenshotManager.captureImage(contentFilter: box.filter, configuration: box.configuration)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CaptureError.sckFailure(error)
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

        return try await captureWithRetry {
            do {
                return try await SCScreenshotManager.captureImage(contentFilter: box.filter, configuration: box.configuration)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CaptureError.sckFailure(error)
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

        return try await captureWithRetry {
            do {
                return try await SCScreenshotManager.captureImage(contentFilter: box.filter, configuration: box.configuration)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CaptureError.sckFailure(error)
            }
        }
    }

    // MARK: - Timeout + retry

    static func withRetry<T: Sendable>(
        deadlineNanoseconds: UInt64,
        nowNanoseconds: @escaping @Sendable () -> UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard nowNanoseconds() < deadlineNanoseconds else { throw CaptureError.timeout }
            logger.error("Capture failed, retrying once: \(String(describing: error), privacy: .public)")
            return try await operation()
        }
    }

    /// One hard wall-clock bound wraps both attempts. A hung first attempt cannot receive a second
    /// independent timeout budget.
    private static func captureWithRetry<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = startedAt.addingReportingOverflow(fetchTimeoutNanoseconds)
        let attempt = Task {
            try await withRetry(
                deadlineNanoseconds: overflow ? UInt64.max : deadline,
                nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
                operation: operation
            )
        }
        return try await withTaskCancellationHandler {
            defer { attempt.cancel() }
            let result = try await withHardTimeout(fetchTimeout, onTimeout: CaptureError.timeout) {
                try await attempt.value
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            attempt.cancel()
        }
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.01
            && abs(lhs.minY - rhs.minY) < 0.01
            && abs(lhs.width - rhs.width) < 0.01
            && abs(lhs.height - rhs.height) < 0.01
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
