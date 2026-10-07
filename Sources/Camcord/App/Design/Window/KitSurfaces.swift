import SwiftUI

// The window is built like the menu-bar panel: one frosted tray, and glass cells floating on
// it, 8 pt apart and 8 pt from the edge. Nothing is written on the tray itself.

private struct KitCell: ViewModifier {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.camcordOpaqueMaterialPreview) private var opaquePreview

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency || opaquePreview {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Theme.Palette.glassSolidSidebar.color)
                } else {
                    PaneGlass(cornerRadius: radius).allowsHitTesting(false)
                }
            }
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
    }
}

private struct KitTray: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.camcordOpaqueMaterialPreview) private var opaquePreview

    func body(content: Content) -> some View {
        content.background {
            Group {
                if reduceTransparency || opaquePreview {
                    Theme.Palette.glassSolidChrome.color
                } else {
                    TrayBlur()
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    /// One glass cell: the panel's pane glass in its 18 pt continuous corner, or the opaque
    /// stand-in under Reduce Transparency.
    func kitCell(radius: CGFloat = Theme.Window.Layout.cellRadius) -> some View {
        modifier(KitCell(radius: radius))
    }

    /// The frosted tray the cells float on.
    func kitTray() -> some View { modifier(KitTray()) }
}
