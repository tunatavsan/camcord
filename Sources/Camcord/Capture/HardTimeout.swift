import Foundation
import os

private struct HardTimeoutState {
    var alreadyResumed = false
    var timeoutTask: Task<Void, Never>? = nil
}

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
    let stateLock = OSAllocatedUnfairLock(initialState: HardTimeoutState())

    return try await withCheckedThrowingContinuation { continuation in
        let finish: @Sendable (Result<T, Error>) -> Void = { result in
            let (isFirst, taskToCancel): (Bool, Task<Void, Never>?) = stateLock.withLock { state in
                if state.alreadyResumed { return (false, nil) }
                state.alreadyResumed = true
                let task = state.timeoutTask
                state.timeoutTask = nil
                return (true, task)
            }
            if isFirst {
                continuation.resume(with: result)
                taskToCancel?.cancel()
            }
        }
        Task.detached {
            do {
                finish(.success(try await operation()))
            } catch {
                finish(.failure(error))
            }
        }
        let task = Task.detached {
            do {
                try await Task.sleep(for: timeout)
                finish(.failure(timeoutError()))
            } catch {
                // Task was cancelled, do nothing
            }
        }
        stateLock.withLock { state in
            if state.alreadyResumed {
                task.cancel()
            } else {
                state.timeoutTask = task
            }
        }
    }
}
