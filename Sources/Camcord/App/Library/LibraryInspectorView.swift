import SwiftUI

struct LibraryInspectorView: View {
    let items: [CaptureItem]
    let thumbnails: LibraryThumbnails
    let copy: () -> Void
    let reveal: () -> Void
    let rename: () -> Void
    let trash: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let item = items.first {
                    if items.count > 1 {
                        Text("\(items.count) captures selected").font(Theme.Font.rowStrong)
                        Text("First selected capture").font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink3.color)
                    }
                    LibraryThumbnail(item: item, thumbnails: thumbnails)
                        .aspectRatio(Theme.Library.thumbnailAspect, contentMode: .fit)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.thumb)
                            .strokeBorder(Theme.Palette.hairline.color, lineWidth: Theme.Library.hairline))
                    Text(verbatim: item.title)
                        .font(Theme.Font.rowStrong)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    LibraryCaptureFacts(item: item)
                    if items.count > 1 {
                        Text("Selection actions").font(Theme.Font.captionStrong).foregroundStyle(Theme.Palette.ink3.color)
                    }
                    LibraryInspectorActions(items: items, copy: copy, reveal: reveal, rename: rename, trash: trash)
                } else {
                    Text("Select a capture to see its details.").font(Theme.Font.body).foregroundStyle(Theme.Palette.ink3.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Library.inspectorInset)
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Library.inspectorInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.surface.color)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.Palette.hairline.color).frame(width: 1).accessibilityHidden(true) }
    }
}

private struct LibraryCaptureFacts: View {
    let item: CaptureItem

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Library.emptyGap, verticalSpacing: Theme.Library.controlGap) {
            GridRow {
                Text("Kind").foregroundStyle(Theme.Palette.ink3.color)
                Text(item.kind.label).font(Theme.Font.data).frame(maxWidth: .infinity, alignment: .trailing)
            }
            fact("Size", ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
            if let size = item.pixelSize { fact("Pixels", "\(Int(size.width)) × \(Int(size.height))") }
            if let duration = item.duration { fact("Length", LibraryItemFormatting.duration(duration)) }
            fact("Taken", LibraryItemFormatting.taken(item.createdAt))
        }
        .font(Theme.Font.body)
    }

    private func fact(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(Theme.Palette.ink3.color)
            Text(verbatim: value).font(Theme.Font.data)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
    }
}

private struct LibraryInspectorActions: View {
    let items: [CaptureItem]
    let copy: () -> Void
    let reveal: () -> Void
    let rename: () -> Void
    let trash: () -> Void

    var body: some View {
        VStack(spacing: Theme.Library.controlGap) {
            Grid(horizontalSpacing: Theme.Library.controlGap, verticalSpacing: Theme.Library.controlGap) {
                GridRow {
                    Button(action: copy) { Label("Copy", systemImage: "doc.on.doc") }
                    Button(action: reveal) { Label("Reveal", systemImage: "folder") }.help(Text("Show in Finder"))
                }
                GridRow {
                    Button(action: rename) { Label("Rename…", systemImage: "pencil") }
                        .disabled(items.count != 1)
                    ShareLink(items: items.map(\.url)) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
            .buttonStyle(LibraryActionStyle(fillsWidth: true))
            Button(action: trash) { Label("Move to Trash", systemImage: "trash") }
                .buttonStyle(LibraryActionStyle(destructive: true, fillsWidth: true))
        }
    }
}
