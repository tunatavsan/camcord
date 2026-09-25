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
