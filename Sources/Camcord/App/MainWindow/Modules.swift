import AppKit
import SwiftUI

// The main window's modules: Library, Studio, Edit and Settings.

/// A module that carries a small tag beside its sidebar row ("Later"). Additive: the module
/// types themselves are unchanged.
@MainActor protocol ModuleBadging {
    var badge: LocalizedStringResource? { get }
}

struct LibraryModule: CamcordModule {
    let id = ModuleID.library
    let title = LocalizedStringResource("Library", comment: "Main window module")
    let symbol = "rectangle.stack"
    let section = ModuleSection.capture
    let isAvailable = true

    func makeView() -> AnyView {
        AnyView(LibraryModuleView())
    }
}

/// Library's centered capture entry point and configured shortcuts.
struct LibraryEmptyView: View {
    var body: some View { LibraryEmptyContent() }
}

struct StudioModule: CamcordModule {
    let id = ModuleID.studio
    let title = LocalizedStringResource("Studio", comment: "Main window module")
    let symbol = "video"
    let section = ModuleSection.capture
    let isAvailable = true

    func makeView() -> AnyView {
        AnyView(StudioView())
    }
}

/// Screenshot editing uses the shared session supplied by the main window.
struct EditModule: CamcordModule {
    let id = ModuleID.edit
    let title = LocalizedStringResource("Edit", comment: "Main window module")
    let symbol = "scissors"
    let section = ModuleSection.create
    let isAvailable = true
    func makeView() -> AnyView { AnyView(ScreenshotEditorView()) }
}

/// Settings inside the window: its groups take over the sidebar, its pages are cards of rows
/// (App/Settings/).
struct SettingsModule: CamcordModule {
    let id = ModuleID.settings
    let title = LocalizedStringResource("Settings", comment: "Main window module")
    let symbol = "gearshape"
    let section = ModuleSection.app
    let isAvailable = true

    func makeView() -> AnyView {
        AnyView(SettingsModuleView())
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
