import Observation

/// Stable observable capture activity. Updated synchronously by CaptureCoordinator;
/// consumers never take over its callbacks or poll a private lock.
@MainActor @Observable
final class CaptureTransitionState {
    private(set) var isActive = false
    func update(exclusiveCapture: Bool, pendingHoldSnapshots: Int) {
        isActive = exclusiveCapture || pendingHoldSnapshots > 0
    }
}
