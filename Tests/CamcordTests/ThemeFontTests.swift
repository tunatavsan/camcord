import AppKit
import CoreText
import SwiftUI
import Testing
@testable import Camcord

@Suite("Bundled typography")
struct ThemeFontTests {
    private static let fontURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Fonts/\(BundledFonts.fileName)")
    // Register once, without unregistering or altering fonts owned by another process.
    private static let fonts = BundledFonts(fontURL: fontURL)

    @Test("Process registration and both Theme factories retain the real variable face")
    func registrationAndTwins() throws {
        #expect(Self.fonts.familyName == "DM Sans")
        for (weight, axisValue, suffix) in [(NSFont.Weight.regular, 400.0, "Regular"),
                                          (.medium, 500.0, "Medium"), (.semibold, 600.0, "SemiBold")] {
            let font = Theme.Font.ns.text(14, weight: weight, fonts: Self.fonts)
            #expect(font.familyName == "DM Sans")
            #expect(font.fontName == "DMSans-9ptRegular_\(suffix)")
            #expect(font.pointSize == 14)
            let variations = try #require(CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber])
            // CoreText omits the axis's default value (400).
            #expect((variations[BundledFonts.weightAxis]?.doubleValue ?? 400) == axisValue)
            #expect(variations[BundledFonts.opticalSizeAxis]?.doubleValue == 14)
            #expect(Theme.Font.text(14, weight: weight, fonts: Self.fonts) == SwiftUI.Font(font as CTFont))
            let loadedURL = try #require(CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL)
            #expect(loadedURL.standardizedFileURL == Self.fontURL.standardizedFileURL)
        }
    }

    @Test("A missing bundled file silently uses the requested system face despite registration")
    func missingFileFallback() {
        _ = Self.fonts
        let missing = BundledFonts(fontURL: Self.fontURL.deletingLastPathComponent()
            .appendingPathComponent("missing-font.ttf"))
        #expect(missing.familyName == nil)
        for weight in [NSFont.Weight.regular, .medium, .semibold] {
            let expected = NSFont.systemFont(ofSize: 14, weight: weight)
            let actual = Theme.Font.ns.text(14, weight: weight, fonts: missing)
            #expect(actual.fontName == expected.fontName)
            #expect(actual.pointSize == expected.pointSize)
            #expect(Theme.Font.text(14, weight: weight, fonts: missing) == SwiftUI.Font(expected as CTFont))
        }
    }

    @Test("The bundled face maps every Turkish letter without glyph fallback")
    func turkishGlyphs() {
        let font = Theme.Font.ns.text(14, fonts: Self.fonts)
        let letters = Array("ğş ıİ çöü ĞŞ ÇÖÜ".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: letters.count)
        let mapped = letters.withUnsafeBufferPointer { characters in
            glyphs.withUnsafeMutableBufferPointer { glyphs in
                CTFontGetGlyphsForCharacters(font as CTFont, characters.baseAddress!, glyphs.baseAddress!, letters.count)
            }
        }
        #expect(font.familyName == "DM Sans")
        #expect(mapped)
        #expect(glyphs.allSatisfy { $0 != 0 })
    }
}
