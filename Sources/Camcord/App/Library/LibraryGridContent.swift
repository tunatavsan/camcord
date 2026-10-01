import SwiftUI

struct LibraryDateGroup: Identifiable {
    let date: Date
    let title: String
    let items: [CaptureItem]
    var id: Date { date }
}

struct LibraryGridContent<Tile: View>: View {
    let groups: [LibraryDateGroup]
    let newestID: String?
    let tile: (CaptureItem) -> Tile

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Library.groupGap) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: Theme.Library.headerGap) {
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                                Text(verbatim: group.title)
                                    .font(Theme.Font.captionStrong)
                                    .tracking(Theme.Font.headerTracking)
                                Text(verbatim: String(group.items.count)).font(Theme.Font.dataSmall)
                            }
                            .foregroundStyle(Theme.Palette.ink3.color)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.Library.gridMinimum), spacing: Theme.Space.l)],
                                      spacing: Theme.Library.gridRowGap) {
                                ForEach(group.items) { item in tile(item).id(item.id) }
                            }
                        }
                    }
                }
                .padding(.bottom, Theme.Library.selectionOutset)
            }
            .scrollClipDisabled()
            .onChange(of: newestID) { _, id in if let id { proxy.scrollTo(id, anchor: .top) } }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LibraryFilterBar: View {
    let items: [CaptureItem]
    @Binding var filter: CaptureItem.Kind?
    @Binding var search: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.m) {
                chips.fixedSize()
                Spacer(minLength: 0)
                searchField
            }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ScrollView(.horizontal) { chips.fixedSize() }
                    .frame(height: Theme.Library.controlHeight)
                searchField
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var chips: some View {
        HStack(spacing: Theme.Library.filterGap) {
            chip("All", kind: nil)
            chip("Screenshots", kind: .screenshot)
            chip("Scroll captures", kind: .scrollCapture)
            chip("Recordings", kind: .recording)
        }
    }

    private func chip(_ title: LocalizedStringKey, kind: CaptureItem.Kind?) -> some View {
        Button { filter = kind } label: {
            HStack(spacing: Theme.Library.controlGap) {
                Text(title).font(Theme.Font.body).foregroundStyle(filter == kind ? Theme.Palette.ink.color : Theme.Palette.ink2.color)
                Text(verbatim: String(items.filter { kind == nil || $0.kind == kind }.count))
                    .font(Theme.Font.dataSmall).foregroundStyle(Theme.Palette.ink3.color)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Theme.Library.controlInset)
            .frame(height: Theme.Library.controlHeight)
            .background(filter == kind ? Theme.Palette.selectionStrong.color : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == kind ? .isSelected : [])
    }

    private var searchField: some View {
        HStack(spacing: Theme.Library.controlGap) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.Palette.ink3.color).accessibilityHidden(true)
            TextField("Search captures", text: $search).textFieldStyle(.plain).font(Theme.Font.body)
        }
        .padding(.horizontal, Theme.Library.searchInset)
        .frame(width: Theme.Library.searchWidth, height: Theme.Library.controlHeight)
        .background(Theme.Palette.surface.color, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Palette.hairline.color))
    }
}
