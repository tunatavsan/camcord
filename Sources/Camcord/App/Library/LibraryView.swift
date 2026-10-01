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
        VStack(alignment: .leading, spacing: 0) {
            if !store.items.isEmpty {
                heading.padding(.bottom, Theme.Space.l)
                LibraryFilterBar(items: store.items, filter: $store.filter, search: $store.search)
                    .padding(.bottom, Theme.Library.filterBottom)
            }
            content
        }
        .padding(Theme.Space.xl)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            if store.items.isEmpty { headingControls.padding(Theme.Space.xl) }
        }
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
        .inspector(isPresented: inspectorPresentation) {
            LibraryInspectorView(items: store.selectedItems, thumbnails: store.thumbnails,
                                 copy: copySelection, reveal: revealSelection, rename: beginRename, trash: requestTrash)
                .inspectorColumnWidth(Theme.Library.inspectorWidth)
        }
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
            HStack(spacing: Theme.Space.xs) {
                Text("\(store.items.count) captures")
                Text(verbatim: "· " + ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
            }
            .font(Theme.Font.data).foregroundStyle(Theme.Palette.ink3.color).lineLimit(1)
            Spacer()
            headingControls
        }
    }

    private var headingControls: some View {
        HStack(spacing: Theme.Space.m) {
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

        }
    }
    private var totalBytes: Int64 {
        store.items.reduce(0) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(max(item.byteSize, 0)); return overflow ? .max : sum
        }
    }
    private var groups: [LibraryDateGroup] {
        Dictionary(grouping: store.filteredItems) { Calendar.current.startOfDay(for: $0.createdAt) }
            .sorted { $0.key > $1.key }
            .map { LibraryDateGroup(date: $0.key, title: groupTitle($0.key), items: $0.value) }
    }
    private func groupTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    private var grid: some View {
        LibraryGridContent(groups: groups, newestID: store.items.first?.id, tile: tile)
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
        let age = Date().timeIntervalSince(item.createdAt)
        return LibraryCaptureTile(item: item, thumbnails: store.thumbnails,
                                  isSelected: store.selection.contains(item.id),
                                  isFresh: item.id == store.items.first?.id && age >= 0 && age < Theme.Library.freshSeconds,
                                  select: { select(item.id); hasFocus = true },
                                  open: { Task { await store.open(item) } },
                                  preview: { store.selection = [item.id]; preview() },
                                  actions: { actions(item) })
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
    private func copySelection() { Task { await store.copySelection() } }
    private func revealSelection() { NSWorkspace.shared.activateFileViewerSelecting(store.selectedItems.map(\.url)) }
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
