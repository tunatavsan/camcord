import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorStyleCapsule: View {
    @Bindable var session: EditorSession
    @State private var showsPrivacy = false
    private var tool: EditorTool { session.selectedAnnotation?.kind ?? session.tool }
    private var style: EditorStyle { session.selectedAnnotation?.style ?? session.style }
    private var usesColor: Bool { [.arrow, .rectangle, .text, .highlight, .step].contains(tool) }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if usesColor {
                EditorColorSwatches(color: style.color, set: setColor, session: session)
                Divider().frame(height: Theme.Space.l)
            }
            if [.arrow, .rectangle].contains(tool) {
                EditorPresetGroup(values: tool == .arrow ? Theme.Editor.arrowWidths : Theme.Editor.lineWidths, value: style.lineWidth, title: "Line width", set: setLineWidth)
            }
            if tool == .text || tool == .step {
                EditorPresetGroup(values: Theme.Editor.textSizes, value: style.fontSize, title: "Text size", set: setTextSize)
            }
            if tool == .text {
                Toggle("Text background", isOn: Binding(get: { style.textBackground }, set: { value in change { $0.textBackground = value } }))
                    .toggleStyle(.button).help("Text background")
            }
            if tool == .blur || tool == .pixelate {
                EditorPresetGroup(values: Theme.Editor.effectSizes, value: style.effectSize, title: "Effect size", set: setEffectSize)
            }
            if session.selectedAnnotation?.kind == .text || session.selectedAnnotation?.kind == .step {
                Button("Edit annotation", systemImage: "text.cursor") { session.showsAnnotationEditor.toggle() }
                    .popover(isPresented: $session.showsAnnotationEditor) { EditorSelectedContent(session: session).padding(Theme.Space.l) }
            }
            if [.redact, .blur, .pixelate].contains(tool) {
                Button("Redaction information", systemImage: "info.circle") { showsPrivacy.toggle() }
                    .popover(isPresented: $showsPrivacy) {
                        Text("Use solid redact for secrets. Blur and pixelate only obscure the image visually.")
                            .font(Theme.Font.body).padding(Theme.Space.l).frame(width: Theme.Editor.inspectorWidth)
                    }
            }
            if tool == .redact {
                Button("Find sensitive text", systemImage: "text.viewfinder", action: session.findSensitiveText)
                    .disabled(session.isFindingText)
            }
            if session.selectedAnnotation != nil {
                Button("Delete annotation", systemImage: "trash", action: session.deleteSelected)
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .camcordGlass(.chrome, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Annotation style")
    }
    private func change(_ edit: (inout EditorStyle) -> Void) {
        edit(&session.style)
        session.updateSelected { edit(&$0.style) }
        session.rememberStyle()
    }
    private func setColor(_ value: EditorColor) {
        session.chooseColor(value)
        session.updateSelected { $0.style.color = value }
        session.rememberStyle()
    }
    private func setLineWidth(_ value: Double) {
        session.chooseLineWidth(value)
        session.updateSelected { $0.style.lineWidth = value }
        session.rememberStyle()
    }
    private func setTextSize(_ value: Double) { change { $0.fontSize = value } }
    private func setEffectSize(_ value: Double) { change { $0.effectSize = value } }
}

private struct EditorColorSwatches: View {
    let color: EditorColor
    let set: (EditorColor) -> Void
    let session: EditorSession
    private let labels: [LocalizedStringResource] = ["Red", "Black", "White", "Yellow", "Green", "Blue", "Purple"]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Theme.Editor.swatches.indices, id: \.self) { index in
                let value = Theme.Editor.swatches[index]
                Button { set(value) } label: {
                    Circle().fill(Color(cgColor: value.cgColor))
                        .frame(width: Theme.Editor.swatchSize, height: Theme.Editor.swatchSize)
                        .overlay { Circle().strokeBorder(Theme.Palette.hairlineStrong.color, lineWidth: 1) }
                        .padding(Theme.Space.xs)
                        .background(color == value ? Theme.Palette.selectionStrong.color : .clear, in: Circle())
                        .frame(width: Theme.Editor.hitSize, height: Theme.Editor.hitSize)
                }
                .accessibilityLabel(Text(labels[index]))
                .accessibilityValue(color == value ? Text("Selected") : Text("Not selected"))
            }
            EditorNativeColorWell(color: color, set: set, session: session)
                .frame(width: Theme.Editor.hitSize, height: Theme.Editor.hitSize)
        }
    }
}

private struct EditorNativeColorWell: NSViewRepresentable {
    let color: EditorColor
    let set: (EditorColor) -> Void
    let session: EditorSession?
    func makeCoordinator() -> Coordinator { Coordinator(set: set, session: session) }
    func makeNSView(context: Context) -> NSColorWell {
        let well = EditorContinuousColorWell(frame: CGRect(x: 0, y: 0, width: Theme.Editor.hitSize, height: Theme.Editor.hitSize))
        well.session = context.coordinator.session
        well.colorWellStyle = .minimal
        well.supportsAlpha = true
        well.target = context.coordinator
        well.action = #selector(Coordinator.changed(_:))
        well.setAccessibilityLabel(String(localized: "Custom color"))
        return well
    }
    func updateNSView(_ well: NSColorWell, context: Context) {
        context.coordinator.set = set
        (well as? EditorContinuousColorWell)?.session = session
        well.color = NSColor(cgColor: color.cgColor) ?? .clear
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSColorWell, context: Context) -> CGSize? {
        CGSize(width: Theme.Editor.hitSize, height: Theme.Editor.hitSize)
    }
    @MainActor final class Coordinator: NSObject {
        var set: (EditorColor) -> Void
        weak var session: EditorSession?
        init(set: @escaping (EditorColor) -> Void, session: EditorSession?) { self.set = set; self.session = session }
        @objc func changed(_ well: NSColorWell) {
            guard let rgb = well.color.usingColorSpace(.sRGB) else { return }
            set(EditorColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent))
        }
    }
}

private struct EditorPresetGroup: View {
    let values: [Double]
    let value: Double
    let title: LocalizedStringResource
    let set: (Double) -> Void
    var body: some View {
        HStack(spacing: Theme.Space.xs / 2) {
            ForEach(Array(zip(["S", "M", "L"], values)), id: \.0) { label, preset in
                Button { set(preset) } label: {
                    Text(verbatim: label).font(Theme.Font.captionStrong)
                        .frame(width: Theme.Editor.hitSize, height: Theme.Editor.presetHeight)
                        .background(value == preset ? Theme.Palette.selectionStrong.color : .clear, in: Capsule())
                }
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(verbatim: "\(Int(preset)) pt"))
                .help(String(localized: title) + " · \(Int(preset)) pt")
            }
        }
    }
}

private struct EditorSelectedContent: View {
    @Bindable var session: EditorSession
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if session.selectedAnnotation?.kind == .text {
                EditorAnnotationText(session: session).frame(height: 72)
            } else if session.selectedAnnotation?.kind == .step {
                Stepper("Step number", value: Binding(get: { session.selectedAnnotation?.stepNumber ?? 1 }, set: { value in
                    session.updateSelected { $0.stepNumber = value }
                }), in: 1...9999)
                Text(verbatim: String(session.selectedAnnotation?.stepNumber ?? 1)).font(Theme.Font.data)
            }
        }.frame(width: Theme.Editor.inspectorWidth)
    }
}

struct EditorSensitiveSummary: View {
    @Bindable var session: EditorSession
    var body: some View {
        if session.isFindingText {
            ProgressView("Finding sensitive text…").controlSize(.small)
                .padding(Theme.Space.m).camcordGlass(.chrome, in: Capsule())
        } else if !session.suggestions.isEmpty {
            HStack(spacing: Theme.Space.m) {
                Text(verbatim: "\(session.suggestions.count) " + String(localized: "found")).font(Theme.Font.data)
                Button("Redact all") {
                    session.selectedSuggestions = Set(session.suggestions.map(\.id)); session.applySuggestions()
                }.buttonStyle(.borderless)
                Button("Dismiss", systemImage: "xmark") { session.dismissSuggestions() }.labelStyle(.iconOnly)
            }.padding(Theme.Space.m).camcordGlass(.chrome, in: Capsule())
        } else if session.hasScannedSensitiveText {
            Text("No email or phone suggestions found. Review the image for other sensitive information.")
                .font(Theme.Font.caption).padding(Theme.Space.m).camcordGlass(.chrome, in: Capsule())
        }
    }
}

struct EditorZoomCapsule: View {
    @Bindable var session: EditorSession
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Button { session.fitZoom = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless).help("Fit").accessibilityLabel("Fit")
            .onDrag { dragProvider() }
            Divider().frame(height: Theme.Space.l)
            Menu {
                Button("Fit") { session.fitZoom = true }
                Button("Actual pixels") { session.fitZoom = false; session.zoom = session.actualPixelZoom }
                Divider()
                Button("Zoom in") { session.changeZoom(by: 1.25) }
                Button("Zoom out") { session.changeZoom(by: 0.8) }
            } label: {
                Text(verbatim: "\(session.displayedZoomPercent)%").font(Theme.Font.data)
            }.menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
        .camcordGlass(.chrome, in: Capsule())
        .help(Text(verbatim: session.document.map { "\($0.source.width) × \($0.source.height) px" } ?? ""))
    }
    private func dragProvider() -> NSItemProvider {
        let provider = NSItemProvider(), id = session.document?.id, revision = session.revision
        provider.suggestedName = String(localized: "Edited screenshot.png")
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [.openInPlace], visibility: .all) { completion in
            Task { @MainActor in
                do {
                    guard session.document?.id == id, session.revision == revision else { throw EditorError.stale }
                    completion(try await session.temporaryExport(), true, nil)
                } catch { completion(nil, false, error) }
            }
            return nil
        }
        return provider
    }
}

struct EditorEmptyView: View {
    let services: AppServices?
    let open: () -> Void
    private var recent: [CaptureItem] { Array(services?.library.items.filter { $0.kind != .recording }.prefix(6) ?? []) }
    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            VStack(spacing: Theme.Space.l) {
                Image(systemName: "photo.badge.plus").font(Theme.Font.display).foregroundStyle(Theme.Palette.ink3.color)
                Text("Drop an image to edit").font(Theme.Font.title)
                HStack(spacing: Theme.Space.m) {
                    Button("Capture Region", systemImage: "viewfinder") { services?.capture(.region) }
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderedProminent).tint(Theme.Palette.ink.color).disabled(services == nil)
                    Button("Open image…", action: open).buttonStyle(.borderless)
                }
            }
            .padding(Theme.Space.xxl)
            .frame(maxWidth: Theme.Editor.inspectorWidth * 2)
            .background(Theme.Palette.hover.color, in: RoundedRectangle(cornerRadius: Theme.Radius.box))
            .overlay { RoundedRectangle(cornerRadius: Theme.Radius.box).strokeBorder(Theme.Palette.hairlineStrong.color, style: StrokeStyle(lineWidth: 1, dash: [4, 4])) }
            if let services, !recent.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(recent) { item in EditorRecentThumbnail(item: item, library: services.library) }
                    }
                }.frame(maxWidth: Theme.Editor.inspectorWidth * 2)
            }
        }.padding(Theme.Space.xl).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EditorRecentThumbnail: View {
    let item: CaptureItem
    let library: LibraryStore
    @State private var image: CGImage?
    var body: some View {
        Button { Task { await library.open(item) } } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.thumb).fill(Theme.Palette.surface.color)
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            }
            .frame(width: Theme.Editor.thumbnailHeight * 1.4, height: Theme.Editor.thumbnailHeight)
            .clipShape(.rect(cornerRadius: Theme.Radius.thumb))
            .overlay { RoundedRectangle(cornerRadius: Theme.Radius.thumb).strokeBorder(Theme.Palette.hairline.color, lineWidth: 1) }
        }.buttonStyle(.plain).help(item.title).accessibilityLabel(Text(verbatim: item.title))
        .task(id: item.id) { image = await library.thumbnails.image(for: item, edge: 240) }
    }
}

@MainActor private final class EditorContinuousColorWell: NSColorWell {
    weak var session: EditorSession?
    override func activate(_ exclusive: Bool) { if !isActive { session?.beginContinuousEdit() }; super.activate(exclusive) }
    override func deactivate() { if isActive { session?.endContinuousEdit() }; super.deactivate() }
}
