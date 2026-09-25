import AppKit
import SwiftUI

/// The pre-Graphite-II style names, now a thin alias layer onto `Theme` (docs/RUN-UI-2.md K3).
/// Only surfaces that are not restyled yet read these; each restyle moves its surface to
/// `Theme` directly, and the whole layer is deleted in P6.4.
enum CamcordStyle {
    static let accent = Theme.Palette.legacyAccent.color
    static let recording = Theme.Palette.record.color

    static let innerBorder = Color.primary.opacity(0.09)
    static let quietFill = Color.primary.opacity(0.055)

    enum Radius {
        static let surface: CGFloat = Theme.Radius.floating
        static func inset(by inset: CGFloat) -> CGFloat { Theme.Radius.inset(surface, by: inset) }
        static let control: CGFloat = Theme.Radius.well
    }
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
