import SwiftUI

struct StudioSourceStrip: View {
    let session: StudioSession
    let locked: Bool
    let selectRegion: (@MainActor () async -> Void)?
    @Environment(\.studioPresentationProvider) private var provider
    private var presentation: StudioPresentationSnapshot? { provider?.snapshot }
    private var choices: [StudioSourceChoice] { presentation?.sources ?? session.thumbnailChoices }
    @State private var hasTrailingSources = false
    private var selected: StudioSourceChoice? { presentation == nil ? session.selectedSource : presentation?.selectedSource }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            GeometryReader { viewport in
                let viewportSize = viewport.size
                let columns: CGFloat = viewportSize.width >= 340 ? 3 : 2
                let tileWidth = min(Theme.Studio.sourceWidth, max(96, (viewportSize.width - (columns - 1) * Theme.Studio.sourceGap) / columns))
                ScrollViewReader { scroll in
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: Theme.Studio.sourceGap) {
                            ForEach(choices) { source in
                                StudioSourceTile(source: source, image: presentation == nil ? session.sourceThumbnails.images[source.id] : presentation?.thumbnails[source.id],
                                                 selected: source.id == selected?.id, width: tileWidth) {
                                    if presentation == nil { session.selectSource(source) }
                                }
                                .onGeometryChange(for: Bool.self) { proxy in
                                    proxy.frame(in: .named("studio-sources"))
                                        .intersects(CGRect(origin: .zero, size: viewportSize))
                                } action: { visible in if presentation == nil { session.sourceThumbnails.setTileVisible(source.id, visible) } }
                                .onDisappear { if presentation == nil { session.sourceThumbnails.setTileVisible(source.id, false) } }
                            }
                            StudioRegionTile(enabled: presentation != nil || selectRegion != nil, width: tileWidth, action: chooseRegion).id("studio-region")
                        }.padding(.vertical, Theme.Space.xs)
                    }.coordinateSpace(.named("studio-sources")).scrollIndicators(.hidden)
                        .onScrollGeometryChange(for: Bool.self) { geometry in
                            geometry.contentSize.width > geometry.visibleRect.maxX + 1
                        } action: { _, trailing in hasTrailingSources = trailing }
                        .overlay(alignment: .trailing) {
                            if hasTrailingSources {
                                Button { withAnimation(.snappy(duration: 0.25)) { scroll.scrollTo("studio-region", anchor: .trailing) } } label: {
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                                        .frame(width: 24, height: 32)
                                        .background(Theme.Palette.surface.color, in: .capsule)
                                        .overlay(Capsule().strokeBorder(Theme.Palette.hairline.color))
                                }.buttonStyle(.plain).padding(.trailing, 2)
                                    .accessibilityLabel(Text("More sources"))
                                    .help(Text("Scroll to see more sources"))
                            }
                        }
                }
            }
            .frame(height: Theme.Studio.sourceHeight + Theme.Studio.sourceCaptionGap + Theme.Studio.channelIcon)
        }
        .contextMenu {
            Button("Clear source") { if presentation == nil { session.clearSource() } }.disabled(locked || selected == nil)
        }
        .accessibilityAction(named: Text("Clear source")) { if !locked && presentation == nil { session.clearSource() } }
        .disabled(locked)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Recording source"))
    }
    private func chooseRegion() { if presentation == nil, let selectRegion { Task { await selectRegion() } } }
}

private struct StudioSourceTile: View {
    let source: StudioSourceChoice
    let image: NSImage?
    let selected: Bool
    let width: CGFloat
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Studio.sourceCaptionGap) {
                ZStack {
                    Theme.Palette.well.color
                    if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
                    else { Image(systemName: symbol).foregroundStyle(Theme.Palette.ink3.color) }
                }
                .frame(width: width, height: width * Theme.Studio.sourceHeight / Theme.Studio.sourceWidth)
                .clipShape(.rect(cornerRadius: Theme.Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(selected ? Theme.Palette.ink.color : Theme.Palette.hairline.color,
                                      lineWidth: selected ? 3 : 0.5)
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.Palette.onRecord.color)
                            .frame(width: 20, height: 20).background(Theme.Palette.record.color, in: .circle)
                            .padding(5).accessibilityHidden(true)
                    }
                }
                Text(verbatim: source.title).font(Theme.Font.caption).lineLimit(2).truncationMode(.middle)
                    .foregroundStyle(selected ? Theme.Palette.ink.color : Theme.Palette.ink2.color)
            }.frame(width: width, alignment: .leading)
        }.buttonStyle(.plain).help(Text(verbatim: source.title))
            .accessibilityLabel(Text(verbatim: source.title))
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private var symbol: String {
        switch source.id { case .display: "display"; case .window: "macwindow"; case .region: "crop" }
    }
}

private struct StudioRegionTile: View {
    let enabled: Bool
    let width: CGFloat
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Studio.sourceCaptionGap) {
                Image(systemName: "rectangle.dashed")
                    .foregroundStyle(Theme.Palette.ink3.color)
                    .frame(width: width, height: width * Theme.Studio.sourceHeight / Theme.Studio.sourceWidth)
                    .background(Theme.Palette.well.color, in: .rect(cornerRadius: Theme.Radius.control))
                Text("Choose a region…").font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink2.color)
                    .lineLimit(2)
            }.frame(width: width, alignment: .leading)
        }.buttonStyle(.plain).disabled(!enabled)
            .help(Text(enabled ? LocalizedStringResource("Choose a region…") : LocalizedStringResource("Region selection is unavailable.")))
    }
}
