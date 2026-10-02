import SwiftUI

extension EnvironmentValues {
    /// Selection resets scrolling independently of window/module activity.
    @Entry var formPageSelected = true
}

// The prototype's settings page (ref `settings-*`): a display title, then cards of rows — a
// label (with an optional note under it) on the left, the control on the right, hairlines
// between rows. Cards are opaque content on the frosted window (K1.G, NOTE-2).

/// A page of cards under a display title, scrolling as one.
struct FormPage<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder var content: Content
    @Environment(\.formPageSelected) private var selected
    @State private var scrollPosition = ScrollPosition(edge: .top)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Settings.titleGap) {
                Text(title)
                    .font(Theme.Font.display)
                    .tracking(Theme.Font.displayTracking)
                    .foregroundStyle(Theme.Palette.ink.color)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: Theme.Settings.cardGap) { content }
            }
            .frame(maxWidth: Theme.Settings.maximumWidth, alignment: .leading)
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.top, Theme.Space.l)
            .padding(.bottom, Theme.Space.xxl)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.automatic)
        .scrollPosition($scrollPosition)
        .onChange(of: selected) { _, selected in
            guard selected else { return }
            // The page fades in, but a previously scrolled document resets without a scrolling animation.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { scrollPosition.scrollTo(edge: .top) }
        }
    }
}

/// One card: an optional caption title above it, rows inside, an optional footnote below.
struct FormCard<Content: View>: View {
    var title: LocalizedStringResource?
    var footnote: LocalizedStringResource?
    @ViewBuilder var content: Content
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let title {
                Text(title)
                    .font(Theme.Font.captionStrong)
                    .tracking(Theme.Font.headerTracking)
                    .foregroundStyle(Theme.Palette.ink3.color)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                content
            }
            .background(Theme.Palette.surface.color, in: RoundedRectangle(cornerRadius: Theme.Radius.box, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.box, style: .continuous)
                .strokeBorder(Theme.Palette.hairline.color, lineWidth: 1 / max(1, displayScale)))
            if let footnote {
                Text(footnote)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.xs)
            }
        }
    }
}

/// One row of a card: label and note on the left, the control on the right, a hairline above
/// every row but the first.
struct FormRow<Control: View>: View {
    let label: LocalizedStringResource
    var note: LocalizedStringResource?
    var isFirst = false
    @ViewBuilder var control: Control
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Rectangle().fill(Theme.Palette.hairline.color).frame(height: 1 / max(1, displayScale))
            }
            HStack(alignment: .center, spacing: Theme.Settings.rowGap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.ink.color)
                    if let note {
                        Text(note)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.ink3.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                control.layoutPriority(1)
            }
            .padding(.horizontal, Theme.Settings.rowHorizontal)
            .padding(.vertical, Theme.Settings.rowVertical)
            .frame(minHeight: Theme.Settings.rowMinimum)
        }
    }
}

extension View {
    /// A switch in ink, the prototype's "on" colour (K1: never the system accent).
    func inkSwitch() -> some View {
        toggleStyle(.switch).tint(Theme.Palette.ink.color).labelsHidden()
    }
}
