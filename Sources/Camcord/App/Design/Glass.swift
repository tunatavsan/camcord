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

/// Passive window surfaces beneath pages. Content uses untinted system Liquid Glass;
/// thumbnails, previews, video and form cards keep their own opaque surfaces above it.
/// The native split-view sidebar supplies its own glass; the sidebar case supports legacy clients.
enum WindowBackdrop: CaseIterable, Sendable {
    /// A legacy whole-height sidebar backdrop.
    case sidebar
    /// An inset content pane matching the native sidebar's glass family.
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
                    Group {
                        if reduceTransparency {
                            contentShape.fill(backdrop.solid.color)
                        } else {
                            PaneGlass()
                        }
                    }
                    .padding(Theme.Navigation.nativeSidebarInset)
                } else if reduceTransparency {
                    backdrop.solid.color
                } else {
                    ZStack {
                        WindowBackdropView(backdrop: backdrop)
                        backdrop.tint.color
                    }
                }
            }
            // Preserve the split view's horizontal reservation while extending beneath the titlebar.
            .ignoresSafeArea(edges: backdrop == .content ? [.top, .bottom] : .all)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var contentShape: ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(Theme.Navigation.nativeSidebarInset)))
    }
}

/// A window pane's glass, made exactly like the native floating sidebar's: one untinted AppKit
/// `NSGlassEffectView` with nothing behind it in the window. Measured over the same backdrop it
/// renders identically to the sidebar, in light and dark (2026-10-02); SwiftUI's `glassEffect`
/// over a large area, or any frost under the glass, does not.
struct PaneGlass: NSViewRepresentable {
    var cornerRadius: CGFloat = Theme.Radius.floating

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.tintColor = nil
        view.cornerRadius = cornerRadius
        view.contentView = NSView()
        view.setAccessibilityHidden(true)
        view.adoptSidebarGlass()
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        if view.cornerRadius != cornerRadius { view.cornerRadius = cornerRadius }
    }
}

extension NSGlassEffectView {
    /// The variant the native floating sidebar's glass carries (read from the live view tree,
    /// macOS 26): a panel glass without the lensing seams a large plain glass bends across its
    /// interior, which shimmer as the window moves. Not public API, so it is applied only when
    /// the view still answers to it; otherwise the glass stays plain.
    func adoptSidebarGlass() {
        guard responds(to: NSSelectorFromString("set_variant:")) else { return }
        setValue(16, forKey: "_variant")
        if responds(to: NSSelectorFromString("set_adaptiveAppearance:")) { setValue(1, forKey: "_adaptiveAppearance") }
    }
}

extension View {
    /// Places a passive system backdrop behind this view (see `WindowBackdrop`).
    func windowBackdrop(_ backdrop: WindowBackdrop) -> some View {
        modifier(WindowBackdropModifier(backdrop: backdrop))
    }
}
