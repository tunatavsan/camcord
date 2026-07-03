import AppKit
import CoreGraphics
import os

/// Failure-path helper for the Screen Recording permission. macOS 15+ periodically
/// re-asks for programmatic capture approval (in practice only after ~a month of
/// non-use), and a revoked/expired grant surfaces as capture errors -- not as a
/// prompt. When a capture fails AND preflight says we lost the permission, this
/// opens the privacy pane (rate-limited) instead of letting the user wonder why
/// every shot silently beeps.
@MainActor
enum PermissionRecovery {
    private static let logger = Logger(subsystem: "dev.tavsan.camcord", category: "permission-recovery")
    /// A permanent once-per-run latch would go silent for the rest of a
    /// weeks-long agent session if the user dismissed System Settings without
    /// fixing the grant -- a cooldown keeps re-offering the fix without spamming.
    private static var lastOpenedPane: ContinuousClock.Instant?
    private static let reopenCooldown: Duration = .seconds(120)

    static let screenRecordingPaneURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    /// Call from capture failure paths. No-op while the permission is intact.
    static func noteCaptureFailure() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        logger.error("Capture failed and Screen Recording preflight is false — permission lost/expired")
        let now = ContinuousClock.now
        if let lastOpenedPane, now - lastOpenedPane < reopenCooldown { return }
        lastOpenedPane = now
        // Re-trigger the system prompt if possible, and take the user to the pane.
        _ = CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(screenRecordingPaneURL)
    }
}
