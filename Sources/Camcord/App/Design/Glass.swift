import AppKit
import SwiftUI

// Glass, the system's own only (docs/design/native/SPEC.md §2.6, K2.1): a tint on
// `glassEffect` / `NSGlassEffectView`, never a blur plus a translucent fill. One glass layer per
// region (K2.2). Reduce Transparency gets the opaque solid tokens (K2.7); system glass also
// handles it by itself, the solid fill is for the shapes we tint.

/// The glass a piece of chrome wears.
enum GlassStyle: CaseIterable, Sendable {
    /// Toolbar groups, the menu-bar panel, the card, the toast, the scroll HUD, menus, first run.
    case chrome
    /// Chrome that is itself a control (a key, a chip): the glass answers the pointer.
    case chromeInteractive
    /// The recording hub and the countdown: dark in both appearances, over any wallpaper.
    case hud

    var tint: ThemeColor {
        switch self {
        case .chrome, .chromeInteractive: Theme.Palette.glassTintChrome
        case .hud: Theme.Palette.glassTintHUD
        }
    }

    /// What Reduce Transparency shows instead.
    var solid: ThemeColor {
        switch self {
        case .chrome, .chromeInteractive: Theme.Palette.glassSolidChrome
        case .hud: Theme.Palette.glassSolidHUD
        }
    }

    var glass: Glass {
        let tinted = Glass.regular.tint(tint.color)
        return self == .chromeInteractive ? tinted.interactive() : tinted
    }

    /// HUD glass is dark whatever the app's appearance is.
    var forcedScheme: ColorScheme? { self == .hud ? .dark : nil }
}

private struct CamcordGlassModifier<S: Shape>: ViewModifier {
    let style: GlassStyle
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background(shape.fill(style.solid.color))
            } else {
                content.glassEffect(style.glass, in: shape)
            }
        }
        .environment(\.colorScheme, style.forcedScheme ?? colorSchemeFallback)
    }

    @Environment(\.colorScheme) private var colorSchemeFallback
}

extension View {
    /// Wears Camcord glass in `shape` (system Liquid Glass with a token tint; the solid token
    /// under Reduce Transparency).
    func camcordGlass(_ style: GlassStyle = .chrome, in shape: some Shape) -> some View {
        modifier(CamcordGlassModifier(style: style, shape: shape))
    }
}

// MARK: - Signature frame

/// Camcord's signature (owner, 2026-10-02): every glass surface wears the same clear, light
/// rim. It is NOT an appearance colour: the rim reads the same in light and dark, like the
/// edge of a pane of glass. A faint outer line keeps it separate from a light backdrop.
enum SignatureFrame {
    static let rim = NSColor(white: 1, alpha: 0.42)
    static let edge = NSColor(white: 0, alpha: 0.10)
    static let width: CGFloat = 1
}

private struct SignatureFrameModifier: ViewModifier {
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: SignatureFrame.edge), lineWidth: SignatureFrame.width)
                RoundedRectangle(cornerRadius: max(0, cornerRadius - SignatureFrame.width), style: .continuous)
                    .strokeBorder(Color(nsColor: SignatureFrame.rim), lineWidth: SignatureFrame.width)
                    .padding(SignatureFrame.width)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Draws the signature rim around a glass surface whose corners are `cornerRadius`.
    func signatureFrame(cornerRadius: CGFloat) -> some View {
        modifier(SignatureFrameModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - AppKit twin

extension NSGlassEffectView {
    /// An `NSGlassEffectView` wearing a Camcord glass style. Put content in `contentView`,
    /// never as a sibling behind the glass.
    static func camcord(_ style: GlassStyle, cornerRadius: CGFloat) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.applyCamcord(style, cornerRadius: cornerRadius)
        return view
    }

    func applyCamcord(_ style: GlassStyle, cornerRadius: CGFloat) {
        self.style = .regular
        tintColor = style.tint.ns
        self.cornerRadius = cornerRadius
        if style == .hud { appearance = NSAppearance(named: .darkAqua) }
    }
}

// MARK: - Window backdrops

/// Passive window surfaces beneath pages. The window is one untinted system Liquid Glass
/// surface; thumbnails, previews, video and form cards keep their own opaque surfaces above it.
/// The sidebar case supports legacy clients.
enum WindowBackdrop: CaseIterable, Sendable {
    /// A legacy whole-height sidebar backdrop.
    case sidebar
    /// The whole window as one glass frame, sidebar and module together.
    case content

    /// Legacy material metadata. The content pane is rendered with `glassEffect` instead.
    var material: NSVisualEffectView.Material {
        switch self {
        case .sidebar: .sidebar
        case .content: .underWindowBackground
        }
    }

    /// Legacy tint metadata; the content pane never applies a tint.
    var tint: ThemeColor {
        switch self {
        case .sidebar: Theme.Palette.backdropSidebar
        case .content: Theme.Palette.backdropContent
        }
    }

    /// Reduce Transparency uses the same opaque panel colour in both window regions.
    var solid: ThemeColor {
        Theme.Palette.glassSolidSidebar
    }
}

private struct WindowBackdropView: NSViewRepresentable {
    let backdrop: WindowBackdrop

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        // Active even while the window is not key: the frost must not flatten to grey.
        view.state = .active
        view.material = backdrop.material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = backdrop.material
    }
}

private struct WindowBackdropModifier: ViewModifier {
    let backdrop: WindowBackdrop
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            Group {
                if backdrop == .content {
                    // The whole app sits in ONE framed glass panel, the one the native sidebar
                    // wore (owner, 2026-10-02): inset from the window's edge, its rim visible,
                    // the sidebar and the module inside it with no gap between them.
                    ZStack {
                        Color(nsColor: .windowBackgroundColor)
                        Group {
                            if reduceTransparency {
                                RoundedRectangle(cornerRadius: Theme.Radius.floating, style: .continuous)
                                    .fill(backdrop.solid.color)
                            } else {
                                WindowFrameGlass()
                            }
                        }
                        .signatureFrame(cornerRadius: Theme.Radius.floating)
                        .padding(Theme.Navigation.nativeSidebarInset)
                    }
                } else if reduceTransparency {
                    backdrop.solid.color
                } else {
                    ZStack {
                        WindowBackdropView(backdrop: backdrop)
                        backdrop.tint.color
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

}

/// The app's frame: one system glass panel whose rim is the visible border.
private struct WindowFrameGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.tintColor = nil
        view.cornerRadius = Theme.Radius.floating
        view.contentView = NSView()
        view.setAccessibilityHidden(true)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {}
}

extension View {
    /// Places a passive system backdrop behind this view (see `WindowBackdrop`).
    func windowBackdrop(_ backdrop: WindowBackdrop) -> some View {
        modifier(WindowBackdropModifier(backdrop: backdrop))
    }
}
