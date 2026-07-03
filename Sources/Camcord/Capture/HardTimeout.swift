import Foundation
import os

/// Races `operation` against a wall-clock deadline and returns whichever finishes
/// first — WITHOUT waiting for the loser.
///
/// A naive task-group timeout does not actually bound latency here: when the sleep
/// child wins, the group still cancels *and awaits* the operation child before the
/// error propagates, and the ScreenCaptureKit calls this app guards (SCShareableContent
/// queries, SCScreenshotManager captures) are continuation-bridged and do not observe
/// cancellation — a hung `replayd` would hang the "timeout" forever. This helper
/// resumes the caller at the deadline and deliberately abandons the orphaned call
/// (it completes on its own in the background and its result is discarded).
func withHardTimeout<T: Sendable>(
    _ timeout: Duration,
    onTimeout timeoutError: @autoclosure @escaping @Sendable () -> Error,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let resumed = OSAllocatedUnfairLock(initialState: false)
    return try await withCheckedThrowingContinuation { continuation in
        let finish: @Sendable (Result<T, Error>) -> Void = { result in
            let isFirst = resumed.withLock { alreadyResumed in
                if alreadyResumed { return false }
                alreadyResumed = true
                return true
            }
            if isFirst {
                continuation.resume(with: result)
            }
        }
        Task.detached {
            do {
                finish(.success(try await operation()))
            } catch {
                finish(.failure(error))
            }
        }
        Task.detached {
            try? await Task.sleep(for: timeout)
            finish(.failure(timeoutError()))
        }
    }
}
