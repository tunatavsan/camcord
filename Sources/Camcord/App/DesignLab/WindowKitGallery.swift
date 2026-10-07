import SwiftUI

/// Every window kit component in every state, side by side on the window's tray: rest,
/// hovered, a sibling hovered, pressed, chosen, disabled. The top row is live, to try with the
/// pointer; the rows below draw each state from `KitState`.
struct WindowKitGallery: View {
    static let size = CGSize(width: 1480, height: 1220)

    private static let states: [(String, KitState)] = [
        ("rest", KitState()),
        ("hover", KitState(focus: true)),
        ("sibling", KitState(focus: false)),
        ("pressed", KitState(focus: true, pressed: true)),
        ("selected", KitState(selected: true)),
        ("focused", KitState(focused: true)),
        ("disabled", KitState(enabled: false)),
    ]

    @State private var module = "library"
    @State private var filter = "all"
    @State private var tab = 0
    @Namespace private var navMark
    @Namespace private var chipMark

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Window.Layout.gap) {
            sidebar
                .frame(width: Theme.Window.Layout.sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .kitCell()
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                live
                ForEach(Self.states, id: \.0) { name, state in stateRow(name, state) }
                Spacer(minLength: 0)
            }
            .padding(Theme.Window.Layout.cellPadding + Theme.Space.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .kitCell()
        }
        .padding(Theme.Window.Layout.ring)
        .frame(width: Self.size.width, height: Self.size.height)
        .foregroundStyle(Theme.Palette.ink.color)
        .tint(Theme.Palette.ink.color)
        .kitTray()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Theme.Window.Layout.rowSpacing) {
            KitSectionHeader(title: Text(verbatim: "Live"))
                .padding(.horizontal, Theme.Window.Layout.rowInset)
                .padding(.bottom, Theme.Space.xs)
            ForEach([("library", "rectangle.stack", "⌘1"), ("studio", "video", "⌘2"), ("edit", "scissors", "⌘3")],
                    id: \.0) { id, symbol, key in
                KitNavRow(symbol: symbol, title: Text(verbatim: id.capitalized), key: key, selected: module == id,
                          mark: navMark) {
                    withAnimation(Theme.Window.Motion.select) { module = id }
                }
            }
            KitSectionHeader(title: Text(verbatim: "States"))
                .padding(.horizontal, Theme.Window.Layout.rowInset)
                .padding(.top, Theme.Space.l)
                .padding(.bottom, Theme.Space.xs)
            ForEach(Self.states, id: \.0) { name, state in
                KitNavRow(symbol: "rectangle.stack", title: Text(verbatim: name), key: "⌘1", selected: state.selected,
                          preview: state) {}
            }
        }
        .kitHoverGroup()
        .padding(Theme.Window.Layout.ring)
        .padding(.top, Theme.Window.Layout.titlebarHeight - Theme.Window.Layout.ring)
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            KitSectionHeader(title: Text(verbatim: "Live")) {
                KitLinkButton(title: Text(verbatim: "All")) {}
            }
            KitTabStrip(tabs: [
                .init(id: 0, symbol: "gearshape", title: Text(verbatim: "General")),
                .init(id: 1, symbol: "camera.viewfinder", title: Text(verbatim: "Screenshot")),
                .init(id: 2, symbol: "record.circle", title: Text(verbatim: "Recording")),
                .init(id: 3, symbol: "video", title: Text(verbatim: "Camera")),
                .init(id: 4, symbol: "keyboard", title: Text(verbatim: "Shortcuts")),
            ], selection: $tab)
            .frame(width: 520)
            HStack(spacing: Theme.Space.l) {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(["all", "screenshots", "recordings"], id: \.self) { id in
                        KitChip(symbol: nil, title: Text(verbatim: id.capitalized),
                                count: ["all": 376, "screenshots": 337, "recordings": 39][id],
                                selected: filter == id, mark: chipMark) {
                            withAnimation(Theme.Window.Motion.select) { filter = id }
                        }
                    }
                }
                .kitHoverGroup()
                HStack(spacing: 0) {
                    KitIconButton(symbol: "square.grid.2x2", title: Text(verbatim: "Grid"), selected: true) {}
                    KitIconButton(symbol: "list.bullet", title: Text(verbatim: "List")) {}
                    KitIconButton(symbol: "sidebar.right", title: Text(verbatim: "Inspector")) {}
                }
                .kitHoverGroup()
                KitCapsuleButton(title: Text(verbatim: "Record"), symbol: "record.circle", role: .primary, shortcut: "⌃⇧R") {}
                KitCapsuleButton(title: Text(verbatim: "Export"), symbol: "square.and.arrow.up") {}
            }
        }
    }

    private func stateRow(_ name: String, _ state: KitState) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            Text(verbatim: name).font(Theme.Window.Font.data).foregroundStyle(Theme.Palette.ink3.color)
                .frame(width: 64, alignment: .leading)
            KitToolButton(symbol: "rectangle.dashed", title: Text(verbatim: "Region"), detail: "⇧⌘4",
                          selected: state.selected, preview: state) {}
            KitIconButton(symbol: "sidebar.right", title: Text(verbatim: name), selected: state.selected, preview: state) {}
            KitChip(symbol: "photo", title: Text(verbatim: "Screens"), count: 12, selected: state.selected, preview: state) {}
            KitCapsuleButton(title: Text(verbatim: "Record"), symbol: "record.circle", role: .primary, shortcut: "⌃⇧R",
                             preview: state) {}
            KitCapsuleButton(title: Text(verbatim: "Export"), symbol: "square.and.arrow.up", preview: state) {}
            KitLinkButton(title: Text(verbatim: "All"), preview: state) {}
            KitCard(title: Text(verbatim: "Screenshot Oct 7, 2026 at 17.30.12"), detail: Text(verbatim: "1920×1080"),
                    selected: state.selected, preview: state) {
                Image(systemName: "photo").foregroundStyle(Theme.Palette.ink3.color)
            }
            .frame(width: 170)
            KitListRow(title: Text(verbatim: "Recording Oct 7, 2026 at 12.04.55"), detail: Text(verbatim: "01:24 · 2.4 MB"),
                       selected: state.selected, preview: state) {
                Image(systemName: "video").foregroundStyle(Theme.Palette.ink2.color)
            } trailing: {
                Text(verbatim: "12:04").font(Theme.Window.Font.data).foregroundStyle(Theme.Palette.ink3.color)
            }
            .frame(width: 280)
        }
        .frame(height: 126)
    }
}
