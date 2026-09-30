import SwiftUI

/// Typed callbacks keep the main window's environment injection small and retain the real shared owners.
@MainActor enum StudioRuntimeCallbacks {
    static func regionAction(_ services: AppServices?) -> (@MainActor () async -> Void)? {
        guard let services else { return nil }
        return { await services.studioPicker.select() }
    }
    static func clipboardClaim(_ services: AppServices?) -> StudioFileActions.Claim? {
        guard let services else { return nil }
        return { services.coordinator.claimClipboardPublication() }
    }
}
