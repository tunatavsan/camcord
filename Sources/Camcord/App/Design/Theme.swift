import AppKit
import CoreText
import SwiftUI

// Camcord's design tokens. Colour, type, spacing, radius and motion live here and nowhere
// else: every surface reads these names, and DesignTokenLiteralTests fails on a literal colour,
// font size or duration in the files that consume them. Palette and type from Console, shape and spacing from Graphite, motion precise.

enum Theme {}

extension Theme {
    /// Opaque Settings forms from Graphite II; shared module chrome is unchanged.
    enum Settings {
        static let maximumWidth: CGFloat = 620
        static let titleGap: CGFloat = 18
        static let cardGap: CGFloat = 22
        static let rowMinimum: CGFloat = 44
        static let rowHorizontal: CGFloat = 14
        static let rowVertical: CGFloat = 8
        static let rowGap: CGFloat = 14
        static let popupHeight: CGFloat = 26
        static let popupRadius: CGFloat = 6
        static let popupLeading: CGFloat = 10
        static let popupTrailing: CGFloat = 8
        static let popupGap: CGFloat = 6
        static let popupMaximumWidth: CGFloat = 300
        static let disabledOpacity: Double = 0.45
        static let sliderWidth: CGFloat = 180
        static let sliderHeight: CGFloat = 14
        static let valueWidth: CGFloat = 64
        static let permissionSymbol: CGFloat = 12
    }
}

extension Theme {
    /// Library content geometry; chrome and materials remain system-owned.
    enum Library {
        static let badgeInk = SwiftUI.Color(nsColor: ThemeColor.RGBA(0xE8EAED).nsColor)
        static let badgeFill = SwiftUI.Color(nsColor: ThemeColor.RGBA(0x0A0B0D, alpha: 0.72).nsColor)
        static let inspectorWidth: CGFloat = 300
        static let inspectorInset: CGFloat = 20
        static let controlHeight: CGFloat = 28
        static let primaryHeight: CGFloat = 36
        static let controlInset: CGFloat = 12
        static let controlGap: CGFloat = 6
        static let searchWidth: CGFloat = 220
        static let searchInset: CGFloat = 10
        static let filterGap: CGFloat = 2
        static let filterBottom: CGFloat = 20
        static let groupGap: CGFloat = 26
        static let headerGap: CGFloat = 10
        static let gridMinimum: CGFloat = 168
        static let gridRowGap: CGFloat = 22
        static let thumbnailAspect: CGFloat = 16 / 10.5
        static let tileGap: CGFloat = 7
        static let metaInset: CGFloat = 2
        static let hairline: CGFloat = 0.5
        static let selectionLine: CGFloat = 2
        static let selectionArm: CGFloat = 14
        static let selectionCorner: CGFloat = 6
        static let selectionOutset: CGFloat = 6
        static let badgeInset: CGFloat = 7
        static let badgeHeight: CGFloat = 18
        static let badgePadding: CGFloat = 6
        static let badgeGap: CGFloat = 4
        static let freshSeconds: TimeInterval = 600
        static let emptyGap: CGFloat = 14
        static let emptyMark: CGFloat = 64
        static let emptyMarkLineFraction: CGFloat = 0.05
        static let emptyTitleInset: CGFloat = 6
        static let shortcutWidth: CGFloat = 92
        static let shortcutMaxWidth: CGFloat = 492
        static let shortcutTopInset: CGFloat = 12
        static let shortcutBottomInset: CGFloat = 10
        static let shortcutSideInset: CGFloat = 6
        static let shortcutIcon: CGFloat = 20
        static let disabledOpacity: Double = 0.45
    }
}

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

        /// WCAG relative luminance, for the contrast floor.
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
    /// setting, or from the live check's in-app override (never the user's system setting).
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
    /// The palette. No token reads the system accent: selection and "on" are
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
        static let ink3 = ThemeColor("ink3", dark: C(0xA0A7B0), light: C(0x596067),
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
        /// behind-window system material. Lower alpha lets more of the blurred desktop colour through.
        static let backdropContent = ThemeColor("backdropContent", dark: C(0x16181B, alpha: 0.52),
                                                light: C(0xE3E6EA, alpha: 0.40),
                                                highContrastDark: C(0x0E0F11, alpha: 0.92),
                                                highContrastLight: C(0xEEF0F2, alpha: 0.92))
        static let backdropSidebar = ThemeColor("backdropSidebar", dark: C(0x2E333A, alpha: 0.62),
                                                light: C(0xD8DCE1, alpha: 0.60),
                                                highContrastDark: C(0x2E333A, alpha: 0.88),
                                                highContrastLight: C(0xD8DCE1, alpha: 0.88))
        /// Reduce Transparency: the opaque stand-ins for glass.
        static let glassSolidChrome = ThemeColor("glassSolidChrome", dark: C(0x1E2125), light: C(0xECEEF1))
        static let glassSolidSidebar = ThemeColor("glassSolidSidebar", dark: C(0x24282D), light: C(0xD8DCE1))
        static let glassSolidHUD = ThemeColor("glassSolidHUD", dark: C(0x1E2125), light: C(0x1E2125))
        /// Pre-Graphite-II accent, kept ONLY for surfaces not yet restyled (the old panel, the old
        /// Settings window, the hub). Deleted with the CamcordStyle alias layer.
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
    /// DM Sans for text; SF Mono for data because this face has no tabular-number feature.
    enum Font {
        static let caption = text(Size.caption)
        static let captionStrong = text(Size.caption, weight: .semibold)
        static let body = text(Size.body)
        static let bodyStrong = text(Size.body, weight: .semibold)
        static let row = text(Size.row)
        static let rowStrong = text(Size.row, weight: .semibold)
        static let sidebarSymbol = SwiftUI.Font.system(size: Navigation.symbolSize, weight: .regular)
        static let sidebarBrand = text(Size.row, weight: .semibold)
        static let sidebarSection = text(Size.caption, weight: .medium)
        static let title = text(Size.title, weight: .semibold)
        static let display = text(Size.display, weight: .semibold)
        static let timecode = SwiftUI.Font.system(size: Size.display, weight: .light, design: .monospaced).monospacedDigit()
        static let countdown = SwiftUI.Font.system(size: Size.countdown, weight: .light, design: .monospaced).monospacedDigit()
        static let data = SwiftUI.Font.system(size: Size.data, design: .monospaced).monospacedDigit()
        static let dataSmall = SwiftUI.Font.system(size: Size.caption, design: .monospaced).monospacedDigit()
        static let dataStrong = SwiftUI.Font.system(size: Size.data, weight: .semibold, design: .monospaced).monospacedDigit()
        /// Tracking for the display size and for uppercase-free section headers.
        static let displayTracking: CGFloat = 0
        static let headerTracking: CGFloat = 0.2

        /// SwiftUI wraps the exact AppKit face, including its weight and optical-size axes.
        static func text(_ size: CGFloat, weight: NSFont.Weight = .regular,
                         fonts: BundledFonts = .application) -> SwiftUI.Font {
            SwiftUI.Font(ns.text(size, weight: weight, fonts: fonts) as CTFont)
        }

        enum Size {
            static let caption: CGFloat = 12
            static let body: CGFloat = 14
            static let row: CGFloat = 16
            static let title: CGFloat = 20
            static let display: CGFloat = 28
            static let data: CGFloat = 12
            static let countdown: CGFloat = 64
        }

        /// AppKit twins, for the hub, the status item, annotations and the overlays.
        enum ns {
            static func text(_ size: CGFloat, weight: NSFont.Weight = .regular,
                             fonts: BundledFonts = .application) -> NSFont {
                fonts.text(size, weight: weight)
            }
            static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
                NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            }
            static var caption: NSFont { text(Size.caption) }
            static var body: NSFont { text(Size.body) }
            static var bodyStrong: NSFont { text(Size.body, weight: .semibold) }
            static var data: NSFont { mono(Size.data) }
            static var dataStrong: NSFont { mono(Size.data, weight: .semibold) }
            static var pill: NSFont { mono(Size.caption, weight: .semibold) }
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

    /// The Graphite II window shell.
    enum Navigation {
        // The design's 236-point boundary includes the native sidebar's measured 8-point outer inset.
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

    /// One concentric family: an inner corner is its outer corner minus the inset
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

    /// The one shadow in the app: the camera tile's lift. Glass draws its own.
    enum Shadow {
        static let tileColor = ThemeColor("tileShadow", dark: C(0x000000, alpha: 0.55), light: C(0x141A22, alpha: 0.34))
        static let tileRadius: CGFloat = 14
        static let tileOffsetY: CGFloat = -6
    }

    /// Studio geometry from the Graphite II source/inspector CSS.
    enum Studio {
        static let inspectorWidth: CGFloat = 312
        static let sideInset: CGFloat = 20
        static let sectionSpacing: CGFloat = 18
        static let mainSpacing: CGFloat = 14
        static let sourceWidth: CGFloat = 124
        static let sourceHeight: CGFloat = 77.5
        static let sourceCaptionGap: CGFloat = 5
        static let sourceGap: CGFloat = 10
        static let channelIcon: CGFloat = 28
        static let decibelWidth: CGFloat = 56
        static let meterHeight: CGFloat = 6
        static let meterSegmentWidth: CGFloat = 11
        static let meterSegmentGap: CGFloat = 1
        static let gainHeight: CGFloat = 14
        static let gainTrack: CGFloat = 2
        static let gainKnob: CGFloat = 12
        static let popupHeight: CGFloat = 26
        static let primaryHeight: CGFloat = 44
        static let placeholderSymbol = SwiftUI.Font.system(size: 34, weight: .light)
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

// MARK: - Menu panel

extension Theme {
    enum Menu {
        /// Panel float tint from Graphite II; real system glass supplies the material.
        static let glassTint = ThemeColor("menuGlassTint", dark: C(0x16181C, alpha: 0.70), light: C(0xF0F2F5, alpha: 0.76),
                                          highContrastDark: C(0x1E2125), highContrastLight: C(0xECEEF1))
        static let inset = ThemeColor("menuInset", dark: C(0x000000, alpha: 0.24), light: C(0x14181E, alpha: 0.05))
        static let line = ThemeColor("menuLine", dark: C(0xFFFFFF, alpha: 0.08), light: C(0x14181E, alpha: 0.10))
        static let headerHeight: CGFloat = 20
        static let sectionHeight: CGFloat = 11
        static let mark: CGFloat = 17
        static let keyHeight: CGFloat = 58
        static let keySymbol: CGFloat = 20
        static let keySymbolFont: CGFloat = 18
        static let chipHeight: CGFloat = 32
        static let actionHeight: CGFloat = 40
        static let lastHeight: CGFloat = 54
        static let thumbnail = CGSize(width: 64, height: 42)
        static let footerHeight: CGFloat = 28
        static let pillHeight: CGFloat = 22
        static let pillDot: CGFloat = 8
        static let pillGap: CGFloat = 6
        static let pillLeading: CGFloat = 6
        static let pillTrailing: CGFloat = 8
        static var pillFont: NSFont { NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold) }
    }
}

// MARK: - Motion

extension Theme {
    /// Precise springs, bounce ≤ 0.05. `reduced` is what Reduce Motion gets.
    enum Motion {
        enum Duration {
            static let instant: Double = 0.12
            static let fast: Double = 0.22
            static let panel: Double = 0.26
            static let morph: Double = 0.26
            static let exit: Double = 0.12
            static let moduleSwitch: Double = 0.14
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
        static let moduleTranslation: CGFloat = 8
        static func moduleOffset(active: Bool, reduceMotion: Bool) -> CGFloat {
            active || reduceMotion ? 0 : moduleTranslation
        }
        /// The module switch's blur bridge, on the outgoing view only.
        static let switchBlur: CGFloat = 3
    }
}

// MARK: - Main window

extension Theme {
    /// The main window speaks the menu-bar panel's language. The panel keeps its numbers inline
    /// (CapturePanelView); these are the same numbers, named, so every window surface reads them
    /// from one place. Text is SF Pro: the window is read at 11–13 pt, where the system face
    /// is the sharpest and its digits are tabular.
    enum Window {
        enum Font {
            static let label = SwiftUI.Font.system(size: Size.label, weight: .medium)
            static let caption = SwiftUI.Font.system(size: Size.caption)
            static let captionStrong = SwiftUI.Font.system(size: Size.caption, weight: .semibold)
            static let body = SwiftUI.Font.system(size: Size.body)
            static let bodyStrong = SwiftUI.Font.system(size: Size.body, weight: .semibold)
            static let row = SwiftUI.Font.system(size: Size.body, weight: .medium)
            static let headline = SwiftUI.Font.system(size: Size.headline, weight: .semibold)
            static let title = SwiftUI.Font.system(size: Size.title, weight: .bold)
            static let display = SwiftUI.Font.system(size: Size.display, weight: .semibold)
            static let data = SwiftUI.Font.system(size: Size.label, weight: .medium).monospacedDigit()
            static let dataBody = SwiftUI.Font.system(size: Size.caption).monospacedDigit()
            static let symbolEmpty = SwiftUI.Font.system(size: Size.emptySymbol, weight: .ultraLight)

            enum Size {
                static let label: CGFloat = 11
                static let caption: CGFloat = 12
                static let body: CGFloat = 13
                static let headline: CGFloat = 15
                static let title: CGFloat = 22
                static let display: CGFloat = 26
                static let emptySymbol: CGFloat = 44
            }
        }

        /// The panel's springs (CapturePanelView), by role.
        enum Motion {
            /// A symbol rising under the pointer, a sibling stepping back.
            static let lift = Animation.spring(response: 0.32, dampingFraction: 0.62)
            /// The larger tool button's rise.
            static let liftTool = Animation.spring(response: 0.34, dampingFraction: 0.62)
            /// Giving under the pointer.
            static let press = Animation.spring(response: 0.2, dampingFraction: 0.7)
            /// The selection mark sliding to a new choice.
            static let select = Animation.spring(response: 0.36, dampingFraction: 0.72)
            /// A switch turning on or off.
            static let toggle = Animation.spring(response: 0.3, dampingFraction: 0.6)
            /// A capsule's bloom, a link's arrow, a menu's pop.
            static let bloom = Animation.spring(response: 0.3, dampingFraction: 0.7)
            /// Words trading places.
            static let swap = Animation.easeOut(duration: 0.16)
            /// Large content arriving.
            static let arrive = Animation.spring(response: 0.42, dampingFraction: 0.84)
            /// A tile settling back after the pointer leaves.
            static let settle = Animation.spring(response: 0.32, dampingFraction: 0.85)
        }

        /// How far things rise, glow, give and step back.
        enum Lift {
            static let symbolScale: CGFloat = 1.18
            static let toolScale: CGFloat = 1.16
            static let symbolRise: CGFloat = 1.5
            static let toolRise: CGFloat = 2
            static let glowOpacity: Double = 0.45
            static let glowRadius: CGFloat = 6
            static let toolGlowRadius: CGFloat = 7
            /// A sibling of the hovered control. Rows carrying words step back less, to stay legible.
            static let sibling: Double = 0.5
            /// A sibling row's words step back less than its symbol, so they stay readable.
            static let rowTextSibling: Double = 0.75
            static let disabled: Double = 0.35
            static let press: CGFloat = 0.92
            /// A wide surface (a row, a card) gives less than a symbol: 8 % of 200 pt is a lurch.
            static let widePress: CGFloat = 0.98
            static let tileScale: CGFloat = 1.03
            static let tileRise: CGFloat = 3
            static let detailRise: CGFloat = 3
            static let arriveScale: CGFloat = 0.985
        }

        /// The window's frame: glass cells on the tray, as in the panel.
        enum Layout {
            static let ring: CGFloat = 8
            static let gap: CGFloat = 8
            static let cellPadding: CGFloat = 12
            static let cellRadius: CGFloat = Radius.floating
            static let sidebarWidth: CGFloat = 212
            static let titlebarHeight: CGFloat = 44
            static let rowHeight: CGFloat = 32
            static let rowInset: CGFloat = 10
            static let rowSpacing: CGFloat = 2
            static let rowRadius: CGFloat = 9
            static let markWidth: CGFloat = 3
            static let markHeight: CGFloat = 16
            static let chipMarkWidth: CGFloat = 16
            static let chipMarkHeight: CGFloat = 2
            static let symbolCanvas: CGFloat = 20
            static let symbolPoint: CGFloat = 14
            static let toolSymbolPoint: CGFloat = 18
            static let toolSymbolCanvas: CGFloat = 26
            static let toolHeight: CGFloat = 56
            static let iconButton: CGFloat = 30
            static let chipHeight: CGFloat = 30
            static let chipSymbolPoint: CGFloat = 11
            static let chipSymbolCanvas: CGFloat = 16
            static let capsuleHeight: CGFloat = 40
            static let linkHeight: CGFloat = 28
            static let iconRadius: CGFloat = Radius.control
            static let focusRing: CGFloat = 2
            static let headerHeight: CGFloat = 52
            static let hairline: CGFloat = 1
        }

        /// The capsule's bloom (CapturePanelView's primary and secondary buttons).
        enum Bloom {
            static let restFill: Double = 0.92
            static let glow: Double = 0.45
            static let quietGlow: Double = 0.18
            static let radius: CGFloat = 10
            static let quietRadius: CGFloat = 8
            static let drop: CGFloat = 2
            static let quietDrop: CGFloat = 1
            static let symbolScale: CGFloat = 1.12
            static let shortcut: Double = 0.75
            static let arrowStep: CGFloat = 2
            static let tileGlow: Double = 0.15
        }

        /// The panel's capsule edges and glows, as colours over ink and white.
        enum Ink {
            static let rim = ThemeColor("windowRim", dark: C(0xFFFFFF, alpha: 0.16), light: C(0xFFFFFF, alpha: 0.55))
            static let capsuleEdge = ThemeColor("windowCapsuleEdge", dark: C(0xFFFFFF, alpha: 0.18), light: C(0xFFFFFF, alpha: 0.35))
            static let quietEdge = ThemeColor("windowQuietEdge", dark: C(0xFFFFFF, alpha: 0.08), light: C(0x14181E, alpha: 0.08))
            /// The system's keyboard focus colour: focus is the one place the window follows the user's accent.
            static let focusRing = SwiftUI.Color(nsColor: .keyboardFocusIndicatorColor)
        }
    }
}
