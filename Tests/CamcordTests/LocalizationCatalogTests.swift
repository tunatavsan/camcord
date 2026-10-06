import Foundation
import Testing

@testable import Camcord

/// The app's own strings live in `Resources/Localizable.xcstrings`, English first, Turkish
/// second. Every key is translated, and every key the code uses is in the catalog — so a
/// new string cannot ship untranslated.
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

    /// Every key the compiler saw in `Sources/Camcord`: `Text`, `Button`, `Toggle`, `Label`,
    /// `Picker`, `.help`, `String(localized:)`, `LocalizedStringResource` … all of them.
    /// The Camcord target is built with `-emit-localized-strings` (Package.swift), so
    /// `swift test` refreshes these files before the tests run.
    private func compiledKeys() throws -> Set<String> {
        let directory = Self.root.appendingPathComponent(".build/localized-strings")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "stringsdata" }
        struct StringsData: Decodable {
            struct Entry: Decodable { let key: String }
            let source: String
            let tables: [String: [Entry]]
        }
        var keys = Set<String>()
        for file in files {
            let data = try JSONDecoder().decode(StringsData.self, from: Data(contentsOf: file))
            // A deleted source leaves its old file behind; it no longer counts.
            guard FileManager.default.fileExists(atPath: data.source) else { continue }
            for entry in data.tables["Localizable"] ?? [] { keys.insert(entry.key) }
        }
        return keys
    }

    @Test("every key the compiler sees in the code is in the catalog")
    func codeKeysAreInTheCatalog() throws {
        let catalogKeys = Set(try catalog().strings.keys)
        let used = try compiledKeys()
        #expect(used.count >= 100, "the compiler's key files look empty; is -emit-localized-strings still set?")
        let missing = used.subtracting(catalogKeys)
        #expect(missing.isEmpty, "not in Localizable.xcstrings: \(missing.sorted())")
    }

    @Test("the key files are live: the flag is set, and every source has a key file of its own")
    func keyFilesAreLive() throws {
        // Without the flag the files stop updating and the check above reads stale keys.
        let manifest = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(manifest.contains("\"-emit-localized-strings\""))
        #expect(manifest.contains("\"-emit-localized-strings-path\", Context.packageDirectory + \"/.build/localized-strings\""))
        // Key files are named after the source's base name, so two sources sharing one
        // would hide each other's keys.
        let directory = Self.root.appendingPathComponent(".build/localized-strings")
        let sources = FileManager.default.enumerator(at: Self.root.appendingPathComponent("Sources/Camcord"),
                                                     includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(sources.count > 50)
        struct Source: Decodable { let source: String }
        for source in sources {
            let keyFile = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".stringsdata")
            let owner = (try? Data(contentsOf: keyFile)).flatMap { try? JSONDecoder().decode(Source.self, from: $0) }?.source
            #expect(owner.map { URL(fileURLWithPath: $0).standardizedFileURL } == source.standardizedFileURL,
                    "no key file of its own for \(source.lastPathComponent)")
        }
    }
}
