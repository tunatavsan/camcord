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

    /// Keys that predate the catalog (Turkish literals used as keys). The list may only
    /// shrink; K8 of docs/RUN-UI-2.md empties it by P6.
    private func legacyKeys() throws -> Set<String> {
        let url = Self.root.appendingPathComponent("Tests/CamcordTests/Fixtures/legacy-uncatalogued-keys.json")
        return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)))
    }

    @Test("every key the compiler sees in the code is in the catalog (or on the shrinking legacy list)")
    func codeKeysAreInTheCatalog() throws {
        let catalogKeys = Set(try catalog().strings.keys)
        let used = try compiledKeys()
        #expect(used.count >= 100, "the compiler's key files look empty; is -emit-localized-strings still set?")
        let missing = used.subtracting(catalogKeys).subtracting(try legacyKeys())
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

    @Test("the legacy list names only keys that are still in the code and still missing from the catalog")
    func legacyListOnlyShrinks() throws {
        let legacy = try legacyKeys()
        let used = try compiledKeys()
        let catalogKeys = Set(try catalog().strings.keys)
        let gone = legacy.subtracting(used)
        #expect(gone.isEmpty, "no longer in the code; remove from the legacy list: \(gone.sorted())")
        let catalogued = legacy.intersection(catalogKeys)
        #expect(catalogued.isEmpty, "now in the catalog; remove from the legacy list: \(catalogued.sorted())")
    }
}
