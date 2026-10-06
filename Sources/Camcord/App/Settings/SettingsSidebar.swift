import SwiftUI

/// While Settings is open the sidebar itself lists its groups, so there is never a menu inside
/// a menu. "← Camcord" goes back to the module the window came from; Esc and ⌘[ do the same.
struct SettingsSidebar: View {
    @Bindable var model: MainWindowModel

    var body: some View {
        InkNavigationList(selection: $model.settingsGroup, order: SettingsGroup.allCases) { focus in
            Button {
                model.leaveSettings()
            } label: {
                Label { Text(verbatim: "Camcord") } icon: {
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
                    SidebarRow(title: group.title, symbol: group.symbol)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { SidebarBrandHeader().accessibilityHidden(true) }
        .onExitCommand { model.leaveSettings() }
        .accessibilityLabel(Text("Settings groups", comment: "Accessibility: the Settings sidebar"))
    }
}
