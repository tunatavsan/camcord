import SwiftUI

// The panel's controls, for the window. Each takes an optional `preview` state: the gallery
// and the render tests draw every state with it; a live control derives its state from the
// pointer, its hover group and the environment.

/// An icon-only button: the panel's destination icons. Hovered it rises and glows; the other
/// members of its group step back. Chosen (a toggle that is on) it sits on the selection fill.
struct KitIconButton: View {
    let symbol: String
    let title: Text
    var selected = false
    var preview: KitState?
    let action: () -> Void
    @State private var hover = KitHover()
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = preview ?? KitState(focus: hover.focus, selected: selected, enabled: enabled)
        let lift = KitLift.resolve(state, kind: .symbol, reduceMotion: reduceMotion)
        Button(action: action) {
            InkSymbol(name: symbol, pointSize: Theme.Window.Layout.symbolPoint, weight: state.selected ? .semibold : .medium,
                      canvas: Theme.Window.Layout.symbolCanvas)
                .foregroundStyle(state.selected ? Theme.Palette.ink.color : Theme.Palette.ink2.color)
                .kitLift(lift)
                .frame(width: Theme.Window.Layout.iconButton, height: Theme.Window.Layout.iconButton)
                .background(KitControlBackground(radius: Theme.Window.Layout.iconRadius, selected: state.selected))
                .opacity(lift.opacity)
                .contentShape(.rect)
                .kitPressed(state.pressed)
                .kitPreview(preview)
        }
        .buttonStyle(KitPressStyle())
        .onHover { hover.update(inside: $0) }
        .animation(reduceMotion ? nil : Theme.Window.Motion.lift, value: state)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(state.selected ? .isSelected : [])
    }
}

/// A symbol over its name: the panel's capture tools. Hovered, the symbol rises and its detail
/// (a shortcut) takes the name's place, as in the panel; the name stays in the tooltip.
struct KitToolButton: View {
    let symbol: String
    let title: Text
    var detail: String?
    var selected = false
    var mark: Namespace.ID?
    var preview: KitState?
    let action: () -> Void
    @State private var hover = KitHover()
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = preview ?? KitState(focus: hover.focus, selected: selected, enabled: enabled)
        let lift = KitLift.resolve(state, kind: .tool, reduceMotion: reduceMotion)
        let showsDetail = state.lifted && detail != nil
        Button(action: action) {
            VStack(spacing: Theme.Space.xs) {
                InkSymbol(name: symbol, pointSize: Theme.Window.Layout.toolSymbolPoint,
                          canvas: Theme.Window.Layout.toolSymbolCanvas)
                    .kitLift(lift, glowRadius: Theme.Window.Lift.toolGlowRadius)
                ZStack {
                    title.font(Theme.Window.Font.captionStrong).lineLimit(1).fixedSize()
                        .opacity(showsDetail ? 0 : 1)
                    if let detail {
                        Text(verbatim: detail).font(Theme.Window.Font.data).lineLimit(1).fixedSize()
                            .foregroundStyle(Theme.Palette.ink2.color)
                            .opacity(showsDetail ? 1 : 0)
                            .offset(y: showsDetail || reduceMotion ? 0 : Theme.Window.Lift.detailRise)
                    }
                }
                KitMark(visible: state.selected, mark: mark)
            }
            .foregroundStyle(state.selected || mark == nil ? Theme.Palette.ink.color : Theme.Palette.ink3.color)
            .padding(.horizontal, Theme.Space.s)
            .frame(height: Theme.Window.Layout.toolHeight)
            .background(KitControlBackground(radius: Theme.Radius.control))
            .opacity(lift.opacity)
            .contentShape(.rect)
            .kitPressed(state.pressed)
            .kitPreview(preview)
        }
        .buttonStyle(KitPressStyle())
        .onHover { hover.update(inside: $0) }
        .animation(reduceMotion ? nil : Theme.Window.Motion.liftTool, value: state)
        .help(Text(verbatim: detail ?? ""))
        .accessibilityLabel(title)
        .accessibilityHint(Text(verbatim: detail ?? ""))
        .accessibilityAddTraits(state.selected ? .isSelected : [])
    }
}

/// The short ink bar under the chosen item; it slides between choices when they share a namespace.
struct KitMark: View {
    let visible: Bool
    let mark: Namespace.ID?

    var body: some View {
        ZStack {
            if visible {
                let bar = Capsule().fill(Theme.Palette.ink.color)
                    .frame(width: Theme.Window.Layout.chipMarkWidth, height: Theme.Window.Layout.chipMarkHeight)
                if let mark { bar.matchedGeometryEffect(id: "kit.mark", in: mark) } else { bar }
            }
        }
        .frame(height: mark == nil ? 0 : Theme.Window.Layout.chipMarkHeight)
        .accessibilityHidden(true)
    }
}

/// A choice: chosen in full ink over the sliding mark, the others quieter.
struct KitChip: View {
    let symbol: String?
    let title: Text
    var count: Int?
    let selected: Bool
    var mark: Namespace.ID?
    var preview: KitState?
    let action: () -> Void
    @State private var hover = KitHover()
    @Namespace private var fallbackMark
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = preview ?? KitState(focus: hover.focus, selected: selected, enabled: enabled)
        let lift = KitLift.resolve(state, kind: .symbol, reduceMotion: reduceMotion)
        Button(action: action) {
            VStack(spacing: Theme.Space.xs - 1) {
                HStack(spacing: Theme.Space.xs + 1) {
                    if let symbol {
                        InkSymbol(name: symbol, pointSize: Theme.Window.Layout.chipSymbolPoint, weight: .semibold,
                                  canvas: Theme.Window.Layout.chipSymbolCanvas)
                            .kitLift(lift, glowRadius: Theme.Space.xs + 1)
                    }
                    title.font(Theme.Window.Font.captionStrong).lineLimit(1).fixedSize()
                    if let count {
                        Text(count, format: .number).font(Theme.Window.Font.data)
                            .foregroundStyle(Theme.Palette.ink3.color)
                    }
                }
                .foregroundStyle(state.selected ? Theme.Palette.ink.color : Theme.Palette.ink3.color)
                KitMark(visible: state.selected, mark: mark ?? fallbackMark)
            }
            .padding(.horizontal, Theme.Space.s - 2)
            .frame(height: Theme.Window.Layout.chipHeight)
            .background(KitControlBackground(radius: Theme.Radius.control))
            .opacity(lift.opacity)
            .contentShape(.rect)
            .kitPressed(state.pressed)
            .kitPreview(preview)
        }
        .buttonStyle(KitPressStyle())
        .onHover { hover.update(inside: $0) }
        .animation(reduceMotion ? nil : Theme.Window.Motion.lift, value: state)
        .accessibilityLabel(title)
        .accessibilityAddTraits(state.selected ? .isSelected : [])
    }
}

/// A row of tabs in the panel's tool look, with the mark sliding under the chosen one.
struct KitTabStrip<ID: Hashable>: View {
    struct Tab {
        let id: ID
        let symbol: String
        let title: Text
    }

    let tabs: [Tab]
    @Binding var selection: ID
    @Namespace private var mark
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.id) { tab in
                KitToolButton(symbol: tab.symbol, title: tab.title, selected: tab.id == selection, mark: mark) {
                    withAnimation(Theme.Motion.resolve(Theme.Window.Motion.select, reduceMotion: reduceMotion)) {
                        selection = tab.id
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .kitHoverGroup()
        .accessibilityElement(children: .contain)
    }
}

/// The panel's call to action: a capsule that blooms on hover. `primary` fills with its tint
/// (record red by default); `secondary` is the quieter partner. Its width never changes: the
/// shortcut's room is kept while it is hidden, so hovering never pushes a neighbour.
struct KitCapsuleButton: View {
    enum Role { case primary, secondary }

    let title: Text
    var symbol: String?
    var role: Role = .secondary
    var shortcut: String?
    var tint: Color = Theme.Palette.record.color
    var onTint: Color = Theme.Palette.onRecord.color
    var preview: KitState?
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = preview ?? KitState(focus: hovered ? true : nil, enabled: enabled)
        let bloom = state.lifted
        Button(action: action) {
            // The hidden full content sizes the capsule; the visible content stays centred in it
            // and makes room for the shortcut when it blooms.
            ZStack {
                content(showsShortcut: true, bloom: false).hidden()
                content(showsShortcut: bloom, bloom: bloom)
            }
            .foregroundStyle(role == .primary ? onTint : Theme.Palette.ink.color)
            .padding(.horizontal, Theme.Space.l)
            .frame(height: Theme.Window.Layout.capsuleHeight)
            .background(fill(bloom: bloom), in: .capsule)
            .background(KitControlBackground())
            .overlay(Capsule().strokeBorder(edge(bloom: bloom), lineWidth: Theme.Window.Layout.hairline))
            .shadow(color: glow(bloom: bloom),
                    radius: bloom ? (role == .primary ? Theme.Window.Bloom.radius : Theme.Window.Bloom.quietRadius) : 0,
                    y: bloom ? (role == .primary ? Theme.Window.Bloom.drop : Theme.Window.Bloom.quietDrop) : 0)
            .opacity(state.enabled ? 1 : Theme.Window.Lift.disabled)
            .contentShape(.capsule)
            .kitPressed(state.pressed)
            .kitPreview(preview)
        }
        .buttonStyle(KitPressStyle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : Theme.Window.Motion.bloom, value: state)
    }

    private func content(showsShortcut: Bool, bloom: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            if let symbol {
                Image(systemName: symbol).font(Theme.Window.Font.bodyStrong)
                    .scaleEffect(bloom && !reduceMotion ? Theme.Window.Bloom.symbolScale : 1)
            }
            title.font(Theme.Window.Font.bodyStrong).lineLimit(1)
            if let shortcut, showsShortcut {
                Text(verbatim: shortcut).font(Theme.Window.Font.data).opacity(Theme.Window.Bloom.shortcut)
                    .transition(.opacity)
            }
        }
    }

    private func fill(bloom: Bool) -> Color {
        switch role {
        case .primary: tint.opacity(bloom ? 1 : Theme.Window.Bloom.restFill)
        case .secondary: bloom ? Theme.Palette.pressed.color : Theme.Palette.hover.color
        }
    }

    private func edge(bloom: Bool) -> Color {
        role == .primary || bloom ? Theme.Window.Ink.capsuleEdge.color : Theme.Window.Ink.quietEdge.color
    }

    private func glow(bloom: Bool) -> Color {
        guard bloom else { return .clear }
        return role == .primary ? tint.opacity(Theme.Window.Bloom.glow) : Theme.Palette.ink.color.opacity(Theme.Window.Bloom.quietGlow)
    }
}

/// "All ›": a quiet link whose arrow steps forward on hover.
struct KitLinkButton: View {
    let title: Text
    var preview: KitState?
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = preview ?? KitState(focus: hovered ? true : nil, enabled: enabled)
        let lit = state.lifted
        Button(action: action) {
            HStack(spacing: 2) {
                title
                Image(systemName: "chevron.right").font(Theme.Window.Font.label.weight(.bold))
                    .offset(x: lit && !reduceMotion ? Theme.Window.Bloom.arrowStep : 0)
            }
            .font(Theme.Window.Font.captionStrong)
            .foregroundStyle(lit ? Theme.Palette.ink.color : Theme.Palette.ink2.color)
            .padding(.horizontal, Theme.Space.xs)
            .frame(minHeight: Theme.Window.Layout.linkHeight)
            .background(KitControlBackground(radius: Theme.Radius.control, pressedFill: false))
            .opacity(state.enabled ? 1 : Theme.Window.Lift.disabled)
            .contentShape(.rect)
            .kitPressed(state.pressed)
            .kitPreview(preview)
        }
        .buttonStyle(KitPressStyle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : Theme.Window.Motion.bloom, value: lit)
    }
}

/// A shortcut as the panel writes it: plain SF Mono, quiet until its row is lit (⌘1).
struct KitKeyBadge: View {
    let key: String
    var lit = false

    var body: some View {
        Text(verbatim: key)
            .font(Theme.Window.Font.data)
            .foregroundStyle(lit ? Theme.Palette.ink2.color : Theme.Palette.ink3.color)
            .accessibilityHidden(true)
    }
}
