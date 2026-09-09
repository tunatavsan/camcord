import Foundation
import Darwin

/// Process-lifetime ownership of the capture hotkeys. An advisory lock is released by
/// the kernel on exit, including crashes; a stale file can never prevent relaunching.
final class AppInstanceLock {
    enum LockError: Error { case alreadyRunning, unavailable(Int32) }
    private let descriptor: Int32

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LockError.unavailable(errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            Darwin.close(descriptor)
            if error == EWOULDBLOCK { throw LockError.alreadyRunning }
            throw LockError.unavailable(error)
        }
        self.descriptor = descriptor
    }

    deinit { Darwin.close(descriptor) }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Camcord", isDirectory: true)
            .appendingPathComponent("instance.lock")
    }
}
