import SwiftUI

/// Typed callbacks keep the main window's environment injection small and retain the real shared owners.
@MainActor final class StudioRuntimeCallbacks {
    let selectRegion: (@MainActor () async -> Void)?
    let claimClipboard: StudioFileActions.Claim?

    init(services: AppServices?) {
        selectRegion = Self.regionAction(services)
        claimClipboard = Self.clipboardClaim(services)
    }

    static func regionAction(_ services: AppServices?) -> (@MainActor () async -> Void)? {
        guard let services else { return nil }
        return { await services.studioPicker.select() }
    }
    static func clipboardClaim(_ services: AppServices?) -> StudioFileActions.Claim? {
        guard let services else { return nil }
        return { services.coordinator.claimClipboardPublication() }
    }
}
