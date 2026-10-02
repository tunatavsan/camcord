import AppKit
import SwiftUI

struct EditorBackgroundInspector: View {
    @Bindable var session: EditorSession
    private var background: EditorBackground { session.document?.edits.background ?? EditorBackground() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                Text("Background and frame").font(Theme.Font.bodyStrong)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Theme.Space.s) {
                    ForEach(EditorBackground.Preset.allCases, id: \.self) { preset in
                        EditorBackgroundPreset(preset: preset, color: background.color, selected: background.preset == preset) {
                            session.edit { $0.background.preset = preset }
                        }
                    }
                }
                ColorPicker("Background color", selection: Binding(get: { Color(cgColor: background.color.cgColor) }, set: { color in
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                    session.edit { $0.background.color = EditorColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent) }
                }))
                EditorBackgroundValue(title: "Padding", value: background.padding, presets: [0, 16, 32, 64], range: 0...160) { value in
                    session.edit { $0.background.padding = value }
                }
                EditorBackgroundValue(title: "Corner radius", value: background.cornerRadius, presets: [0, 8, 12, 24], range: 0...80) { value in
                    session.edit { $0.background.cornerRadius = value }
                }
                Picker("Image corners", selection: Binding(get: { background.imageCorners }, set: { value in session.edit { $0.background.imageCorners = value } })) {
                    Text("Auto").tag(EditorBackground.ImageCorners.auto)
                    Text("Square").tag(EditorBackground.ImageCorners.square)
                    Text("Rounded").tag(EditorBackground.ImageCorners.rounded)
                }.pickerStyle(.segmented)
                EditorBackgroundValue(title: "Frame width", value: background.frameWidth, presets: [0, 1, 2, 4], range: 0...24) { value in
                    session.edit { $0.background.frameWidth = value }
                }
                Toggle("Shadow", isOn: Binding(get: { background.shadow }, set: { value in session.edit { $0.background.shadow = value } }))
                    .toggleStyle(.switch).tint(Theme.Palette.ink.color)
                Button("Reset crop") {
                    if let bounds = session.document?.bounds { session.edit { $0.crop = bounds } }
                }.buttonStyle(.borderless)
            }.padding(Theme.Space.l)
        }
        // On the window's glass, like the sidebar: no opaque slab of its own.
        .scrollContentBackground(.hidden)
        .disabled(session.document == nil)
    }
}

private struct EditorBackgroundPreset: View {
    let preset: EditorBackground.Preset
    let color: EditorColor
    let selected: Bool
    let select: () -> Void
    var body: some View {
        Button(action: select) {
            VStack(spacing: Theme.Space.s) {
                ZStack {
                    previewBackground
                    RoundedRectangle(cornerRadius: Theme.Radius.key)
                        .fill(Theme.Palette.ink.color)
                        .frame(width: Theme.Editor.thumbnailHeight, height: Theme.Editor.thumbnailHeight / 2)
                        .overlay { Image(systemName: "photo").foregroundStyle(Theme.Palette.onInk.color) }
                }
                .frame(height: Theme.Editor.thumbnailHeight)
                .clipShape(.rect(cornerRadius: Theme.Radius.thumb))
                .overlay { RoundedRectangle(cornerRadius: Theme.Radius.thumb).strokeBorder(selected ? Theme.Palette.ink.color : Theme.Palette.hairline.color, lineWidth: selected ? 2 : 1) }
                Text(preset.title).font(Theme.Font.caption)
            }
        }.buttonStyle(.plain).accessibilityValue(selected ? Text("Selected") : Text("Not selected"))
    }
    @ViewBuilder private var previewBackground: some View {
        switch preset {
        case .none:
            Canvas { context, size in
                let cell: CGFloat = 8
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.90)))
                var squares = Path()
                for row in 0..<Int(ceil(size.height / cell)) {
                    for column in 0..<Int(ceil(size.width / cell)) where (row + column).isMultiple(of: 2) {
                        squares.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                    }
                }
                context.fill(squares, with: .color(Color(white: 0.72)))
            }
        case .paper: Color(cgColor: color.cgColor)
        case .graphite: Color(cgColor: Theme.Editor.backgroundGraphite.cgColor)
        case .gradient: LinearGradient(colors: [Color(cgColor: color.cgColor), Color(cgColor: Theme.Editor.backgroundGradientEnd.cgColor)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

private struct EditorBackgroundValue: View {
    let title: LocalizedStringResource
    let value: Double
    let presets: [Double]
    let range: ClosedRange<Double>
    let set: (Double) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text(title).font(Theme.Font.captionStrong)
                Spacer()
                TextField("Pixels", text: Binding(get: { String(Int(value)) }, set: { text in
                    if let number = Double(text), number.isFinite { set(min(range.upperBound, max(range.lowerBound, number))) }
                }))
                .font(Theme.Font.data).multilineTextAlignment(.trailing)
                .frame(width: Theme.Editor.thumbnailHeight)
                Text(verbatim: "px").font(Theme.Font.data).foregroundStyle(Theme.Palette.ink3.color)
            }
            HStack(spacing: Theme.Space.xs) {
                ForEach(presets, id: \.self) { preset in
                    Button { set(preset) } label: {
                        Text(verbatim: String(Int(preset))).font(Theme.Font.dataSmall)
                            .frame(maxWidth: .infinity).frame(height: Theme.Editor.presetHeight)
                            .background(value == preset ? Theme.Palette.selectionStrong.color : Theme.Palette.hover.color, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}
