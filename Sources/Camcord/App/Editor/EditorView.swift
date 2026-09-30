import SwiftUI
import AppKit
import QuickLookUI
import UniformTypeIdentifiers

extension EditorTool {
    var keyEquivalent: String { switch self { case .select: "V"; case .arrow: "A"; case .rectangle: "R"; case .text: "T"; case .highlight: "H"; case .step: "S"; case .blur: "B"; case .pixelate: "P"; case .redact: "X"; case .crop: "C" } }
    var title: LocalizedStringResource {
        switch self {
        case .select: "Select"; case .arrow: "Arrow"; case .rectangle: "Rectangle"; case .text: "Text"
        case .highlight: "Highlight"; case .step: "Numbered step"; case .blur: "Blur"; case .pixelate: "Pixelate"; case .redact: "Solid redact"; case .crop: "Crop"
        }
    }
}
extension EditorBackground.Preset {
    var title: LocalizedStringResource { switch self { case .none: "No background"; case .paper: "Paper"; case .graphite: "Graphite"; case .gradient: "Gradient" } }
}

/// Argument-free module content; a missing environment service is a safe empty page.
struct ScreenshotEditorView: View {
    @Environment(\.screenshotEditorSession) private var session
    var body: some View {
        Group {
            if let session { EditorWorkspace(session: session) }
            else { EditorEmptyView(open: {}, enabled: false) }
        }
        .font(Theme.Font.body).foregroundStyle(Theme.Palette.ink.color)
        .background(Theme.Palette.window.color)
    }
}
private struct EditorEmptyView: View {
    let open: () -> Void
    var enabled = true
    var body: some View {
        EmptyState(title: "Edit a screenshot") {
            VStack(spacing: Theme.Space.l) {
                Text("Open or drop a PNG, JPEG or TIFF image to annotate, crop and redact it.").foregroundStyle(Theme.Palette.ink2.color)
                Button("Open image…", systemImage: "folder", action: open).buttonStyle(.borderedProminent).tint(Theme.Palette.ink.color).disabled(!enabled)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EditorWorkspace: View {
    @Bindable var session: EditorSession
    @State private var quickLook = EditorQuickLook()
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if session.document == nil { EditorEmptyView(open: session.chooseImage) }
            else {
                HStack(spacing: 0) {
                    ZStack {
                        EditorCanvas(session: session)
                        if session.isRendering { ProgressView().padding(Theme.Space.l).background(Theme.Palette.surface.color, in: RoundedRectangle(cornerRadius: Theme.Radius.box)) }
                    }
                    inspector.frame(width: 250)
                }
            }
            status
        }
        .onAppear { session.resume() }
        .onDisappear { session.stop(); quickLook.close() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, ["png", "jpg", "jpeg", "tif", "tiff"].contains(url.pathExtension.lowercased()) else { return false }
            Task { await session.open(url: url) }; return true
        }
    }
    private var toolbar: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Button("Open image…", systemImage: "folder", action: session.chooseImage)
                Button("Undo", systemImage: "arrow.uturn.backward", action: session.undo).disabled(!session.canUndo)
                Button("Redo", systemImage: "arrow.uturn.forward", action: session.redo).disabled(!session.canRedo)
                Spacer()
                Button("Fit", action: { session.fitZoom = true })
                Button("Actual pixels", action: { session.fitZoom = false; session.zoom = 1 })
                Button { session.fitZoom = false; session.zoom = max(0.02, session.canvasZoom / 1.25) } label: { Label("Zoom out", systemImage: "minus.magnifyingglass") }
                Button { session.fitZoom = false; session.zoom = min(16, session.canvasZoom * 1.25) } label: { Label("Zoom in", systemImage: "plus.magnifyingglass") }
                Divider().frame(height: 20)
                Button { Task { await session.copy() } } label: { Label("Copy", systemImage: "doc.on.doc") }.disabled(session.document == nil || session.isExporting)
                Button("Export…", systemImage: "square.and.arrow.up", action: session.chooseExport).disabled(session.document == nil || session.isExporting)
            }
            .labelStyle(.iconOnly)
            HStack(spacing: Theme.Space.xs) {
                ForEach(EditorTool.allCases, id: \.self) { tool in
                    Button { session.tool = tool } label: { Image(systemName: tool.symbol).frame(width: 26, height: 26) }
                        .background(session.tool == tool ? Theme.Palette.selectionStrong.color : Theme.Palette.hover.color, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                        .help(Text(tool.title)).accessibilityLabel(Text(tool.title)).accessibilityValue(session.tool == tool ? Text("Selected") : Text("Not selected"))
                }
                Spacer(minLength: Theme.Space.s)
                Button { Task { await session.pin() } } label: { Label("Pin", systemImage: "pin") }
                Button { Task { do { quickLook.show(try await session.temporaryExport()) } catch { session.error = error.localizedDescription } } } label: { Label("Quick Look", systemImage: "eye") }
                EditorShareButton(session: session).frame(width: 26, height: 26)
                Image(systemName: "hand.draw").frame(width: 26, height: 26).help("Drag edited image")
                    .accessibilityLabel("Drag edited image")
                    .onDrag {
                        let provider = NSItemProvider(), id = session.document?.id, revision = session.revision
                        provider.suggestedName = String(localized: "Edited screenshot.png")
                        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [.openInPlace], visibility: .all) { completion in
                            Task { @MainActor in do {
                                guard session.document?.id == id, session.revision == revision else { throw EditorError.stale }
                                completion(try await session.temporaryExport(), true, nil)
                            } catch { completion(nil, false, error) } }
                            return nil
                        }
                        return provider
                    }
            }.disabled(session.document == nil || session.isExporting)
        }
        .buttonStyle(.borderless).font(Theme.Font.body).padding(Theme.Space.m)
        .camcordGlass(.chrome, in: Rectangle())
    }
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack {
                    Text(session.tool.title).font(Theme.Font.title)
                    Spacer()
                    Text(verbatim: session.tool.keyEquivalent).font(Theme.Font.data).padding(Theme.Space.xs)
                        .background(Theme.Palette.raised.color, in: RoundedRectangle(cornerRadius: Theme.Radius.badge)).accessibilityHidden(true)
                }
                if session.tool == .redact || session.tool == .blur || session.tool == .pixelate {
                    Text("Use solid redact for secrets. Blur and pixelate only obscure the image visually.").font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink2.color)
                }
                if let hex = session.pixelHex, let point = session.pixelLocation {
                    Text("Last inspected pixel").font(Theme.Font.caption.weight(.semibold))
                    HStack { Text(hex).font(Theme.Font.data); Spacer(); Button { session.copyHex(hex) } label: { Label("Copy pixel color", systemImage: "doc.on.doc") }.labelStyle(.iconOnly).keyboardShortcut("c", modifiers: [.command, .shift]) }
                    Text("x \(Int(point.x)) · y \(Int(point.y))").font(Theme.Font.data).foregroundStyle(Theme.Palette.ink2.color)
                }
                styleControls
                if let annotation = session.selectedAnnotation {
                    Divider()
                    Text("Selected annotation").font(Theme.Font.caption.weight(.semibold))
                    if annotation.kind == .text {
                        TextField("Annotation text", text: Binding(get: { session.selectedAnnotation?.text ?? "" }, set: { value in session.updateSelected { $0.text = value } })).textFieldStyle(.roundedBorder)
                    }
                    if annotation.kind == .step {
                        Stepper("Step number", value: Binding(get: { session.selectedAnnotation?.stepNumber ?? 1 }, set: { value in session.updateSelected { $0.stepNumber = value } }), in: 1...9999)
                        Text(String(annotation.stepNumber)).font(Theme.Font.data)
                    }
                    Button("Delete annotation", systemImage: "trash", action: session.deleteSelected)
                }
                Divider()
                backgroundControls
                Divider()
                Button { session.findSensitiveText() } label: { Label("Find sensitive text", systemImage: "text.viewfinder") }.disabled(session.isFindingText)
                if session.isFindingText { ProgressView() }
                Text("Looks for email addresses and phone numbers on this image. Review suggestions before applying.").font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink2.color)
                if session.hasScannedSensitiveText && session.suggestions.isEmpty { Text("No email or phone suggestions found. Review the image for other sensitive information.").font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink2.color) }
                ForEach(Array(session.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    Toggle(isOn: Binding(get: { session.selectedSuggestions.contains(suggestion.id) }, set: { selected in if selected { session.selectedSuggestions.insert(suggestion.id) } else { session.selectedSuggestions.remove(suggestion.id) } })) {
                        HStack { Text(suggestion.kind == .email ? "Email address" : "Phone number"); Text("\(index + 1)").font(Theme.Font.data) }
                    }
                }
                if !session.suggestions.isEmpty { Button("Apply solid redactions", action: session.applySuggestions).disabled(session.selectedSuggestions.isEmpty) }
            }.padding(Theme.Space.l)
        }.background(Theme.Palette.surface.color)
    }
    private var styleControls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ColorPicker("Annotation color", selection: Binding(get: { Color(cgColor: session.selectedAnnotation?.style.color.cgColor ?? session.style.color.cgColor) }, set: { color in
                guard let rgba = NSColor(color).usingColorSpace(.sRGB) else { return }
                let value = EditorColor(red: rgba.redComponent, green: rgba.greenComponent, blue: rgba.blueComponent, alpha: rgba.alphaComponent)
                session.style.color = value; session.updateSelected { $0.style.color = value }; session.rememberStyle()
            }))
            editorSlider("Line width", value: Binding(get: { session.selectedAnnotation?.style.lineWidth ?? session.style.lineWidth }, set: { value in session.style.lineWidth = value; session.updateSelected { $0.style.lineWidth = value }; session.rememberStyle() }), range: 1...32)
            editorSlider("Text size", value: Binding(get: { session.selectedAnnotation?.style.fontSize ?? session.style.fontSize }, set: { value in session.style.fontSize = value; session.updateSelected { $0.style.fontSize = value }; session.rememberStyle() }), range: 8...120)
            editorSlider("Effect size", value: Binding(get: { session.selectedAnnotation?.style.effectSize ?? session.style.effectSize }, set: { value in session.style.effectSize = value; session.updateSelected { $0.style.effectSize = value }; session.rememberStyle() }), range: 2...80)
        }
    }
    private var backgroundControls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Background and frame").font(Theme.Font.caption.weight(.semibold))
            Picker("Background", selection: Binding(get: { session.document?.edits.background.preset ?? .none }, set: { value in session.edit { $0.background.preset = value } })) {
                ForEach(EditorBackground.Preset.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            ColorPicker("Background color", selection: Binding(get: { Color(cgColor: session.document?.edits.background.color.cgColor ?? EditorColor.paper.cgColor) }, set: { color in
                guard let rgba = NSColor(color).usingColorSpace(.sRGB) else { return }
                let value = EditorColor(red: rgba.redComponent, green: rgba.greenComponent, blue: rgba.blueComponent, alpha: rgba.alphaComponent)
                session.edit { $0.background.color = value }
            }))
            editorSlider("Padding", value: Binding(get: { session.document?.edits.background.padding ?? 40 }, set: { value in session.edit { $0.background.padding = value } }), range: 0...160)
            editorSlider("Corner radius", value: Binding(get: { session.document?.edits.background.cornerRadius ?? 12 }, set: { value in session.edit { $0.background.cornerRadius = value } }), range: 0...80)
            editorSlider("Frame width", value: Binding(get: { session.document?.edits.background.frameWidth ?? 0 }, set: { value in session.edit { $0.background.frameWidth = value } }), range: 0...24)
            Toggle("Shadow", isOn: Binding(get: { session.document?.edits.background.shadow ?? true }, set: { value in session.edit { $0.background.shadow = value } }))
            Button("Reset crop") { guard let bounds = session.document?.bounds else { return }; session.edit { $0.crop = bounds } }
        }
    }
    private func editorSlider(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue)) px").font(Theme.Font.data) }
            Slider(value: value, in: range, step: 1).accessibilityLabel(Text(title)).tint(Theme.Palette.ink.color)
        }
    }
    private var status: some View {
        HStack(spacing: Theme.Space.m) {
            if let document = session.document { Text("\(document.source.width) × \(document.source.height) px").font(Theme.Font.data) }
            if session.hasUnsavedEdits { Text("Unexported edits").font(Theme.Font.caption) }
            Spacer()
            if let error = session.error { Text(error).font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink2.color); Button("Dismiss") { session.error = nil } }
            if session.isExporting || session.isLoading { ProgressView().controlSize(.small) }
        }.padding(Theme.Space.s).background(Theme.Palette.surface.color)
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

private struct EditorShareButton: NSViewRepresentable {
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
