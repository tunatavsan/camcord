import SwiftUI

/// A sidebar row: the panel's tool rise on its symbol, its siblings stepping back, and the
/// chosen row in full ink beside a short ink bar that slides between rows (no fill, never the
/// user's accent).
struct KitNavRow: View {
    let symbol: String
    let title: Text
    var key: String?
    let selected: Bool
    var mark: Namespace.ID?
    var preview: KitState?
    let action: () -> Void
    @State private var hover = KitHover()
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = preview ?? KitState(focus: hover.focus, selected: selected, enabled: enabled)
        let lift = KitLift.resolve(state, kind: .row, reduceMotion: reduceMotion)
        Button(action: action) {
            HStack(spacing: Theme.Space.s + 1) {
                InkSymbol(name: symbol, pointSize: Theme.Window.Layout.symbolPoint,
                          weight: state.selected ? .semibold : .medium, canvas: Theme.Window.Layout.symbolCanvas)
                    .kitLift(lift)
                    .opacity(lift.opacity)
                Group {
                    title.font(state.selected ? Theme.Window.Font.bodyStrong : Theme.Window.Font.row).lineLimit(1)
                    Spacer(minLength: Theme.Space.xs)
                    if let key { KitKeyBadge(key: key, lit: state.lifted || state.selected) }
                }
                .opacity(lift.textOpacity)
            }
            .foregroundStyle(state.selected ? Theme.Palette.ink.color : Theme.Palette.ink2.color)
            .padding(.horizontal, Theme.Window.Layout.rowInset)
            .frame(height: Theme.Window.Layout.rowHeight)
            .background(KitControlBackground(radius: Theme.Window.Layout.rowRadius))
            .overlay(alignment: .leading) { selectionMark(visible: state.selected) }
            .contentShape(.rect)
            .kitPressed(state.pressed, wide: true)
            .kitPreview(preview)
        }
        .buttonStyle(KitPressStyle(wide: true))
        .onHover { hover.update(inside: $0) }
        .animation(reduceMotion ? nil : Theme.Window.Motion.lift, value: state)
        .accessibilityLabel(title)
        .accessibilityAddTraits(state.selected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder private func selectionMark(visible: Bool) -> some View {
        if visible {
            let bar = Capsule().fill(Theme.Palette.ink.color)
                .frame(width: Theme.Window.Layout.markWidth, height: Theme.Window.Layout.markHeight)
                .padding(.leading, Theme.Space.xs - 1)
            if let mark { bar.matchedGeometryEffect(id: "kit.nav.mark", in: mark) } else { bar }
        }
    }
}

/// A quiet section label in ink 3, with an optional link on the right ("All ›").
struct KitSectionHeader<Trailing: View>: View {
    let title: Text
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            title.font(Theme.Window.Font.captionStrong).foregroundStyle(Theme.Palette.ink3.color)
            Spacer(minLength: Theme.Space.s)
            trailing
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

extension KitSectionHeader where Trailing == EmptyView {
    init(title: Text) { self.init(title: title) { EmptyView() } }
}

/// A capture tile: the picture whole inside a well of fixed ratio, its name and a detail
/// below. Hovered the tile lifts a little, like the panel's recent captures; chosen, an ink
/// ring stands around the well.
struct KitCard<Picture: View, Badge: View>: View {
    let title: Text
    let detail: Text
    let selected: Bool
    var aspect: CGFloat = Theme.Library.thumbnailAspect
    var preview: KitState?
    @ViewBuilder var picture: Picture
    @ViewBuilder var badge: Badge
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = preview ?? KitState(focus: hovered ? true : nil, selected: selected, enabled: enabled)
        let lifted = state.lifted && !reduceMotion
        VStack(alignment: .leading, spacing: Theme.Space.s - 1) {
            ZStack {
                Theme.Palette.well.color
                picture
            }
            .aspectRatio(aspect, contentMode: .fit)
            .overlay(alignment: .topLeading) { badge.padding(Theme.Library.badgeInset) }
            .clipShape(.rect(cornerRadius: Theme.Radius.thumb, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.thumb + Theme.Space.xs, style: .continuous)
                    .strokeBorder(Theme.Palette.ink.color, lineWidth: Theme.Library.selectionLine)
                    .padding(-Theme.Space.xs)
                    .opacity(state.selected ? 1 : 0)
            }
            .shadow(color: Theme.Palette.ink.color.opacity(state.lifted ? Theme.Window.Bloom.tileGlow : 0),
                    radius: Theme.Window.Lift.glowRadius)
            .scaleEffect(lifted ? Theme.Window.Lift.tileScale : 1)
            .offset(y: lifted ? -Theme.Window.Lift.tileRise : 0)
            VStack(alignment: .leading, spacing: 1) {
                title.font(Theme.Window.Font.row).foregroundStyle(Theme.Palette.ink.color)
                    .lineLimit(1).truncationMode(.middle)
                detail.font(Theme.Window.Font.dataBody).foregroundStyle(Theme.Palette.ink3.color).lineLimit(1)
            }
            .padding(.horizontal, Theme.Library.metaInset)
        }
        .opacity(state.enabled ? 1 : Theme.Window.Lift.disabled)
        .kitPressed(state.pressed, wide: true)
        .contentShape(.rect)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : (state.lifted ? Theme.Window.Motion.lift : Theme.Window.Motion.settle),
                   value: state.lifted)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(state.selected ? .isSelected : [])
    }
}

extension KitCard where Badge == EmptyView {
    init(title: Text, detail: Text, selected: Bool, aspect: CGFloat = Theme.Library.thumbnailAspect,
         preview: KitState? = nil, @ViewBuilder picture: () -> Picture) {
        self.init(title: title, detail: detail, selected: selected, aspect: aspect, preview: preview,
                  picture: picture, badge: { EmptyView() })
    }
}

/// A list row: leading picture or symbol, a name over a detail, trailing content. Hovered, its
/// leading symbol rises and glows over the faint hover fill; chosen, the row is marked by the
/// sidebar's ink bar over the selection fill.
struct KitListRow<Leading: View, Trailing: View>: View {
    let title: Text
    var detail: Text?
    let selected: Bool
    var preview: KitState?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = preview ?? KitState(focus: hovered ? true : nil, selected: selected, enabled: enabled)
        let lift = KitLift.resolve(state, kind: .symbol, reduceMotion: reduceMotion)
        HStack(spacing: Theme.Space.m) {
            leading.kitLift(lift)
            VStack(alignment: .leading, spacing: 1) {
                title.font(Theme.Window.Font.row).foregroundStyle(Theme.Palette.ink.color)
                    .lineLimit(1).truncationMode(.middle)
                if let detail {
                    detail.font(Theme.Window.Font.dataBody).foregroundStyle(Theme.Palette.ink3.color).lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Theme.Space.s)
            trailing.fixedSize()
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s - 2)
        .background(KitControlBackground(radius: Theme.Window.Layout.rowRadius, selected: state.selected,
                                         hovered: state.lifted))
        .overlay(alignment: .leading) {
            if state.selected {
                Capsule().fill(Theme.Palette.ink.color)
                    .frame(width: Theme.Window.Layout.markWidth, height: Theme.Window.Layout.markHeight)
                    .padding(.leading, Theme.Space.xs - 1)
            }
        }
        .opacity(state.enabled ? 1 : Theme.Window.Lift.disabled)
        .kitPressed(state.pressed, wide: true)
        .kitPreview(preview)
        .contentShape(.rect)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : Theme.Window.Motion.lift, value: state)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(state.selected ? .isSelected : [])
    }
}

/// An empty surface: a quiet symbol, one large line, what to do, and the actions to do it.
struct KitEmptyState<Actions: View>: View {
    let symbol: String
    let title: Text
    let message: Text
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Image(systemName: symbol)
                .font(Theme.Window.Font.symbolEmpty)
                .foregroundStyle(Theme.Palette.ink3.color)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Space.s) {
                title.font(Theme.Window.Font.display).foregroundStyle(Theme.Palette.ink.color)
                message.font(Theme.Window.Font.body).foregroundStyle(Theme.Palette.ink2.color)
            }
            .multilineTextAlignment(.center)
            actions
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
