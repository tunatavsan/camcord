import AppKit
@preconcurrency import ScreenCaptureKit
import os

// `SCShareableContent` and the `SCWindow`/`SCDisplay` it vends are not Sendable-
// annotated in this SDK, but they are read-only snapshot objects (no mutating API
// surface) -- safe to hand across actor boundaries. This is the one place in the app
// that shuttles them across an isolation boundary (this actor -> @MainActor callers),
// so the retroactive conformance lives here rather than scattering `@unchecked` boxes
// at every call site.
extension SCShareableContent: @unchecked @retroactive Sendable {}
extension SCWindow: @unchecked @retroactive Sendable {}
extension SCDisplay: @unchecked @retroactive Sendable {}

/// Caches the last `SCShareableContent` query.
///
/// `SCShareableContent` queries are documented to cause multi-second stalls, so this
/// app never queries it per-capture. The cache is refreshed when it is older than
/// `maxAge` (5s) AND a fresh query is requested for window operations, or when
/// invalidated by a screen-parameters change or an app launch/terminate notification.
/// Region capture (`ScreenshotService.captureRegion`) does NOT go through this cache --
/// it doesn't need shareable content at all.
actor ShareableContentCache {
    private static let maxAge: TimeInterval = 5
    private static let fetchTimeout: Duration = .seconds(2)

    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "shareable-content-cache")

    private var cached: SCShareableContent?
    private var cachedAt: ContinuousClock.Instant?
    private var invalidated = true
    /// Coalesces concurrent fetches: the actor is reentrant across the fetch await,
    /// and each un-coalesced SCShareableContent query is a potential multi-second
    /// stall — overlapping callers should share one in-flight query.
    private var inFlightFetch: Task<SCShareableContent, Error>?

    /// Returns the cached content if it is fresh (and not invalidated), otherwise
    /// performs a new timeout+retry-guarded fetch and caches the result.
    func content(forceRefresh: Bool = false) async throws -> SCShareableContent {
        if !forceRefresh, !invalidated, let cached, let cachedAt,
            ContinuousClock.now - cachedAt < .seconds(Self.maxAge)
        {
            return cached
        }
        if let inFlightFetch {
            return try await inFlightFetch.value
        }
        let fetch = Task { [logger] in
            try await Self.fetchWithRetry(logger: logger)
        }
        inFlightFetch = fetch
        defer { inFlightFetch = nil }
        let fresh = try await fetch.value
        cached = fresh
        cachedAt = ContinuousClock.now
        invalidated = false
        return fresh
    }

    /// Returns the last cached snapshot without fetching, even if it is stale or
    /// nil. Used for continuous UI updates (e.g. mouseMoved window-snap highlighting)
    /// that must never block on a fresh `SCShareableContent` query.
    func lastKnownContent() -> SCShareableContent? {
        cached
    }

    /// Kicks off a background refresh without blocking the caller; used when the
    /// overlay opens so `lastKnownContent()` has something reasonably fresh to show.
    func refreshInBackground() {
        Task {
            do {
                _ = try await content(forceRefresh: true)
            } catch {
                logger.error("Background shareable-content refresh failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func invalidate() {
        invalidated = true
    }

    private static func fetchWithRetry(logger: Logger) async throws -> SCShareableContent {
        do {
            return try await fetchWithTimeout()
        } catch {
            logger.error("Shareable-content fetch failed, retrying once: \(String(describing: error), privacy: .public)")
            return try await fetchWithTimeout()
        }
    }

    /// Hard wall-clock bound: a hung SCK query is abandoned, not awaited (see
    /// `withHardTimeout` — task-group cancellation can't bound non-cooperative calls).
    private static func fetchWithTimeout() async throws -> SCShareableContent {
        try await withHardTimeout(fetchTimeout, onTimeout: CaptureError.timeout) {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }
}

/// Observes the notifications that should invalidate the shareable-content cache:
/// display configuration changes and app launch/terminate (which changes the window list).
@MainActor
final class ShareableContentCacheInvalidator {
    private let cache: ShareableContentCache
    // Block-based observer tokens must be removed from the SAME center that created
    // them, so the two centers' tokens are tracked separately. Only ever mutated in
    // `init` and read in `deinit`, which never run concurrently for a given
    // instance -- safe to hand to the nonisolated deinit.
    private nonisolated(unsafe) var defaultCenterObservers: [NSObjectProtocol] = []
    private nonisolated(unsafe) var workspaceCenterObservers: [NSObjectProtocol] = []

    init(cache: ShareableContentCache) {
        self.cache = cache
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let invalidate: @Sendable (Notification) -> Void = { [cache] _ in
            Task { await cache.invalidate() }
        }

        defaultCenterObservers.append(
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: invalidate)
        )
        workspaceCenterObservers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: invalidate)
        )
        workspaceCenterObservers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: invalidate)
        )
        // A Space switch changes the on-screen window list too.
        workspaceCenterObservers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: invalidate)
        )
    }

    deinit {
        for observer in defaultCenterObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in workspaceCenterObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
