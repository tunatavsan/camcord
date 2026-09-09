import Foundation
import os

/// Best-effort Focus / Do-Not-Disturb toggling around a recording so message and mail
/// banners don't leak into the capture.
///
/// macOS 15 exposes NO public API to change Focus, so this shells out to the `shortcuts`
/// CLI to run a user-made Shortcut (e.g. a "Set Focus → Do Not Disturb On/Off" shortcut
/// the user creates once and names in Settings). Entirely opt-in and fail-silent: an
/// empty/whitespace name is a no-op, and a launch failure is logged but never surfaced —
/// a leaked notification is a minor annoyance, not a reason to interrupt the recording.
enum DoNotDisturb {
    private static let logger = Logger(subsystem: "dev.tavsan.camcord", category: "dnd")
    private static let shortcutsCLI = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// Runs the named Shortcut, fire-and-forget (does not wait for it to finish). Safe to
    /// call with an empty name (no-op).
    static func run(shortcutNamed name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard FileManager.default.isExecutableFile(atPath: shortcutsCLI.path) else {
            logger.error("shortcuts CLI not available at \(shortcutsCLI.path, privacy: .public)")
            return
        }
        let process = Process()
        process.executableURL = shortcutsCLI
        process.arguments = ["run", trimmed]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            let log = logger
            let shortcutName = trimmed
            process.terminationHandler = { p in
                let status = p.terminationStatus
                if status != 0 {
                    log.error("shortcuts run \"\(shortcutName, privacy: .public)\" exited with non-zero status: \(status)")
                }
            }
            try process.run()
        } catch {
            logger.error("shortcuts run \"\(trimmed, privacy: .public)\" failed to launch: \(String(describing: error), privacy: .public)")
        }
    }
}
