import SwiftUI

// Visual-neutral placeholders (RUN UI-1 D1): system look, one empty state each. Their real
// surfaces are built in UI-2 from the design direction the owner picks.

struct LibraryModule: CamcordModule {
    let id = ModuleID.library
    let title = LocalizedStringResource("Library", comment: "Main window module")
    let symbol = "photo.stack"
    let section = ModuleSection.capture
    let isAvailable = true

    func makeView() -> AnyView {
        AnyView(ModulePlaceholder(
            symbol: symbol,
            title: title,
            message: LocalizedStringResource("Your screenshots, scroll captures and recordings will appear here.",
                                             comment: "Library empty state")
        ))
    }
}

struct StudioModule: CamcordModule {
    let id = ModuleID.studio
    let title = LocalizedStringResource("Studio", comment: "Main window module")
    let symbol = "video.badge.waveform"
    let section = ModuleSection.capture
    let isAvailable = true

    func makeView() -> AnyView {
        AnyView(ModulePlaceholder(
            symbol: symbol,
            title: title,
            message: LocalizedStringResource("Set up one source, your camera and your audio before you record.",
                                             comment: "Studio empty state")
        ))
    }
}

struct EditModule: CamcordModule {
    let id = ModuleID.edit
    let title = LocalizedStringResource("Edit", comment: "Main window module")
    let symbol = "scissors"
    let section = ModuleSection.create
    let isAvailable = false

    func makeView() -> AnyView {
        AnyView(ModulePlaceholder(
            symbol: symbol,
            title: title,
            message: LocalizedStringResource("Trimming and editing are coming later.", comment: "Edit empty state")
        ))
    }
}

/// Settings inside the window: the existing Settings content, embedded. Its services come
/// from the environment (`AppServices`), so it renders the real thing wherever they are.
struct SettingsModule: CamcordModule {
    let id = ModuleID.settings
    let title = LocalizedStringResource("Settings", comment: "Main window module")
    let symbol = "gearshape"
    let section = ModuleSection.app
    let isAvailable = true

    func makeView() -> AnyView {
        AnyView(SettingsModuleView(symbol: symbol, title: title))
    }
}

private struct SettingsModuleView: View {
    let symbol: String
    let title: LocalizedStringResource
    @Environment(\.appServices) private var services

    var body: some View {
        if let services {
            SettingsRootView(eventTapEngine: services.eventTapEngine, defaultsSuite: services.defaults)
        } else {
            ModulePlaceholder(
                symbol: symbol,
                title: title,
                message: LocalizedStringResource("Settings are loading.", comment: "Settings placeholder")
            )
        }
    }
}

/// One empty state, in the system's own look.
struct ModulePlaceholder: View {
    let symbol: String
    let title: LocalizedStringResource
    let message: LocalizedStringResource

    var body: some View {
        ContentUnavailableView {
            Label { Text(title) } icon: { Image(systemName: symbol) }
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
