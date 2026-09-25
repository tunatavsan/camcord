import SwiftUI

// KARAR-1: Camcord's navigation lists (the main window's sidebar, the Settings group list) draw
// their own selection, the ink capsule, so the user's system accent never colours them (K1).
// Everything else keeps the system's selection. Keyboard and VoiceOver parity is part of the
// component: ↑/↓ move the selection while the list has focus, each row is a button that
// carries the selected trait.

/// Pure keyboard movement through a navigation list: one step up or down among the enabled
/// ids, stopping at the ends (as Finder's sidebar does).
enum InkNavigation {
    static func move<ID: Equatable>(from current: ID, by step: Int, in order: [ID]) -> ID {
        guard let index = order.firstIndex(of: current) else { return order.first ?? current }
        let next = min(max(index + step, 0), order.count - 1)
        return order.isEmpty ? current : order[next]
    }
}

/// The list: a scroll view of `InkNavigationRow`s and headers that takes keyboard focus.
struct InkNavigationList<ID: Hashable, Content: View>: View {
    @Binding var selection: ID
    /// The selectable ids in on-screen order, for the arrow keys.
    let order: [ID]
    @ViewBuilder var content: (FocusState<Bool>.Binding) -> Content
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                content($focused)
            }
            .padding(.horizontal, Theme.Space.s + 2)
            .padding(.vertical, Theme.Space.xs)
        }
        .scrollIndicators(.never)
        .focusable()
        .focused($focused)
        // No accent focus ring (K1): focus shows as a stronger selection capsule, the way the
        // system's own sidebar turns its highlight on and off with focus.
        .focusEffectDisabled()
        .environment(\.inkNavigationFocused, focused)
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        selection = InkNavigation.move(from: selection, by: delta, in: order)
        return .handled
    }
}

extension EnvironmentValues {
    /// Whether the enclosing ink navigation list has keyboard focus.
    @Entry var inkNavigationFocused = false
}

/// A section title inside an ink navigation list.
struct InkNavigationHeader: View {
    let title: LocalizedStringResource

    var body: some View {
        // ink2, not ink3: on the frosted sidebar ink3 measures 3.6:1 (NOTE-2 asks 4.5).
        Text(title)
            .font(Theme.Font.captionStrong)
            .foregroundStyle(Theme.Palette.ink2.color)
            .padding(.horizontal, Theme.Space.s + 2)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One row: a plain button whose selected state is the ink capsule.
struct InkNavigationRow<ID: Hashable, Label: View>: View {
    let id: ID
    @Binding var selection: ID
    var focus: FocusState<Bool>.Binding?
    @ViewBuilder var label: Label

    @State private var hovering = false
    @Environment(\.controlActiveState) private var activeState

    private var isSelected: Bool { selection == id }

    var body: some View {
        Button {
            selection = id
            focus?.wrappedValue = true
        } label: {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.s + 2)
                .frame(minHeight: 30)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        // Every title in ink, as in the owner's reference; the capsule marks the selection.
        .foregroundStyle(Theme.Palette.ink.color)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(fill)
        }
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var fill: Color {
        if isSelected {
            // The lighter capsule while the window is key; quieter in an inactive window, like
            // the system sidebar's own inactive highlight.
            return activeState == .inactive ? Theme.Palette.selection.color : Theme.Palette.selectionStrong.color
        }
        return hovering ? Theme.Palette.hover.color : .clear
    }
}
