import AppKit
import SwiftUI

enum CamcordStyle {
    static let accent = Color(red: 0.35, green: 0.43, blue: 0.86)
    static let recording = Color(red: 0.94, green: 0.30, blue: 0.33)

    static let innerBorder = Color.primary.opacity(0.09)
    static let quietFill = Color.primary.opacity(0.055)
}

/// Shared native material used by the panel and Settings. The visual-effect view is
/// always active so a menu-bar popover keeps its intended material while its app is not key.
struct CamcordMaterial: View {
    let material: NSVisualEffectView.Material

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.camcordOpaqueMaterialPreview) private var opaquePreview

    init(material: NSVisualEffectView.Material = .popover) {
        self.material = material
    }

    var body: some View {
        if reduceTransparency || opaquePreview {
            Color(nsColor: .windowBackgroundColor)
        } else {
            NativeVisualEffect(material: material)
                .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.18))
        }
    }
}

private struct CamcordOpaqueMaterialPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

private struct CamcordDesignPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var camcordOpaqueMaterialPreview: Bool {
        get { self[CamcordOpaqueMaterialPreviewKey.self] }
        set { self[CamcordOpaqueMaterialPreviewKey.self] = newValue }
    }

    var camcordDesignPreview: Bool {
        get { self[CamcordDesignPreviewKey.self] }
        set { self[CamcordDesignPreviewKey.self] = newValue }
    }
}

private struct NativeVisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
    }
}
