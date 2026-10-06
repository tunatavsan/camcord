import Foundation

/// Persistent diagnostics sink: the installed app's `os_log` lines are not retrievable with
/// `log show`, so the trigger and scroll session logs also write to
/// `~/Library/Logs/Camcord/diagnostics.log`, opened once per process and started empty when
/// the previous run left it over `maxBytes`. `stamp`/`handle`/`opened` are queue-confined.
enum DiagnosticsLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Camcord/diagnostics.log")
    private static let maxBytes: UInt64 = 512 * 1024
    private static let queue = DispatchQueue(label: "dev.tavsan.camcord.diagnostics", qos: .utility)
    private nonisolated(unsafe) static let stamp = ISO8601DateFormatter()
    private nonisolated(unsafe) static var handle: FileHandle?
    private nonisolated(unsafe) static var opened = false
    private nonisolated(unsafe) static var written: UInt64 = 0

    /// Appends `line` prefixed with an ISO8601 timestamp. Never throws, never blocks the caller.
    static func append(_ line: String) {
        let now = Date()
        queue.async {
            guard let handle = open() else { return }
            let data = Data("\(stamp.string(from: now)) \(line)\n".utf8)
            // The bound holds DURING the run too: this app sits in the menu bar for weeks,
            // so a launch-only check would let the file grow without limit.
            if written + UInt64(data.count) > maxBytes {
                try? handle.truncate(atOffset: 0)
                try? handle.seek(toOffset: 0)
                written = 0
            }
            try? handle.write(contentsOf: data)
            written += UInt64(data.count)
        }
    }

    /// Performance diagnostics accepts only fixed outcomes, numeric timing and static stack
    /// symbols. The ordinary sink already rotates at 512 KiB, including during a long run.
    static func appendPerformanceStall(generation: UInt64, elapsedNanoseconds: UInt64, outcome: String) {
        append("performance runloop-stall generation=\(generation) elapsed_ms=\(Double(elapsedNanoseconds) / 1_000_000) outcome=\(outcome)")
    }

    /// Serial-queue only. Opens once per process; a file over the bound starts empty.
    private static func open() -> FileHandle? {
        if opened { return handle }
        opened = true
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? UInt64 ?? 0
        if size > maxBytes || !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        written = (try? handle?.seekToEnd()) ?? 0
        return handle
    }
}
