import AppKit
import SwiftUI
import Testing

@testable import Camcord

/// The Graphite II tokens (docs/design/native/SPEC.md §2): the accessibility floor in the
/// palette, dynamic resolution per appearance, the concentric radii, the motion rules, glass
/// fallbacks, and the live-check commands.
@MainActor
@Suite("Theme tokens")
struct ThemeTests {
    typealias RGBA = ThemeColor.RGBA

    private func contrast(_ text: ThemeColor, on ground: ThemeColor, _ variant: ThemeColor.Variant,
                          over base: ThemeColor = Theme.Palette.window) -> CGFloat {
        let groundValue = ground.value(variant).over(base.value(variant))
        return RGBA.contrast(text.value(variant).over(groundValue), groundValue)
    }

    @Test("text is at least 4.5:1 on the window and on surfaces, in every variant (BRIEF §7.10)",
          arguments: ThemeColor.Variant.allCases)
    func textContrast(variant: ThemeColor.Variant) {
        let texts = [Theme.Palette.ink, Theme.Palette.ink2, Theme.Palette.ink3]
        for ground in [Theme.Palette.window, Theme.Palette.surface] {
            for text in texts {
                let ratio = contrast(text, on: ground, variant)
                #expect(ratio >= 4.5, "\(text.name) on \(ground.name) \(variant): \(ratio)")
            }
        }
        // White on record red (the Record bar and the menu-bar pill), ink on its own fill,
        // and ink on a selected row.
        #expect(contrast(Theme.Palette.onRecord, on: Theme.Palette.record, variant) >= 4.5)
        #expect(contrast(Theme.Palette.onInk, on: Theme.Palette.ink, variant) >= 4.5)
        #expect(contrast(Theme.Palette.ink, on: Theme.Palette.selectionStrong, variant) >= 4.5)
        // The state colours stay readable as text on a surface (permissions).
        #expect(contrast(Theme.Palette.ok, on: Theme.Palette.surface, variant) >= 3)
        #expect(contrast(Theme.Palette.warn, on: Theme.Palette.surface, variant) >= 3)
    }

    @Test("section captions remain above 4.5:1 on the measured dark glass composite")
    func captionContrastOnCompositedGlass() {
        // The actual material behind section captions measured RGB (51, 52, 55).
        // Keep this independent of palette.window: a transparent composite has its own luminance.
        let measuredBackground = RGBA(0x333437)
        let caption = Theme.Palette.ink3.value(.dark).over(measuredBackground)
        #expect(RGBA.contrast(caption, measuredBackground) >= 4.5)
    }

    @Test("Increase Contrast strengthens hairlines and ink; it never weakens them")
    func highContrastIsStronger() {
        for (normal, strong) in [(ThemeColor.Variant.dark, ThemeColor.Variant.highContrastDark),
                                 (.light, .highContrastLight)] {
            for token in [Theme.Palette.hairline, Theme.Palette.ink2, Theme.Palette.ink3] {
                #expect(contrast(token, on: Theme.Palette.window, strong) > contrast(token, on: Theme.Palette.window, normal),
                        "\(token.name) \(strong)")
            }
        }
    }

    @Test("dark or light comes from the appearance, Increase Contrast from the setting")
    func variantMapping() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        let light = try #require(NSAppearance(named: .aqua))
        let vibrant = try #require(NSAppearance(named: .vibrantDark))
        #expect(ThemeColor.variant(for: dark, increaseContrast: false) == .dark)
        #expect(ThemeColor.variant(for: light, increaseContrast: false) == .light)
        #expect(ThemeColor.variant(for: vibrant, increaseContrast: false) == .dark)
        #expect(ThemeColor.variant(for: dark, increaseContrast: true) == .highContrastDark)
        #expect(ThemeColor.variant(for: light, increaseContrast: true) == .highContrastLight)
    }

    @Test("a token resolves to its own value for each appearance, dynamically, and follows the override")
    func dynamicResolution() throws {
        defer { ThemeColor.highContrastOverride = nil }
        let cases: [(NSAppearance.Name, Bool, ThemeColor.Variant)] = [
            (.darkAqua, false, .dark), (.aqua, false, .light), (.darkAqua, true, .highContrastDark), (.aqua, true, .highContrastLight),
        ]
        for (name, highContrast, variant) in cases {
            ThemeColor.highContrastOverride = highContrast
            let appearance = try #require(NSAppearance(named: name))
            for token in [Theme.Palette.window, Theme.Palette.ink3, Theme.Palette.hairline] {
                var resolved: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    resolved = token.ns.usingColorSpace(.sRGB)
                }
                let expected = token.value(variant)
                let color = try #require(resolved)
                #expect(abs(color.redComponent - expected.red) < 0.002, "\(token.name) \(variant)")
                #expect(abs(color.greenComponent - expected.green) < 0.002, "\(token.name) \(variant)")
                #expect(abs(color.blueComponent - expected.blue) < 0.002, "\(token.name) \(variant)")
            }
        }
    }

    @Test("every token has its own name, and hex strings read back")
    func namesAreUnique() {
        let names = Theme.Palette.all.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(Theme.Palette.window.dark.hexString == "#16181B")
        #expect(Theme.Palette.record.light.hexString == "#D2343A")
        #expect(Theme.Palette.selection.dark.hexString == "#E8EAED 12%")
    }

    @Test("radii are one concentric family: inner = outer − inset")
    func concentricRadii() {
        #expect(Theme.Radius.well == Theme.Radius.floating - 8)
        #expect(Theme.Radius.key == Theme.Radius.well - 4)
        #expect(Theme.Radius.inset(Theme.Radius.floating, by: 30) == Theme.Radius.badge)
        #expect(CamcordStyle.Radius.surface == Theme.Radius.floating)
    }

    @Test("motion: short, and Reduce Motion always gets the plain cross-fade")
    func motionRules() {
        typealias D = Theme.Motion.Duration
        let durations = [D.instant, D.fast, D.panel, D.morph, D.exit, D.moduleSwitch]
        #expect(durations.allSatisfy { $0 > 0 && $0 <= 0.3 })
        for animation in [Theme.Motion.fast, Theme.Motion.panel, Theme.Motion.morph, Theme.Motion.snap] {
            #expect(Theme.Motion.resolve(animation, reduceMotion: true) == Theme.Motion.reduced)
            #expect(Theme.Motion.resolve(animation, reduceMotion: false) == animation)
        }
        #expect(Theme.Motion.condenseBlur <= 8)
        #expect(Theme.Motion.condenseScale >= 0.96)
    }

    @Test("glass: tints are translucent, Reduce Transparency stand-ins are opaque, HUDs are dark")
    func glassFallbacks() {
        for style in GlassStyle.allCases {
            for variant in ThemeColor.Variant.allCases {
                #expect(style.solid.value(variant).alpha == 1, "\(style) solid \(variant)")
                #expect(style.tint.value(variant).alpha < 1, "\(style) tint \(variant)")
            }
        }
        #expect(GlassStyle.hud.forcedScheme == .dark)
        #expect(GlassStyle.chrome.forcedScheme == nil)
        let view = NSGlassEffectView.camcord(.hud, cornerRadius: 22)
        #expect(view.style == .regular)
        #expect(view.cornerRadius == 22)
        #expect(view.appearance?.name == .darkAqua)
    }

    @Test("live-check commands parse; anything else is ignored")
    func liveCheckCommands() throws {
        typealias Command = LiveCheck.Command
        #expect(Command.parse("window studio") == .window(.studio))
        #expect(Command.parse("window") == .window(.library))
        #expect(Command.parse("window timeline") == nil)
        #expect(Command.parse("appearance dark") == .appearance(.darkAqua))
        #expect(Command.parse("appearance light") == .appearance(.aqua))
        #expect(Command.parse("appearance system") == .appearance(nil))
        #expect(Command.parse("appearance sepia") == nil)
        #expect(Command.parse("lab components") == .lab(.components))
        #expect(Command.parse("contrast high") == .contrast(true))
        #expect(Command.parse("contrast normal") == .contrast(false))
        #expect(Command.parse("contrast system") == .contrast(nil))
        #expect(Command.parse("contrast max") == nil)
        #expect(Command.parse("close") == .close)
        #expect(Command.parse("rm -rf") == nil)
        #expect(Command.parse("") == nil)
        // Off by default: no listener without the default.
        let defaults = try #require(UserDefaults(suiteName: "camcord.livecheck.test"))
        defaults.removePersistentDomain(forName: "camcord.livecheck.test")
        #expect(LiveCheck(defaults: defaults) { _ in } == nil)
        defaults.set(true, forKey: LiveCheck.defaultsKey)
        #expect(LiveCheck(defaults: defaults) { _ in } != nil)
        defaults.removePersistentDomain(forName: "camcord.livecheck.test")
    }
}
