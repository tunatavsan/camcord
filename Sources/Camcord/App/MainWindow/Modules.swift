import AppKit
import SwiftUI

// The main window's modules. The Library and the Studio get their real pages in P3 and P4;
// until then the Library shows its empty state (K1) and the Studio says what it will hold.

/// A module that carries a small tag beside its sidebar row ("Later"). Additive to the K9 seam:
/// the module types themselves are unchanged.
@MainActor protocol ModuleBadging {
    var badge: LocalizedStringResource? { get }
}

struct LibraryModule: CamcordModule {
    let id = ModuleID.library
    let title = LocalizedStringResource("Library", comment: "Main window module")
    let symbol = "photo.stack"
    let section = ModuleSection.capture
    let isAvailable = true

    func makeView() -> AnyView {
        AnyView(LibraryModuleView())
    }
}

/// The empty Library (K1): the mark, "No captures yet", the five hotkeys as key caps, and two
/// ways to start. No question, no composer.
struct LibraryEmptyView: View {
    @Environment(\.appServices) private var services

    var body: some View {
        EmptyState(title: LocalizedStringResource("No captures yet", comment: "Empty Library title")) {
            VStack(spacing: Theme.Space.xl) {
                HStack(spacing: Theme.Space.s) {
                    ForEach(CaptureKind.allCases) { kind in
                        HotkeyTile(kind: kind)
                    }
                }
                HStack(spacing: Theme.Space.s) {
                    Button {
                        services?.capture(.region)
                    } label: {
                        Label { Text(CaptureKind.region.actionTitle) } icon: { Image(systemName: CaptureKind.region.symbol) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.ink.color)
                    Button {
                        services?.toggleRecording()
                    } label: {
                        Label { Text("Record", comment: "Button: start a recording") } icon: {
                            Image(systemName: "record.circle").foregroundStyle(Theme.Palette.record.color)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One capture's key cap in the empty Library: its symbol, its name, its hotkey.
private struct HotkeyTile: View {
    let kind: CaptureKind

    var body: some View {
        VStack(spacing: Theme.Space.s - 2) {
            Image(systemName: kind.symbol)
                .font(Theme.Font.title.weight(.regular))
                .foregroundStyle(Theme.Palette.ink.color)
                .accessibilityHidden(true)
            Text(kind.title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.ink2.color)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            KeyCap(shortcut: kind.shortcut)
        }
        .frame(width: 96)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.Palette.surface.color, in: RoundedRectangle(cornerRadius: Theme.Radius.box, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.box, style: .continuous).strokeBorder(Theme.Palette.hairline.color))
        .accessibilityElement(children: .combine)
    }
}

struct StudioModule: CamcordModule {
    let id = ModuleID.studio
    let title = LocalizedStringResource("Studio", comment: "Main window module")
    let symbol = "video.badge.waveform"
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

/// Settings inside the window (K7): its groups take over the sidebar, its pages are the
/// prototype's cards (App/Settings/).
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
