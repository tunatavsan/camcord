import ServiceManagement
import os

/// Single owner of the launch-at-login logic so the menu toggle and the Settings
/// toggle can't drift apart. Deliberately nonisolated: `SMAppService` class methods
/// are thread-safe to query, and `SettingsView.init` (nonisolated) reads `isEnabled`.
enum LoginItem {
    private static let logger = Logger(subsystem: "dev.tavsan.camcord", category: "login-item")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        if enabled {
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                return
            }
            do {
                try service.register()
            } catch {
                logger.error("Failed to register login item: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            do {
                try service.unregister()
            } catch {
                logger.error("Failed to unregister login item: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
