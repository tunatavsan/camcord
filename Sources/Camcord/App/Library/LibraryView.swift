import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct LibraryModuleView: View {
    @Environment(\.appServices) private var services
    var body: some View {
        if let services { LibraryView(store: services.library) } else { LibraryEmptyView() }
    }
}

struct LibraryView: View {
    @Bindable var store: LibraryStore
    @Environment(\.mainWindowLifecycle) private var lifecycle
    @State private var visibilityToken: UUID?
    @State private var quickLookURL: URL?
    @State private var renameID: String?
    @State private var renameName = ""
    @State private var confirmsTrash = false
    @State private var anchor: String?
    @State private var navigationID: String?
    @FocusState private var hasFocus: Bool

    private var inspectorPresentation: Binding<Bool> {
        Binding(get: { !store.items.isEmpty && store.showsInspector }, set: { presented in
            // An automatic empty-state dismissal must preserve the user's inspector intent.
            guard !store.items.isEmpty else { return }
            store.showsInspector = presented
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            heading
            filters
            content
        }
        .padding(Theme.Space.xl)
        .foregroundStyle(Theme.Palette.ink.color)
        .tint(Theme.Palette.ink.color)
        .dragContainer(for: URL.self, itemID: \.self) { (urls: [URL]) in urls }
        .dragContainerSelection(store.selectedItems.map(\.url))
        .dragConfiguration(DragConfiguration(allowMove: false, allowDelete: false))
        .onChange(of: lifecycle?.allowsLivePreview, initial: true) { _, visible in
            if visible == true, visibilityToken == nil { visibilityToken = store.acquireVisibility() }
            if visible != true, let token = visibilityToken { store.releaseVisibility(token); visibilityToken = nil }
        }
        .onDisappear { if let token = visibilityToken { store.releaseVisibility(token); visibilityToken = nil } }
        .focusable().focused($hasFocus)
        .onKeyPress(.space) { preview(); return .handled }
        .onKeyPress(.return) { beginRename(); return .handled }
        .onDeleteCommand { requestTrash() }
        .onExitCommand { quickLookURL = nil; store.selection.removeAll() }
        .onMoveCommand { direction in moveSelection(direction) }
        .quickLookPreview($quickLookURL, in: store.selectedItems.map(\.url))
        .inspector(isPresented: inspectorPresentation) { inspector.frame(minWidth: 260, idealWidth: 300, maxWidth: 360) }
        .sheet(isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) { renameSheet }
        .confirmationDialog("Move selected captures to Trash?", isPresented: $confirmsTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                let ids = store.selection
                Task { do { try await store.delete(ids) } catch { store.issue = error.localizedDescription } }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("You can restore these files from the Trash.") }
        .alert("Library action failed", isPresented: Binding(get: { store.issue != nil }, set: { if !$0 { store.issue = nil } })) {
            Button("OK") { store.issue = nil }
        } message: { Text(verbatim: store.issue ?? "") }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            guard store.onOpenScreenshot != nil else {
                store.issue = String(localized: "The screenshot editor is not available yet. Use Quick Look to preview this capture.")
                return false
            }
            Task { await store.openDroppedImage(url) }
            return true
        }
        .background {
            VStack {
                Button("Copy") { Task { await store.copySelection() } }.keyboardShortcut("c", modifiers: .command)
                Button("Select all") { store.selection = Set(store.filteredItems.map(\.id)) }.keyboardShortcut("a", modifiers: .command)
                Button("Open capture") { if let item = store.selectedItems.first { Task { await store.open(item) } } }
                    .keyboardShortcut("o", modifiers: .command)
            }.hidden()
        }
        .task { await store.enforceRetention() }
    }
    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text("Library").font(Theme.Font.display).tracking(Theme.Font.displayTracking)
            Text("\(store.items.count) captures").font(Theme.Font.data).foregroundStyle(Theme.Palette.ink3.color)
            Spacer()
            Button { store.usesGrid.toggle() } label: {
                Image(systemName: store.usesGrid ? "list.bullet" : "square.grid.2x2")
            }.help(Text(store.usesGrid ? "List view" : "Grid view"))
                .accessibilityLabel(Text(store.usesGrid ? "List view" : "Grid view"))
            Button { store.showsInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                .disabled(store.items.isEmpty)
                .help(Text(store.items.isEmpty ? "Select a capture to see its details." : "Show inspector"))
                .accessibilityLabel(Text("Show inspector"))
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help(Text("Refresh Library")).accessibilityLabel(Text("Refresh Library"))
        }.buttonStyle(.borderless)
    }
    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.l) { filterButtons; searchField }
            VStack(alignment: .leading, spacing: Theme.Space.m) { filterButtons; searchField }
        }
    }
    private var filterButtons: some View {
        HStack(spacing: Theme.Space.xs) {
            filterButton("All", kind: nil)
            filterButton("Screenshots", kind: .screenshot)
            filterButton("Scroll captures", kind: .scrollCapture)
            filterButton("Recordings", kind: .recording)
        }.padding(Theme.Space.xs)
            .background(Theme.Palette.surface.color, in: Capsule())
    }
    private func filterButton(_ title: LocalizedStringKey, kind: CaptureItem.Kind?) -> some View {
        Button { store.filter = kind } label: {
            HStack(spacing: Theme.Space.xs) {
                Text(title).font(Theme.Font.caption)
                Text(verbatim: String(store.items.filter { kind == nil || $0.kind == kind }.count)).font(Theme.Font.dataSmall)
            }.padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.s)
                .background(store.filter == kind ? Theme.Palette.selectionStrong.color : Theme.Palette.surface.color, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(store.filter == kind ? .isSelected : [])
    }
    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.Palette.ink3.color).accessibilityHidden(true)
            TextField("Search captures", text: $store.search).textFieldStyle(.plain)
        }.padding(Theme.Space.s).frame(minWidth: 140, maxWidth: 260)
            .background(Theme.Palette.field.color, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }
    @ViewBuilder private var content: some View {
        if store.isLoading && store.items.isEmpty {
            ProgressView("Loading captures…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.items.isEmpty && store.loadingIssue != nil {
            ContentUnavailableView {
                Label("Couldn't load captures", systemImage: "exclamationmark.triangle")
            } actions: { Button("Try again") { Task { await store.refresh() } } }
        } else if store.items.isEmpty {
            LibraryEmptyView()
        } else if store.filteredItems.isEmpty {
            ContentUnavailableView {
                Label("No matching captures", systemImage: "magnifyingglass")
            } description: { Text("Try another search or filter.") }
            actions: { Button("Clear filters") { store.search = ""; store.filter = nil } }
        } else {
            if store.usesGrid { grid } else { list }
            HStack {
                Text("\(store.selection.count) selected")
                Spacer()
                Text(verbatim: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
            }.font(Theme.Font.dataSmall).foregroundStyle(Theme.Palette.ink3.color)
        }
    }
    private var totalBytes: Int64 {
        store.items.reduce(0) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(max(item.byteSize, 0)); return overflow ? .max : sum
        }
    }
    private var groups: [(date: Date, items: [CaptureItem])] {
        Dictionary(grouping: store.filteredItems) { Calendar.current.startOfDay(for: $0.createdAt) }
            .sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }
    private func groupTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.xl) {
                    ForEach(groups, id: \.date) { group in
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            HStack { Text(verbatim: groupTitle(group.date)).font(Theme.Font.body.weight(.semibold))
                                Text(verbatim: String(group.items.count)).font(Theme.Font.dataSmall).foregroundStyle(Theme.Palette.ink3.color) }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: Theme.Space.l)], spacing: Theme.Space.xl) {
                                ForEach(group.items) { item in tile(item).id(item.id) }
                            }
                        }
                    }
                }
            }.onChange(of: store.items.first?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .top) } }
        }
    }
    private var list: some View {
        List(selection: $store.selection) {
            ForEach(groups, id: \.date) { group in
                Section {
                    ForEach(group.items) { item in
                        HStack(spacing: Theme.Space.m) {
                            LibraryThumbnail(item: item, thumbnails: store.thumbnails).frame(width: 64, height: 44)
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                Text(verbatim: item.title).font(Theme.Font.body).lineLimit(1)
                                Text(item.kind.label).font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink3.color)
                            }
                            Spacer()
                            Text(item.createdAt, style: .time).font(Theme.Font.dataSmall)
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file)).font(Theme.Font.dataSmall).frame(width: 75, alignment: .trailing)
                        }.tag(item.id).contextMenu { actions(item) }
                            .onTapGesture(count: 2) { Task { await store.open(item) } }
                            .draggable(containerItemID: item.url)
                    }
                } header: { Text(verbatim: groupTitle(group.date)) }
            }
        }.listStyle(.inset).scrollContentBackground(.hidden)
    }
    private func tile(_ item: CaptureItem) -> some View {
        Button { select(item.id); hasFocus = true } label: {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                LibraryThumbnail(item: item, thumbnails: store.thumbnails)
                    .frame(height: 126).frame(maxWidth: .infinity)
                    .overlay(alignment: .bottomTrailing) {
                        kindBadge(item).font(Theme.Font.dataSmall).padding(Theme.Space.xs)
                            .background(Theme.Palette.surface.color, in: Capsule()).padding(Theme.Space.s)
                    }
                Text(verbatim: item.title).font(Theme.Font.body).lineLimit(1)
                HStack {
                    Text(item.createdAt, style: .time)
                    Spacer()
                    if Date().timeIntervalSince(item.createdAt) >= 0 && Date().timeIntervalSince(item.createdAt) < 600 { Text("Just now") }
                }.font(Theme.Font.dataSmall).foregroundStyle(Theme.Palette.ink3.color)
            }.padding(Theme.Space.s)
                .background(store.selection.contains(item.id) ? Theme.Palette.selection.color : Theme.Palette.surface.color,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.box))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.box)
                    .strokeBorder(store.selection.contains(item.id) ? Theme.Palette.ink.color : Theme.Palette.hairline.color,
                                  lineWidth: store.selection.contains(item.id) ? 2 : 1))
                .contentShape(.rect)
        }.buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { Task { await store.open(item) } })
            .contextMenu { actions(item) }
            .draggable(containerItemID: item.url)
            .accessibilityLabel(Text(verbatim: item.title))
            .accessibilityValue(Text(item.kind.label))
            .accessibilityAddTraits(store.selection.contains(item.id) ? .isSelected : [])
            .accessibilityAction(named: Text("Open capture")) { Task { await store.open(item) } }
            .accessibilityAction(named: Text("Quick Look")) { store.selection = [item.id]; preview() }
    }
    @ViewBuilder private func kindBadge(_ item: CaptureItem) -> some View {
        if item.kind == .recording, let seconds = item.duration {
            Text(verbatim: Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
        } else { Text(item.kind.label) }
    }
    private func select(_ id: String) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.shift), let anchor,
           let start = store.filteredItems.firstIndex(where: { $0.id == anchor }),
           let end = store.filteredItems.firstIndex(where: { $0.id == id }) {
            let range = Set(store.filteredItems[min(start, end)...max(start, end)].map(\.id))
            if modifiers.contains(.command) { store.selection.formUnion(range) } else { store.selection = range }
        } else if modifiers.contains(.command) {
            if !store.selection.insert(id).inserted { store.selection.remove(id) }
            anchor = id
        } else { store.selection = [id]; anchor = id }
        navigationID = id
    }
    private func moveSelection(_ direction: MoveCommandDirection) {
        let items = store.filteredItems
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == navigationID } ?? items.firstIndex { store.selection.contains($0.id) }
        let increment = direction == .left || direction == .up ? -1 : 1
        let next = min(max((index ?? -increment) + increment, 0), items.count - 1)
        select(items[next].id)
    }
    @ViewBuilder private func actions(_ item: CaptureItem) -> some View {
        Button("Open capture") { store.selection = [item.id]; Task { await store.open(item) } }
        Button("Quick Look") { if !store.selection.contains(item.id) { store.selection = [item.id] }; preview() }
        Divider()
        Button("Copy") { if !store.selection.contains(item.id) { store.selection = [item.id] }; Task { await store.copySelection() } }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(store.selection.contains(item.id) ? store.selectedItems.map(\.url) : [item.url]) }
        Button("Rename…") { store.selection = [item.id]; beginRename() }
        ShareLink(items: store.selection.contains(item.id) ? store.selectedItems.map(\.url) : [item.url]) { Text("Share") }
        Divider()
        Button("Move to Trash", role: .destructive) { if !store.selection.contains(item.id) { store.selection = [item.id] }; requestTrash() }
    }
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let item = store.selectedItems.first {
                    LibraryThumbnail(item: item, thumbnails: store.thumbnails).frame(height: 200)
                    Text(verbatim: item.title).font(Theme.Font.title).textSelection(.enabled)
                    if store.selection.count > 1 { Text("\(store.selection.count) selected").font(Theme.Font.data) }
                    Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.m) {
                        fact("Created", item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        fact("Size", ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
                        if let size = item.pixelSize { fact("Dimensions", "\(Int(size.width)) × \(Int(size.height))") }
                        if item.kind == .recording { fact("Duration", item.duration.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) } ?? String(localized: "Unknown")) }
                        fact("Location", item.origin == .clipboardCache ? String(localized: "Copied capture") : String(localized: "Saved file"))
                    }.font(Theme.Font.data)
                    Text(verbatim: FolderPicker.display(item.url.path)).font(Theme.Font.dataSmall).foregroundStyle(Theme.Palette.ink3.color).textSelection(.enabled)
                    HStack {
                        Button("Open capture") { Task { await store.open(item) } }
                        Button("Quick Look") { preview() }
                    }
                    HStack {
                        Button("Copy") { Task { await store.copySelection() } }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(store.selectedItems.map(\.url)) }
                    }
                    HStack {
                        Button("Rename…") { beginRename() }.disabled(store.selection.count != 1)
                        ShareLink(items: store.selectedItems.map(\.url)) { Text("Share") }
                    }
                    Button("Move to Trash", role: .destructive) { requestTrash() }
                } else { Text("Select a capture to see its details.").foregroundStyle(Theme.Palette.ink3.color) }
            }.padding(Theme.Space.l).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Theme.Palette.surface.color)
    }
    private func fact(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow { Text(title).foregroundStyle(Theme.Palette.ink3.color); Text(verbatim: value).textSelection(.enabled) }
    }
    private func preview() { quickLookURL = store.selectedItems.first?.url }
    private func requestTrash() { if !store.selection.isEmpty { confirmsTrash = true } }
    private func beginRename() {
        guard store.selection.count == 1, let item = store.selectedItems.first else { return }
        renameName = item.title; renameID = item.id
    }
    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Rename capture").font(Theme.Font.title)
            TextField("New name", text: $renameName).textFieldStyle(.roundedBorder).onSubmit { finishRename() }
            HStack { Spacer(); Button("Cancel") { renameID = nil }.keyboardShortcut(.cancelAction)
                Button("Rename") { finishRename() }.keyboardShortcut(.defaultAction).disabled(!LibraryFiles.validName(renameName)) }
        }.padding(Theme.Space.xl).frame(width: 360)
    }
    private func finishRename() {
        guard let id = renameID else { return }
        let name = renameName; renameID = nil
        Task { do { try await store.rename(id, to: name) } catch { store.issue = error.localizedDescription } }
    }
}

extension CaptureItem.Kind {
    var label: LocalizedStringKey {
        switch self { case .screenshot: "Screenshot"; case .scrollCapture: "Scroll capture"; case .recording: "Recording" }
    }
}

private struct LibraryThumbnail: View {
    let item: CaptureItem
    let thumbnails: LibraryThumbnails
    @State private var image: CGImage?
    @State private var isLoading = true
    var body: some View {
        ZStack {
            Theme.Palette.well.color
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit().padding(Theme.Space.xs) }
            else if isLoading { ProgressView().controlSize(.small) }
            else { Image(systemName: item.kind == .recording ? "film" : "photo.badge.exclamationmark")
                    .font(Theme.Font.title).foregroundStyle(Theme.Palette.ink3.color).accessibilityLabel(Text("Thumbnail unavailable")) }
        }.clipShape(.rect(cornerRadius: Theme.Radius.thumb))
            .task(id: item) {
                image = nil; isLoading = true
                let decoded = await thumbnails.image(for: item)
                guard !Task.isCancelled else { return }
                image = decoded; isLoading = false
            }
    }
}
