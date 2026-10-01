import SwiftUI
import AppKit
import QuickLookUI
import UniformTypeIdentifiers

extension EditorTool {
    var keyEquivalent: String {
        switch self {
        case .select: "V"; case .arrow: "A"; case .rectangle: "R"; case .text: "T"
        case .highlight: "H"; case .step: "N"; case .blur: "B"; case .pixelate: "P"
        case .redact: "X"; case .crop: "C"
        }
    }
    var title: LocalizedStringResource {
        switch self {
        case .select: "Select"; case .arrow: "Arrow"; case .rectangle: "Rectangle"; case .text: "Text"
        case .highlight: "Highlight"; case .step: "Numbered step"; case .blur: "Blur"
        case .pixelate: "Pixelate"; case .redact: "Solid redact"; case .crop: "Crop"
        }
    }
}
extension EditorBackground.Preset {
    var title: LocalizedStringResource {
        switch self { case .none: "No background"; case .paper: "Paper"; case .graphite: "Graphite"; case .gradient: "Gradient" }
    }
}

struct ScreenshotEditorView: View {
    @Environment(\.screenshotEditorSession) private var session
    @Environment(\.appServices) private var services
    var body: some View {
        ZStack {
            if let session { EditorWorkspace(session: session, services: services) }
            else { EditorEmptyView(services: nil, open: {}) }
        }
        .font(Theme.Font.body)
        .foregroundStyle(Theme.Palette.ink.color)
    }
}

struct EditorWorkspace: View {
    @Bindable var session: EditorSession
    let services: AppServices?
    @State private var quickLook = EditorQuickLook()
    @State private var activity = EditorWorkspaceActivity()
    @Environment(\.mainWindowModuleActive) private var moduleActive
    @Environment(\.mainWindowLifecycle) private var lifecycle
    @State private var styleCapsuleHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isActive: Bool { moduleActive && (lifecycle?.allowsLivePreview ?? true) }
    private var inspectorPresentation: Binding<Bool> {
        Binding(get: { isActive && session.showsBackgroundInspector }, set: { if isActive { session.showsBackgroundInspector = $0 } })
    }
    private var showsStyle: Bool { session.selectedAnnotation != nil || session.tool != .select && session.tool != .crop }

    var body: some View {
        ZStack {
            if session.document == nil {
                EditorEmptyView(services: services, open: { if session.isActive { session.chooseImage() } })
            } else {
                EditorCanvas(session: session, fitTopClearance: showsStyle ? Theme.Space.m + styleCapsuleHeight + Theme.Space.s : 0)
                    .overlay(alignment: .top) {
                        VStack(spacing: Theme.Space.s) {
                            if showsStyle {
                                EditorStyleCapsule(session: session)
                                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                                        if styleCapsuleHeight != height { styleCapsuleHeight = height }
                                    }
                            }
                            EditorSensitiveSummary(session: session)
                        }
                        .padding(Theme.Space.m)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        EditorZoomCapsule(session: session).padding(Theme.Space.l)
                    }
            }
            if session.isLoading || session.isRendering {
                ProgressView().controlSize(.small)
                    .padding(Theme.Space.m)
                    .camcordGlass(.chrome, in: Capsule())
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(!isActive)
        .allowsHitTesting(isActive)
        .accessibilityHidden(!isActive)
        .inspector(isPresented: inspectorPresentation) {
            EditorBackgroundInspector(session: session)
                .inspectorColumnWidth(Theme.Editor.inspectorWidth)
        }
        .toolbar {
            if isActive {
                ToolbarItemGroup(placement: .navigation) {
                    Button("Undo", systemImage: "arrow.uturn.backward", action: { if session.isActive { session.undo() } })
                        .disabled(!session.canUndo).keyboardShortcut("z", modifiers: .command)
                    Button("Redo", systemImage: "arrow.uturn.forward", action: { if session.isActive { session.redo() } })
                        .disabled(!session.canRedo).keyboardShortcut("z", modifiers: [.command, .shift])
                }
                ToolbarItem(placement: .principal) { EditorToolCapsule(session: session) }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Background and frame", systemImage: "square.on.square") { guard session.isActive else { return }; session.showsBackgroundInspector.toggle() }
                        .disabled(session.document == nil)
                    Button { activity.perform { _ = await session.copy() } } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .labelStyle(.titleAndIcon).buttonStyle(.glassProminent).tint(Theme.Palette.ink.color)
                        .keyboardShortcut("c", modifiers: .command).disabled(unavailable)
                    Button("Save…", systemImage: "square.and.arrow.down", action: { if session.isActive { session.chooseExport() } })
                        .keyboardShortcut("s", modifiers: .command).disabled(unavailable)
                    EditorShareButton(session: session).frame(width: Theme.Editor.toolWidth, height: Theme.Editor.toolHeight)
                    Menu {
                        Button("Open image…", systemImage: "folder", action: { if session.isActive { session.chooseImage() } })
                        Divider()
                        Button("Pin to Screen", systemImage: "pin") { activity.perform { await session.pin() } }.disabled(unavailable)
                        Button("Quick Look", systemImage: "eye", action: showQuickLook).disabled(unavailable)
                        Button("Show in Finder", systemImage: "folder") {
                            if session.isActive, let url = session.document?.sourceURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }.disabled(session.document?.sourceURL == nil)
                        Divider()
                        Button("Find sensitive text", systemImage: "text.viewfinder", action: { if session.isActive { session.findSensitiveText() } })
                            .disabled(unavailable || session.isFindingText)
                        Button("Reset crop") {
                            if session.isActive, let bounds = session.document?.bounds { session.edit { $0.crop = bounds } }
                        }.disabled(unavailable)
                        if let hex = session.pixelHex {
                            Button("Copy pixel color") { if session.isActive { session.copyHex(hex) } }
                                .keyboardShortcut("c", modifiers: [.command, .shift])
                        }
                    } label: { Label("More", systemImage: "ellipsis") }
                }
            }
        }
        .labelStyle(.iconOnly)
        .onChange(of: isActive, initial: true) { _, active in
            activity.update(active: active, session: session, library: services?.library) {
                await services?.openLatestEditorCaptureIfEmpty()
            }
            if !active { quickLook.close() }
        }
        .onDisappear { activity.update(active: false, session: session); quickLook.close() }
        .alert("The edit could not be completed", isPresented: Binding(get: { isActive && session.error != nil && session.pendingURL == nil && session.pendingCapture == nil }, set: { if isActive && !$0 { session.error = nil } })) {
            Button("Dismiss") { session.error = nil }
        } message: { Text(verbatim: session.error ?? "") }
        .dropDestination(for: URL.self) { urls, _ in
            guard isActive, session.isActive, let url = urls.first, ["png", "jpg", "jpeg", "tif", "tiff"].contains(url.pathExtension.lowercased()) else { return false }
            activity.perform { await session.open(url: url) }; return true
        }
    }
    private var unavailable: Bool { !isActive || session.document == nil || session.isExporting }
    private func showQuickLook() {
        guard isActive, session.isActive else { return }
        activity.perform {
            do {
                let url = try await session.temporaryExport()
                guard !Task.isCancelled, session.isActive else { return }
                quickLook.show(url)
            }
            catch { session.error = error.localizedDescription }
        }
    }
}

struct EditorToolCapsule: View {
    @Bindable var session: EditorSession
    var body: some View {
        HStack(spacing: Theme.Space.xs / 2) {
            ForEach(EditorTool.allCases, id: \.self) { tool in
                Button { guard session.isActive else { return }; session.tool = tool } label: {
                    Image(systemName: tool.symbol)
                        .font(Theme.Editor.symbol)
                        .frame(width: Theme.Editor.toolWidth, height: Theme.Editor.toolHeight)
                        .background(session.tool == tool ? Theme.Palette.selectionStrong.color : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(String(localized: tool.title) + " · " + tool.keyEquivalent)
                .accessibilityLabel(Text(tool.title))
                .accessibilityValue(session.tool == tool ? Text("Selected") : Text("Not selected"))
            }
        }
        .disabled(session.document == nil || session.isExporting)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Annotation tools")
    }
}
@MainActor final class EditorQuickLook: NSObject, @MainActor QLPreviewPanelDataSource {
    private var url: URL?
    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self; panel.reloadData(); panel.orderFrontRegardless()
    }
    func close() { guard QLPreviewPanel.sharedPreviewPanelExists() else { url = nil; return }; if let panel = QLPreviewPanel.shared(), panel.dataSource === self { panel.orderOut(nil); panel.dataSource = nil }; url = nil }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url as NSURL? }
}

struct EditorShareButton: NSViewRepresentable {
    let session: EditorSession
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: String(localized: "Share"))!, target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.isBordered = false; button.contentTintColor = Theme.Palette.ink.ns
        button.setAccessibilityLabel(String(localized: "Share")); return button
    }
    func updateNSView(_ view: NSButton, context: Context) { context.coordinator.session = session; view.isEnabled = session.isActive && session.document != nil && !session.isExporting }
    static func dismantleNSView(_ view: NSButton, coordinator: Coordinator) {
        coordinator.cancelSharing(); view.target = nil; view.action = nil; view.isEnabled = false
    }
    @MainActor final class Coordinator: NSObject {
        var session: EditorSession
        private var shareTask: Task<Void, Never>?
        private var shareGeneration = UUID()
        init(session: EditorSession) { self.session = session }
        func cancelSharing() {
            shareGeneration = UUID(); shareTask?.cancel(); shareTask = nil
        }
        isolated deinit { shareTask?.cancel() }
        @objc func share(_ button: NSButton) {
            guard session.isActive else { return }
            cancelSharing()
            let generation = shareGeneration, currentSession = session
            shareTask = Task { [weak self, weak button] in
                defer { if self?.shareGeneration == generation { self?.shareTask = nil } }
                do {
                    let url = try await currentSession.temporaryExport()
                    guard !Task.isCancelled, self?.shareGeneration == generation,
                          self?.session === currentSession, currentSession.isActive, let button else { return }
                    NSSharingServicePicker(items: [url]).show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                } catch {
                    guard !Task.isCancelled, self?.shareGeneration == generation, currentSession.isActive else { return }
                    currentSession.error = error.localizedDescription
                }
            }
        }
    }
}

/// Installed at the main-window host so pending opens are immediately reviewable in any module.
struct EditorOpeningConfirmationModifier: ViewModifier {
    let session: EditorSession?
    func body(content: Content) -> some View {
        let capture = session?.pendingCapture, url = session?.pendingURL
        return content.confirmationDialog("Open another image?", isPresented: Binding(get: { session?.pendingCapture != nil || session?.pendingURL != nil }, set: { if !$0 { session?.cancelPending() } })) {
            Button("Discard edits and open", role: .destructive) { Task { await session?.discardAndOpen(capture: capture, url: url) } }
            Button("Cancel", role: .cancel) { session?.cancelPending() }
        } message: { Text("Your current edits have not been exported.") }
    }
}

/// Retained view state and cancellable presentation work have different lifetimes.
@MainActor final class EditorWorkspaceActivity {
    private var active: Bool?
    private var autoOpenTask: Task<Void, Never>?
    private var actionTasks: [UUID: Task<Void, Never>] = [:]
    private let visibility = LibraryVisibilityLease()
    func update(active: Bool, session: EditorSession, library: LibraryStore? = nil,
                openLatest: @escaping @MainActor () async -> Void = {}) {
        guard self.active != active else { return }
        self.active = active
        for task in actionTasks.values { task.cancel() }; actionTasks.removeAll()
        autoOpenTask?.cancel(); autoOpenTask = nil; visibility.release()
        if !active { session.stop(); return }
        session.resume()
        guard session.document == nil, let library else { return }
        let token = visibility.acquire(library)
        autoOpenTask = Task { [weak self] in
            defer { self?.visibility.release(ifCurrent: token) }
            await library.refresh()
            guard !Task.isCancelled, self?.active == true, session.document == nil else { return }
            await openLatest()
        }
    }
    @discardableResult func perform(_ action: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard active == true else { return nil }
        let id = UUID()
        actionTasks[id] = Task { [weak self] in
            defer { self?.actionTasks.removeValue(forKey: id) }
            guard !Task.isCancelled, self?.active == true else { return }
            await action()
        }
        return actionTasks[id]
    }
    func waitForAutoOpen() async { await autoOpenTask?.value }
    isolated deinit { autoOpenTask?.cancel(); for task in actionTasks.values { task.cancel() } }
}
