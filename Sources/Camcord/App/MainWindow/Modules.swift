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

/// Settings inside the window: the existing Settings content, embedded. `content` is set at
/// launch, when the event-tap engine it needs exists; until then a placeholder shows.
struct SettingsModule: CamcordModule {
    @MainActor static var content: (() -> AnyView)?

    let id = ModuleID.settings
    let title = LocalizedStringResource("Settings", comment: "Main window module")
    let symbol = "gearshape"
    let section = ModuleSection.app
    let isAvailable = true

    func makeView() -> AnyView {
        Self.content?() ?? AnyView(ModulePlaceholder(
            symbol: symbol,
            title: title,
            message: LocalizedStringResource("Settings are loading.", comment: "Settings placeholder")
        ))
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
