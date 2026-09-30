import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StudioLayersInspector: View {
    let document: StudioLayerDocument
    let locked: Bool
    private var selected: StudioLayer? { document.layers.first { $0.id == document.selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Layers").font(Theme.Font.bodyStrong)
                Spacer()
                Text(verbatim: "\(document.layers.count)/24").font(Theme.Font.dataSmall).foregroundStyle(Theme.Palette.ink3.color)
                Menu {
                    Button("Text", systemImage: "textformat") { document.addText(String(localized: "Text")) }
                    Button("Image…", systemImage: "photo") { importImage(kind: .image) }
                    Button("Logo…", systemImage: "seal") { importImage(kind: .logo) }
                } label: { Label("Add layer", systemImage: "plus") }.labelStyle(.iconOnly)
                    .disabled(locked || document.layers.count >= 24)
            }
            if document.layers.isEmpty {
                Text("Add text, an image or a logo. Layers are included in the recording.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink3.color)
            } else {
                VStack(spacing: 4) {
                    // The top row is visually frontmost; the backend array is back-to-front.
                    ForEach(Array(document.layers.reversed())) { layer in layerRow(layer) }
                }
            }
            if document.isRasterizing { Label("Updating layers…", systemImage: "arrow.triangle.2.circlepath").font(Theme.Font.caption) }
            if let issue = document.issue {
                Text(issue.studioMessage).font(Theme.Font.caption).foregroundStyle(Theme.Palette.warn.color)
                Button("Dismiss") { document.dismissIssue() }.controlSize(.small)
            }
            if let selected { layerControls(selected) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !locked, !urls.isEmpty, document.layers.count < 24 else { return false }
            Task { for url in urls.prefix(24 - document.layers.count) { await document.importImage(from: url) } }
            return true
        }
    }
    private func layerRow(_ layer: StudioLayer) -> some View {
        HStack(spacing: 8) {
            Button { document.selectedID = layer.id } label: {
                HStack(spacing: 8) {
                    Image(systemName: layer.kind == .text ? "textformat" : layer.kind == .logo ? "seal" : "photo")
                    Text(verbatim: layer.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.buttonStyle(.plain)
            Button { document.update(layer.id) { $0.isVisible.toggle() } } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
            }.buttonStyle(.plain).help(Text(layer.isVisible ? LocalizedStringResource("Hide layer") : LocalizedStringResource("Show layer")))
                .accessibilityLabel(Text(layer.isVisible ? LocalizedStringResource("Hide layer") : LocalizedStringResource("Show layer")))
        }
        .font(Theme.Font.body).padding(8)
        .background(document.selectedID == layer.id ? Theme.Palette.selectionStrong.color : Theme.Palette.hover.color,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .disabled(locked)
    }
    private func layerControls(_ layer: StudioLayer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Layer name", text: value(layer, \.name))
            if layer.kind == .text {
                TextField("Text", text: value(layer, \.text), axis: .vertical).lineLimit(2...5)
                Stepper(value: style(layer, \.fontSize), in: 8...256, step: 2) { Text("Text size: \(Int(layer.textStyle.fontSize))") }
                    .help(Text("Text size is relative to a 1920×1080 reference canvas and scales to fit the layer bounds."))
                Toggle("Bold", isOn: style(layer, \.bold))
                ColorPicker("Text color", selection: textColor(layer), supportsOpacity: true)
            }
            scalar("Opacity", value: value(layer, \.opacity), upper: 1)
            scalar("Left", value: rect(layer, \.origin.x), upper: max(0, 1 - layer.rect.width))
            scalar("Top", value: rect(layer, \.origin.y), upper: max(0, 1 - layer.rect.height))
            scalar("Bounds width", value: rect(layer, \.size.width), upper: max(0.01, 1 - layer.rect.minX), lower: 0.01)
            scalar("Bounds height", value: rect(layer, \.size.height), upper: max(0.01, 1 - layer.rect.minY), lower: 0.01)
            Text("Images and logos keep their proportions and are centered inside these bounds. Text fits from the top left.")
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink3.color)
            HStack {
                Button("Move forward", systemImage: "arrow.up") { move(layer, by: 1) }.labelStyle(.iconOnly)
                    .disabled(document.layers.last?.id == layer.id)
                Button("Move backward", systemImage: "arrow.down") { move(layer, by: -1) }.labelStyle(.iconOnly)
                    .disabled(document.layers.first?.id == layer.id)
                Spacer()
                Button("Delete layer", systemImage: "trash", role: .destructive) { document.remove(layer.id) }.labelStyle(.iconOnly)
            }
            Text("Drag the selected layer on the stage or adjust its position here.")
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink3.color)
        }.disabled(locked).font(Theme.Font.body)
    }
    private func move(_ layer: StudioLayer, by amount: Int) {
        guard let index = document.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        document.move(layer.id, to: index + amount)
    }
    private func importImage(kind: StudioLayer.Kind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await document.importImage(from: url, kind: kind) }
        }
    }
    private func value<Value>(_ layer: StudioLayer, _ key: WritableKeyPath<StudioLayer, Value>) -> Binding<Value> {
        Binding(get: { document.layers.first { $0.id == layer.id }?[keyPath: key] ?? layer[keyPath: key] },
                set: { value in document.update(layer.id) { $0[keyPath: key] = value } })
    }
    private func style<Value>(_ layer: StudioLayer, _ key: WritableKeyPath<StudioTextStyle, Value>) -> Binding<Value> {
        Binding(get: { document.layers.first { $0.id == layer.id }?.textStyle[keyPath: key] ?? layer.textStyle[keyPath: key] },
                set: { value in document.update(layer.id) { $0.textStyle[keyPath: key] = value } })
    }
    private func rect(_ layer: StudioLayer, _ key: WritableKeyPath<CGRect, CGFloat>) -> Binding<Double> {
        Binding(get: { Double(document.layers.first { $0.id == layer.id }?.rect[keyPath: key] ?? layer.rect[keyPath: key]) },
                set: { value in document.update(layer.id) { $0.rect[keyPath: key] = CGFloat(value) } })
    }
    private func scalar(_ title: LocalizedStringResource, value: Binding<Double>, upper: Double, lower: Double = 0) -> some View {
        HStack {
            Text(title).frame(width: 52, alignment: .leading)
            Slider(value: value, in: lower...max(lower, upper), step: 0.01).accessibilityLabel(Text(title))
            Text(verbatim: "\(Int(value.wrappedValue * 100))%").font(Theme.Font.dataSmall).frame(width: 38, alignment: .trailing)
        }.font(Theme.Font.caption)
    }
    private func textColor(_ layer: StudioLayer) -> Binding<Color> {
        Binding(get: { Color(.sRGB, red: layer.textStyle.red, green: layer.textStyle.green, blue: layer.textStyle.blue, opacity: layer.textStyle.alpha) }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            document.update(layer.id) {
                $0.textStyle.red = rgb.redComponent; $0.textStyle.green = rgb.greenComponent
                $0.textStyle.blue = rgb.blueComponent; $0.textStyle.alpha = rgb.alphaComponent
            }
        })
    }
}
