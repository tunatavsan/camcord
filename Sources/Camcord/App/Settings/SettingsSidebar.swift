import SwiftUI

/// While Settings is open the sidebar itself lists its groups (the owner's reference: Codex),
/// so there is never a menu inside a menu (SPEC N3). "← Camcord" goes back to the module the
/// window came from; Esc and ⌘[ do the same.
struct SettingsSidebar: View {
    @Bindable var model: MainWindowModel

    var body: some View {
        InkNavigationList(selection: $model.settingsGroup, order: SettingsGroup.allCases) { focus in
            Button {
                model.leaveSettings()
            } label: {
                Label { Text("Camcord", comment: "Sidebar: back from Settings to the app") } icon: {
                    Image(systemName: "chevron.left")
                }
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.ink2.color)
                .padding(.horizontal, Theme.Space.s + 2)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .accessibilityLabel(Text("Back to Camcord", comment: "Accessibility: leave Settings"))
            InkNavigationHeader(title: LocalizedStringResource("Settings", comment: "Main window module"))
            ForEach(SettingsGroup.allCases) { group in
                InkNavigationRow(id: group, selection: $model.settingsGroup, focus: focus) {
                    Label { Text(group.title) } icon: { Image(systemName: group.symbol) }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { SettingsSidebarHeader() }
        .onExitCommand { model.leaveSettings() }
        .accessibilityLabel(Text("Settings groups", comment: "Accessibility: the Settings sidebar"))
    }
}

/// The same header as the app sidebar, so the switch reads as one sidebar changing its list.
private struct SettingsSidebarHeader: View {
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ViewfinderMarkView(dot: .plain).frame(width: 18, height: 18)
            Text(verbatim: "Camcord").font(Theme.Font.rowStrong)
        }
        .foregroundStyle(Theme.Palette.ink.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.s)
        .accessibilityHidden(true)
    }
}
