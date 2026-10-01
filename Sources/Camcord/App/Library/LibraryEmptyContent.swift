import SwiftUI

struct LibraryEmptyContent: View {
    @Environment(\.appServices) private var services

    private var configuredKinds: [CaptureKind] { CaptureKind.allCases.filter { $0.shortcut != nil } }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: Theme.Library.emptyGap) {
                    ViewfinderMarkView(dot: .plain, lineFraction: Theme.Library.emptyMarkLineFraction)
                        .frame(width: Theme.Library.emptyMark, height: Theme.Library.emptyMark)
                        .foregroundStyle(Theme.Palette.ink3.color)
                        .accessibilityHidden(true)
                    Text("No captures yet")
                        .font(Theme.Font.title)
                        .foregroundStyle(Theme.Palette.ink.color)
                        .padding(.top, Theme.Library.emptyTitleInset)
                    if !configuredKinds.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.Library.shortcutWidth, maximum: Theme.Library.shortcutWidth), spacing: Theme.Space.s)],
                                  spacing: Theme.Space.s) {
                            ForEach(configuredKinds) { kind in LibraryShortcutTile(kind: kind) }
                        }
                        .frame(maxWidth: Theme.Library.shortcutMaxWidth)
                        .padding(.top, Theme.Space.s)
                        .padding(.bottom, Theme.Library.shortcutBottomInset)
                    }
                    Button(action: captureRegion) {
                        Label { Text(CaptureKind.region.actionTitle) } icon: { Image(systemName: CaptureKind.region.symbol) }
                    }
                    .buttonStyle(LibraryActionStyle(primary: true, large: true))
                    .disabled(services == nil)
                    .help(Text(services == nil ? "Capture actions are unavailable in this window." : "Capture a region"))
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, Theme.Space.xl)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func captureRegion() { services?.capture(.region) }
}

private struct LibraryShortcutTile: View {
    let kind: CaptureKind

    var body: some View {
        VStack(spacing: Theme.Library.controlGap) {
            Image(systemName: kind.symbol)
                .font(Theme.Font.title.weight(.regular))
                .frame(height: Theme.Library.shortcutIcon)
                .foregroundStyle(Theme.Palette.ink.color)
                .accessibilityHidden(true)
            Text(kind.title).font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink2.color).lineLimit(1)
            KeyCap(shortcut: kind.shortcut)
        }
        .frame(width: Theme.Library.shortcutWidth)
        .padding(.top, Theme.Library.shortcutTopInset)
        .padding(.bottom, Theme.Library.shortcutBottomInset)
        .background(Theme.Palette.surface.color, in: .rect(cornerRadius: Theme.Radius.thumb))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.thumb).strokeBorder(Theme.Palette.hairline.color))
        .accessibilityElement(children: .combine)
    }
}
