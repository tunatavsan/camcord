import AppKit
import SwiftUI

// The main window's modules: Library, Studio and Edit.

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
