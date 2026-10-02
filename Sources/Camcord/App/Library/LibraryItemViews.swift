import SwiftUI

struct LibraryCaptureTile<Actions: View>: View {
    let item: CaptureItem
    let thumbnails: LibraryThumbnails
    let isSelected: Bool
    let isFresh: Bool
    let select: () -> Void
    let open: () -> Void
    let preview: () -> Void
    let actions: () -> Actions
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: Theme.Library.tileGap) {
                LibraryThumbnail(item: item, thumbnails: thumbnails)
                    .aspectRatio(Theme.Library.thumbnailAspect, contentMode: .fit)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.thumb)
                            .strokeBorder(thumbnailBorder, lineWidth: isSelected || isHovered ? 1 : Theme.Library.hairline)
                    }
                    .overlay(alignment: .bottomLeading) { badge.padding(Theme.Library.badgeInset) }
                    .overlay(alignment: .topTrailing) {
                        if isFresh {
                            Text("Just now")
                                .font(Theme.Font.captionStrong)
                                .padding(.horizontal, Theme.Library.badgePadding)
                                .frame(height: Theme.Library.badgeHeight)
                                .foregroundStyle(Theme.Palette.onInk.color)
                                .background(Theme.Palette.ink.color, in: .rect(cornerRadius: Theme.Radius.badge))
                                .padding(Theme.Library.badgeInset)
                        }
                    }
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(verbatim: item.title)
                        .font(Theme.Font.body)
                        .lineLimit(2, reservesSpace: true)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: LibraryItemFormatting.time(item.createdAt))
                        .font(Theme.Font.dataSmall)
                        .foregroundStyle(Theme.Palette.ink3.color)
                }
                .padding(.horizontal, Theme.Library.metaInset)
                .padding(.bottom, Theme.Library.controlGap)
            }
            .padding(Theme.Library.controlGap)
            .background(isSelected ? Theme.Palette.selectionStrong.color : .clear,
                        in: .rect(cornerRadius: Theme.Radius.thumb))
            .contentShape(.rect)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Theme.Radius.thumb)
                        .strokeBorder(Theme.Palette.hairlineStrong.color, lineWidth: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded { _ in open() })
        .contextMenu { actions() }
        .draggable(containerItemID: item.url)
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityValue(Text(item.kind.label))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("Open capture"), open)
        .accessibilityAction(named: Text("Quick Look"), preview)
    }

    private var thumbnailBorder: Color {
        isSelected ? Theme.Palette.ink3.color : isHovered ? Theme.Palette.hairlineStrong.color : Theme.Palette.hairline.color
    }

    @ViewBuilder private var badge: some View {
        if item.kind == .scrollCapture {
            badgeLabel("Scroll", symbol: "arrow.down.document")
        } else if item.kind == .recording, let seconds = item.duration {
            HStack(spacing: Theme.Library.badgeGap) {
                Image(systemName: "play").accessibilityHidden(true)
                Text(verbatim: LibraryItemFormatting.duration(seconds))
            }
            .modifier(LibraryBadgeAppearance())
        }
    }

    private func badgeLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol).modifier(LibraryBadgeAppearance())
    }
}

private struct LibraryBadgeAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.Font.dataSmall)
            .foregroundStyle(Theme.Library.badgeInk)
            .padding(.horizontal, Theme.Library.badgePadding)
            .frame(height: Theme.Library.badgeHeight)
            .background(Theme.Library.badgeFill, in: .rect(cornerRadius: Theme.Radius.badge))
    }
}

struct LibraryThumbnail: View {
    let item: CaptureItem
    let thumbnails: LibraryThumbnails
    @Environment(\.mainWindowModuleActive) private var moduleActive
    @Environment(\.mainWindowLifecycle) private var lifecycle
    @State private var image: CGImage?
    @State private var isLoading = true

    private var isActive: Bool { moduleActive && (lifecycle?.allowsLivePreview ?? true) }
    private struct Request: Equatable { let item: CaptureItem; let isActive: Bool }

    var body: some View {
        ZStack {
            Theme.Palette.well.color
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: item.kind == .recording ? "film" : "photo.badge.exclamationmark")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.Palette.ink3.color)
                    .accessibilityLabel(Text("Thumbnail unavailable"))
            }
        }
        .clipShape(.rect(cornerRadius: Theme.Radius.thumb))
        .task(id: Request(item: item, isActive: isActive)) {
            guard isActive else { return }
            image = nil
            isLoading = true
            let decoded = await thumbnails.image(for: item)
            guard !Task.isCancelled else { return }
            image = decoded
            isLoading = false
        }
    }
}

enum LibraryItemFormatting {
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    static func taken(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return String(localized: "Today") + " " + time(date) }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "Yesterday") + " " + time(date) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

struct LibraryActionStyle: ButtonStyle {
    var primary = false
    var destructive = false
    var large = false
    var fillsWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? Theme.Font.row.weight(.medium) : Theme.Font.body)
            .lineLimit(1)
            .padding(.horizontal, large ? Theme.Space.l : Theme.Library.controlInset)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .frame(height: large ? Theme.Library.primaryHeight : Theme.Library.controlHeight)
            .foregroundStyle(destructive ? Theme.Palette.record.color : primary ? Theme.Palette.onInk.color : Theme.Palette.ink.color)
            .background(primary ? Theme.Palette.ink.color : Theme.Palette.raised.color,
                        in: .rect(cornerRadius: large ? Theme.Radius.thumb : Theme.Radius.control))
            .opacity(isEnabled ? configuration.isPressed ? 0.8 : 1 : Theme.Library.disabledOpacity)
    }
}
