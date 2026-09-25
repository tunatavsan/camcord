import Foundation
import Testing

@testable import Camcord

/// The app's own strings live in `Resources/Localizable.xcstrings`, English first, Turkish
/// second (docs/RUN-UI-1.md K2). Every key is translated, and every English-first key the
/// code uses is in the catalog — so a new string cannot ship untranslated.
@Suite("Localization catalog")
struct LocalizationCatalogTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct Unit: Decodable { let state: String; let value: String }
                let stringUnit: Unit
            }
            let localizations: [String: Localization]?
        }
        let sourceLanguage: String
        let strings: [String: Entry]
    }

    private func catalog() throws -> Catalog {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Localizable.xcstrings"))
        return try JSONDecoder().decode(Catalog.self, from: data)
    }

    @Test("every key has a translated Turkish and English value")
    func everyKeyTranslated() throws {
        let catalog = try catalog()
        #expect(catalog.sourceLanguage == "en")
        #expect(!catalog.strings.isEmpty)
        for (key, entry) in catalog.strings {
            for language in ["tr", "en"] {
                let unit = entry.localizations?[language]?.stringUnit
                #expect(unit?.state == "translated", "\(language) missing for \"\(key)\"")
                #expect(unit?.value.isEmpty == false, "\(language) empty for \"\(key)\"")
            }
        }
    }

    @Test("every English-first key in the code is in the catalog")
    @MainActor
    func codeKeysAreInTheCatalog() throws {
        let keys = Set(try catalog().strings.keys)
        // The typed ones, straight from the code.
        var used = Set<String>()
        for module in ModuleRegistry.all { used.insert(module.title.key) }
        for mode in DockIconMode.allCases { used.insert(mode.title.key) }
        // The literal ones: every String(localized:), LocalizedStringResource(…) and
        // Text(…, comment:) in Sources, plus the SwiftUI labels that take a key directly.
        let pattern = try NSRegularExpression(
            pattern: #"(?:String\(localized: |LocalizedStringResource\(|Text\()"((?:[^"\\]|\\.)+)"(?:,\s*comment|\)|,)"#)
        let sources = Self.root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let full = String(text[Range(match.range, in: text)!])
                // Only English-first keys: Text("…", comment:) and the two localized APIs.
                guard full.hasPrefix("String(localized:") || full.hasPrefix("LocalizedStringResource(")
                        || full.hasSuffix("comment") else { continue }
                used.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        used.formUnion(["Canvas", "Format", "Dock icon",
                        "Window recordings: the file keeps this shape; a resized window is centred on a blurred backdrop.",
                        "Auto picks the smallest 1080p-or-taller format at up to 60 fps."])
        #expect(used.count >= 20)
        let missing = used.subtracting(keys)
        #expect(missing.isEmpty, "not in Localizable.xcstrings: \(missing.sorted())")
    }
}
