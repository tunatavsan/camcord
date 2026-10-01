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
    @State private var libraryToken: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if session.document == nil {
                EditorEmptyView(services: services, open: session.chooseImage)
            } else {
                EditorCanvas(session: session)
                    .overlay(alignment: .top) {
                        VStack(spacing: Theme.Space.s) {
                            if session.selectedAnnotation != nil || session.tool != .select && session.tool != .crop {
                                EditorStyleCapsule(session: session)
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
        .onAppear { session.resume() }
        .onDisappear { session.stop() }
        .inspector(isPresented: $session.showsBackgroundInspector) {
            EditorBackgroundInspector(session: session)
                .inspectorColumnWidth(Theme.Editor.inspectorWidth)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Undo", systemImage: "arrow.uturn.backward", action: session.undo)
                    .disabled(!session.canUndo).keyboardShortcut("z", modifiers: .command)
                Button("Redo", systemImage: "arrow.uturn.forward", action: session.redo)
                    .disabled(!session.canRedo).keyboardShortcut("z", modifiers: [.command, .shift])
            }
            ToolbarItem(placement: .principal) { EditorToolCapsule(session: session) }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Background and frame", systemImage: "square.on.square") { session.showsBackgroundInspector.toggle() }
                    .disabled(session.document == nil)
                Button { Task { await session.copy() } } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .labelStyle(.titleAndIcon).buttonStyle(.glassProminent).tint(Theme.Palette.ink.color)
                    .keyboardShortcut("c", modifiers: .command).disabled(unavailable)
                Button("Save…", systemImage: "square.and.arrow.down", action: session.chooseExport)
                    .keyboardShortcut("s", modifiers: .command).disabled(unavailable)
                EditorShareButton(session: session).frame(width: Theme.Editor.toolWidth, height: Theme.Editor.toolHeight)
                Menu {
                    Button("Open image…", systemImage: "folder", action: session.chooseImage)
                    Divider()
                    Button("Pin to Screen", systemImage: "pin") { Task { await session.pin() } }.disabled(unavailable)
                    Button("Quick Look", systemImage: "eye", action: showQuickLook).disabled(unavailable)
                    Button("Show in Finder", systemImage: "folder") {
                        if let url = session.document?.sourceURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }.disabled(session.document?.sourceURL == nil)
                    Divider()
                    Button("Find sensitive text", systemImage: "text.viewfinder", action: session.findSensitiveText)
                        .disabled(unavailable || session.isFindingText)
                    Button("Reset crop") {
                        if let bounds = session.document?.bounds { session.edit { $0.crop = bounds } }
                    }.disabled(unavailable)
                    if let hex = session.pixelHex {
                        Button("Copy pixel color") { session.copyHex(hex) }
                            .keyboardShortcut("c", modifiers: [.command, .shift])
                    }
                } label: { Label("More", systemImage: "ellipsis") }
            }
        }
        .labelStyle(.iconOnly)
        .onAppear { session.resume() }
        .onDisappear {
            session.stop(); quickLook.close()
            if let libraryToken { services?.library.releaseVisibility(libraryToken); self.libraryToken = nil }
        }
        .task {
            guard session.document == nil, let services else { return }
            libraryToken = services.library.acquireVisibility()
            await services.library.refresh()
            guard !Task.isCancelled else { return }
            await services.openLatestEditorCaptureIfEmpty()
            if session.document != nil, let libraryToken {
                services.library.releaseVisibility(libraryToken); self.libraryToken = nil
            }
        }
        .alert("The edit could not be completed", isPresented: Binding(get: { session.error != nil && session.pendingURL == nil && session.pendingCapture == nil }, set: { if !$0 { session.error = nil } })) {
            Button("Dismiss") { session.error = nil }
        } message: { Text(verbatim: session.error ?? "") }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, ["png", "jpg", "jpeg", "tif", "tiff"].contains(url.pathExtension.lowercased()) else { return false }
            Task { await session.open(url: url) }; return true
        }
    }
    private var unavailable: Bool { session.document == nil || session.isExporting }
    private func showQuickLook() {
        Task {
            do { quickLook.show(try await session.temporaryExport()) }
            catch { session.error = error.localizedDescription }
        }
    }
}

struct EditorToolCapsule: View {
    @Bindable var session: EditorSession
    var body: some View {
        HStack(spacing: Theme.Space.xs / 2) {
            ForEach(EditorTool.allCases, id: \.self) { tool in
                Button { session.tool = tool } label: {
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
    func updateNSView(_ view: NSButton, context: Context) { context.coordinator.session = session; view.isEnabled = session.document != nil && !session.isExporting }
    @MainActor final class Coordinator: NSObject {
        var session: EditorSession
        init(session: EditorSession) { self.session = session }
        @objc func share(_ button: NSButton) {
            Task { do { let url = try await session.temporaryExport(); NSSharingServicePicker(items: [url]).show(relativeTo: button.bounds, of: button, preferredEdge: .minY) } catch { session.error = error.localizedDescription } }
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
