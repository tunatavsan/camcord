import AppKit
import SwiftUI

// Camcord's design tokens (docs/design/native/SPEC.md §2, docs/RUN-UI-2.md K1–K3). Colour, type,
// spacing, radius and motion live here and nowhere else: every surface reads these names, and
// DesignTokenLiteralTests fails on a literal colour, font size or duration in the files that
// consume them. Palette and type from Console, shape and spacing from Graphite, motion precise.

enum Theme {}

// MARK: - Colour

/// One colour token: its value in the dark and light appearances and their high-contrast
/// twins. It resolves itself against the drawing appearance, in SwiftUI and AppKit alike.
struct ThemeColor: Sendable {
    struct RGBA: Equatable, Sendable {
        let red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat

        init(_ hex: UInt32, alpha: CGFloat = 1) {
            red = CGFloat((hex >> 16) & 0xFF) / 255
            green = CGFloat((hex >> 8) & 0xFF) / 255
            blue = CGFloat(hex & 0xFF) / 255
            self.alpha = alpha
        }

        var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

        /// Two-digit hex per channel, plus the alpha as a percentage when it is not opaque.
        var hexString: String {
            let hex = String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()),
                             Int((blue * 255).rounded()))
            return alpha < 1 ? "\(hex) \(Int((alpha * 100).rounded()))%" : hex
        }

        /// WCAG relative luminance, for the contrast floor (BRIEF §7.10).
        var luminance: CGFloat {
            func linear(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// This colour composited over an opaque `base`.
        func over(_ base: RGBA) -> RGBA {
            RGBA(red: red * alpha + base.red * (1 - alpha), green: green * alpha + base.green * (1 - alpha),
                 blue: blue * alpha + base.blue * (1 - alpha), alpha: 1)
        }

        private init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
            self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        }

        /// WCAG contrast ratio between two opaque colours.
        static func contrast(_ a: RGBA, _ b: RGBA) -> CGFloat {
            let (l1, l2) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
            return (l1 + 0.05) / (l2 + 0.05)
        }
    }

    enum Variant: String, CaseIterable, Sendable { case dark, light, highContrastDark, highContrastLight }

    let name: String
    let dark: RGBA
    let light: RGBA
    let highContrastDark: RGBA
    let highContrastLight: RGBA

    /// The dynamic AppKit colour: resolved each time it is drawn, so an appearance change (or
    /// Increase Contrast) repaints it without anyone observing anything. Built once per token.
    let ns: NSColor
    /// The same colour for SwiftUI.
    let color: Color

    init(_ name: String, dark: RGBA, light: RGBA, highContrastDark: RGBA? = nil, highContrastLight: RGBA? = nil) {
        self.name = name
        self.dark = dark
        self.light = light
        self.highContrastDark = highContrastDark ?? dark
        self.highContrastLight = highContrastLight ?? light
        let variants = (dark.nsColor, light.nsColor, self.highContrastDark.nsColor, self.highContrastLight.nsColor)
        let ns = NSColor(name: NSColor.Name("camcord.\(name)")) { appearance in
            switch Self.variant(for: appearance) {
            case .dark: variants.0
            case .light: variants.1
            case .highContrastDark: variants.2
            case .highContrastLight: variants.3
            }
        }
        self.ns = ns
        self.color = Color(nsColor: ns)
    }

    func value(_ variant: Variant) -> RGBA {
        switch variant {
        case .dark: dark
        case .light: light
        case .highContrastDark: highContrastDark
        case .highContrastLight: highContrastLight
        }
    }

    /// Increase Contrast cannot be read from an appearance (measured: the Accessibility
    /// appearances are composites named plain DarkAqua / Aqua), so it comes from the system
    /// setting, or from the live check's in-app override (never the owner's system setting).
    nonisolated(unsafe) static var highContrastOverride: Bool?

    static var increaseContrast: Bool {
        highContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    static func variant(for appearance: NSAppearance, increaseContrast: Bool = ThemeColor.increaseContrast) -> Variant {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        switch (dark, increaseContrast) {
        case (true, true): return .highContrastDark
        case (true, false): return .dark
        case (false, true): return .highContrastLight
        case (false, false): return .light
        }
    }
}

private typealias C = ThemeColor.RGBA

extension Theme {
    /// The palette (SPEC §2.1). No token reads the system accent (K1): selection and "on" are
    /// ink, record red is the only strong colour, ok/warn appear only in meters and permissions.
    enum Palette {
        static let window = ThemeColor("window", dark: C(0x16181B), light: C(0xE3E6EA),
                                       highContrastDark: C(0x0E0F11), highContrastLight: C(0xEEF0F2))
        static let surface = ThemeColor("surface", dark: C(0x1B1E22), light: C(0xECEEF1),
                                        highContrastLight: C(0xF6F7F8))
        static let raised = ThemeColor("raised", dark: C(0x2E333A), light: C(0xD0D5DB),
                                       highContrastDark: C(0x3A4048), highContrastLight: C(0xC3C9D0))
        static let field = ThemeColor("field", dark: C(0x101215), light: C(0xFFFFFF))
        static let hairline = ThemeColor("hairline", dark: C(0x2A2E34), light: C(0xC5CAD1),
                                         highContrastDark: C(0x5A616A), highContrastLight: C(0x7A828C))
        static let hairlineStrong = ThemeColor("hairlineStrong", dark: C(0x3E444C), light: C(0xA3AAB3),
                                               highContrastDark: C(0x8A919A), highContrastLight: C(0x5A616A))
        static let ink = ThemeColor("ink", dark: C(0xE8EAED), light: C(0x14161A),
                                    highContrastDark: C(0xFFFFFF), highContrastLight: C(0x000000))
        static let ink2 = ThemeColor("ink2", dark: C(0xA8AEB6), light: C(0x454B53),
                                     highContrastDark: C(0xC9CED4), highContrastLight: C(0x2B3036))
        static let ink3 = ThemeColor("ink3", dark: C(0x8A919A), light: C(0x596067),
                                     highContrastDark: C(0xB0B6BE), highContrastLight: C(0x3A4047))
        static let onInk = ThemeColor("onInk", dark: C(0x15171A), light: C(0xF4F5F7),
                                      highContrastDark: C(0x000000), highContrastLight: C(0xFFFFFF))
        static let selection = ThemeColor("selection", dark: C(0xE8EAED, alpha: 0.12), light: C(0x14161A, alpha: 0.09),
                                          highContrastDark: C(0xFFFFFF, alpha: 0.22),
                                          highContrastLight: C(0x000000, alpha: 0.18))
        static let selectionStrong = ThemeColor("selectionStrong", dark: C(0xE8EAED, alpha: 0.20),
                                                light: C(0x14161A, alpha: 0.15),
                                                highContrastDark: C(0xFFFFFF, alpha: 0.30),
                                                highContrastLight: C(0x000000, alpha: 0.26))
        static let hover = ThemeColor("hover", dark: C(0xFFFFFF, alpha: 0.05), light: C(0x14181E, alpha: 0.05),
                                      highContrastDark: C(0xFFFFFF, alpha: 0.10),
                                      highContrastLight: C(0x14181E, alpha: 0.10))
        static let pressed = ThemeColor("pressed", dark: C(0xFFFFFF, alpha: 0.09), light: C(0x14181E, alpha: 0.10))
        static let record = ThemeColor("record", dark: C(0xD2343A), light: C(0xD2343A),
                                       highContrastDark: C(0xB8262C), highContrastLight: C(0xB8262C))
        static let recordHover = ThemeColor("recordHover", dark: C(0xE0454B), light: C(0xBA2A30))
        static let onRecord = ThemeColor("onRecord", dark: C(0xFFFFFF), light: C(0xFFFFFF))
        static let ok = ThemeColor("ok", dark: C(0x62B48C), light: C(0x236A4B),
                                   highContrastDark: C(0x7CD0A6), highContrastLight: C(0x17503A))
        static let warn = ThemeColor("warn", dark: C(0xD3A84C), light: C(0x86600E),
                                     highContrastDark: C(0xE8C06A), highContrastLight: C(0x6A4B08))
        static let well = ThemeColor("well", dark: C(0x0A0B0D), light: C(0x222529))
        static let meterOff = ThemeColor("meterOff", dark: C(0x262A30), light: C(0xC6CBD2))
        static let meterLow = ThemeColor("meterLow", dark: C(0xD5D9DE), light: C(0x2C3137))
        static let meterMid = ThemeColor("meterMid", dark: C(0xD3A84C), light: C(0xA07813))
        static let meterHigh = ThemeColor("meterHigh", dark: C(0xE5484D), light: C(0xD2343A))
        /// Tints for system Liquid Glass (Glass.swift); the glass itself is the system's.
        static let glassTintChrome = ThemeColor("glassTintChrome", dark: C(0x1E2126, alpha: 0.40),
                                                light: C(0xECEEF1, alpha: 0.45))
        static let glassTintHUD = ThemeColor("glassTintHUD", dark: C(0x0E0F11, alpha: 0.72),
                                             light: C(0x0E0F11, alpha: 0.72))
        /// The frost dials of the window backdrops (Glass.swift `WindowBackdrop`): a tint over a
        /// behind-window system material. Lower alpha = more desktop through (NOTE-2).
        static let backdropContent = ThemeColor("backdropContent", dark: C(0x16181B, alpha: 0.994),
                                                light: C(0xE3E6EA, alpha: 0.78),
                                                highContrastDark: C(0x0E0F11, alpha: 0.92),
                                                highContrastLight: C(0xEEF0F2, alpha: 0.92))
        static let backdropSidebar = ThemeColor("backdropSidebar", dark: C(0x2E333A, alpha: 0.62),
                                                light: C(0xD8DCE1, alpha: 0.60),
                                                highContrastDark: C(0x2E333A, alpha: 0.88),
                                                highContrastLight: C(0xD8DCE1, alpha: 0.88))
        /// Reduce Transparency: the opaque stand-ins for glass (K2.7).
        static let glassSolidChrome = ThemeColor("glassSolidChrome", dark: C(0x1E2125), light: C(0xECEEF1))
        static let glassSolidSidebar = ThemeColor("glassSolidSidebar", dark: C(0x24282D), light: C(0xD8DCE1))
        static let glassSolidHUD = ThemeColor("glassSolidHUD", dark: C(0x1E2125), light: C(0x1E2125))
        /// Pre-Graphite-II accent, kept ONLY for surfaces not yet restyled (the old panel, the old
        /// Settings window, the hub). Deleted with the CamcordStyle alias layer in P6.4.
        static let legacyAccent = ThemeColor("legacyAccent", dark: C(0x596ED8), light: C(0x596ED8))

        static let all: [ThemeColor] = [
            window, surface, raised, field, hairline, hairlineStrong, ink, ink2, ink3, onInk,
            selection, selectionStrong, hover, pressed, record, recordHover, onRecord, ok, warn, well,
            meterOff, meterLow, meterMid, meterHigh, glassTintChrome, glassTintHUD, backdropContent, backdropSidebar,
            glassSolidChrome, glassSolidSidebar, glassSolidHUD,
        ]
    }
}

// MARK: - Type

extension Theme {
    /// SF Pro Text 11 / 13 / 15 / 20 + one display size; SF Mono tabular for all data (K1, K2.3).
    enum Font {
        static let caption = SwiftUI.Font.system(size: Size.caption)
        static let captionStrong = SwiftUI.Font.system(size: Size.caption, weight: .semibold)
        static let body = SwiftUI.Font.system(size: Size.body)
        static let bodyStrong = SwiftUI.Font.system(size: Size.body, weight: .semibold)
        static let row = SwiftUI.Font.system(size: Size.row)
        static let rowStrong = SwiftUI.Font.system(size: Size.row, weight: .semibold)
        static let sidebarSymbol = SwiftUI.Font.system(size: Navigation.symbolSize, weight: .regular)
        static let sidebarBrand = SwiftUI.Font.system(size: Size.row, weight: .semibold)
        static let sidebarSection = SwiftUI.Font.system(size: Size.caption, weight: .medium)
        static let title = SwiftUI.Font.system(size: Size.title, weight: .semibold)
        static let display = SwiftUI.Font.system(size: Size.display, weight: .semibold)
        static let timecode = SwiftUI.Font.system(size: Size.display, weight: .light, design: .monospaced).monospacedDigit()
        static let countdown = SwiftUI.Font.system(size: Size.countdown, weight: .light, design: .monospaced).monospacedDigit()
        static let data = SwiftUI.Font.system(size: Size.data, design: .monospaced).monospacedDigit()
        static let dataSmall = SwiftUI.Font.system(size: Size.caption, design: .monospaced).monospacedDigit()
        static let dataStrong = SwiftUI.Font.system(size: Size.data, weight: .semibold, design: .monospaced).monospacedDigit()
        /// Tracking for the display size and for uppercase-free section headers.
        static let displayTracking: CGFloat = -0.6
        static let headerTracking: CGFloat = 0.2

        enum Size {
            static let caption: CGFloat = 11
            static let body: CGFloat = 13
            static let row: CGFloat = 15
            static let title: CGFloat = 20
            static let display: CGFloat = 30
            static let data: CGFloat = 12
            static let countdown: CGFloat = 64
        }

        /// AppKit twins, for the hub, the status item and the overlays.
        enum ns {
            static func text(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
                NSFont.systemFont(ofSize: size, weight: weight)
            }
            static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
                NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            }
            static var caption: NSFont { text(Size.caption) }
            static var body: NSFont { text(Size.body) }
            static var bodyStrong: NSFont { text(Size.body, weight: .semibold) }
            static var data: NSFont { NSFont.monospacedSystemFont(ofSize: Size.data, weight: .regular) }
            static var dataStrong: NSFont { NSFont.monospacedSystemFont(ofSize: Size.data, weight: .semibold) }
            static var pill: NSFont { NSFont.monospacedSystemFont(ofSize: Size.caption, weight: .semibold) }
        }
    }
}

// MARK: - Spacing, radius, shadow

extension Theme {
    /// Graphite's scale: 4 · 8 · 12 · 16 · 24 · 32. Content margins are `xl`.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// The inspected Graphite II window shell (`index.html` 138–158).
    enum Navigation {
        // CSS's 236-point boundary includes the native sidebar's measured 8-point outer inset.
        // navigationSplitViewColumnWidth sizes the content, rather than that outer boundary.
        static let sidebarBoundary: CGFloat = 236
        static let nativeSidebarInset: CGFloat = 8
        static let sidebarWidth = sidebarBoundary - nativeSidebarInset
        static let rowHeight: CGFloat = 32
        static let rowInset: CGFloat = 10
        static let rowSpacing: CGFloat = 2
        static let contentSpacing: CGFloat = 10
        static let symbolSize: CGFloat = 13
        static let symbolSlotSize: CGFloat = 18
        static let brandSize: CGFloat = 18
        static let brandSlotSize: CGFloat = 20
        static let brandTopInset: CGFloat = 6
        static let brandBottomInset: CGFloat = 12
        static let footerSpacing: CGFloat = 6
        static let footerDotSize: CGFloat = 6
        static let badgeHorizontalInset: CGFloat = 5
        static let badgeVerticalInset: CGFloat = 1
    }

    /// One concentric family (K2.4): an inner corner is its outer corner minus the inset
    /// between them. Where the OS owns a corner (window, sidebar, toolbar items, menus), it wins.
    enum Radius {
        static let floating: CGFloat = 18
        static let well: CGFloat = inset(floating, by: 8)   // 10
        static let key: CGFloat = inset(well, by: 4)         // 6
        static let thumb: CGFloat = 10
        static let box: CGFloat = 12
        static let control: CGFloat = 8
        static let badge: CGFloat = 5

        /// The concentric inner radius, never tighter than a badge's.
        static func inset(_ outer: CGFloat, by inset: CGFloat) -> CGFloat { max(badge, outer - inset) }
    }

    /// The one shadow in the app: the camera tile's lift (K2.5). Glass draws its own.
    enum Shadow {
        static let tileColor = ThemeColor("tileShadow", dark: C(0x000000, alpha: 0.55), light: C(0x141A22, alpha: 0.34))
        static let tileRadius: CGFloat = 14
        static let tileOffsetY: CGFloat = -6
    }

    /// Editor chrome follows Graphite's 32-point keys and 4/8/12/16 spacing.
    enum Editor {
        static let toolWidth: CGFloat = 30
        static let toolHeight: CGFloat = 32
        static let symbol = SwiftUI.Font.system(size: 15, weight: .regular)
        static let inspectorWidth: CGFloat = 280
        static let swatchSize: CGFloat = 16
        static let hitSize: CGFloat = 28
        static let presetHeight: CGFloat = 28
        static let thumbnailHeight: CGFloat = 68
        static let canvasMargin: CGFloat = 32
        static let shadowRadius: CGFloat = 12
        static let shadowY: CGFloat = 4
        static let shadowColor = ThemeColor("editorImageShadow", dark: C(0x000000, alpha: 0.18), light: C(0x000000, alpha: 0.12))
        static let lineWidths: [Double] = [2, 4, 8]
        static let arrowWidths: [Double] = [4, 6, 10]
        static let textSizes: [Double] = [18, 28, 42]
        static let effectSizes: [Double] = [6, 12, 24]
        static let backgroundGraphite = EditorColor(red: 0.10, green: 0.11, blue: 0.13)
        static let backgroundGradientEnd = EditorColor(red: 0.60, green: 0.67, blue: 0.79)
        static let swatches: [EditorColor] = [.ink, .black, .paper,
            EditorRenderer.markerColor,
            EditorColor(red: 0.384, green: 0.706, blue: 0.549),
            EditorColor(red: 0.298, green: 0.510, blue: 0.851),
            EditorColor(red: 0.541, green: 0.420, blue: 0.867)]
    }
}

// MARK: - Motion

extension Theme {
    /// Precise springs, bounce ≤ 0.05 (K1, K2.6). `reduced` is what Reduce Motion gets (K2.7).
    enum Motion {
        enum Duration {
            static let instant: Double = 0.12
            static let fast: Double = 0.22
            static let panel: Double = 0.26
            static let morph: Double = 0.26
            static let exit: Double = 0.12
            static let moduleSwitch: Double = 0.22
            static let reduced: Double = 0.15
            static let breath: Double = 0.52
            static let dwell: Double = 6
        }

        static let instant = Animation.easeOut(duration: Duration.instant)
        static let fast = Animation.spring(duration: Duration.fast, bounce: 0)
        static let panel = Animation.spring(duration: Duration.panel, bounce: 0.04)
        static let morph = Animation.spring(duration: Duration.morph, bounce: 0.05)
        static let exit = Animation.easeOut(duration: Duration.exit)
        static let moduleSwitch = Animation.easeOut(duration: Duration.moduleSwitch)
        static let snap = Animation.spring(duration: Duration.fast, bounce: 0.05)
        static let drag = Animation.interactiveSpring(response: 0.18, dampingFraction: 0.9)
        static let reduced = Animation.easeInOut(duration: Duration.reduced)
        static let dwell = Animation.linear(duration: Duration.dwell)

        /// The animation a transition should use: its own, or a plain cross-fade under Reduce Motion.
        static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
            reduceMotion ? reduced : animation
        }

        /// Condense (Frost): a small surface arrives from a blur of 8 pt and 96 % scale. Only
        /// small surfaces — panel content, card, toast, HUD, countdown, menus — never the
        /// window or anything showing video (NATIVE-GAPS #7).
        static let condenseBlur: CGFloat = 8
        static let condenseScale: CGFloat = 0.96
        /// The module switch's blur bridge, on the outgoing view only.
        static let switchBlur: CGFloat = 3
    }
}
