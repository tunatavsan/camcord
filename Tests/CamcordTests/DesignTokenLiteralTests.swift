import Foundation
import Testing

/// New and restyled surfaces read colour, type size and animation
/// timing from `Theme` only. This greps them for literals; `App/Design/Theme.swift` and
/// `Glass.swift` are where the literals live. Each restyle step adds its files to `enforced`.
@Suite("Design token literals")
struct DesignTokenLiteralTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Files and folders (relative to the package root) whose Swift must use tokens.
    static let enforced = [
        "Sources/Camcord/App/Design/Components",
        "Sources/Camcord/App/DesignLab/TokenGallery.swift",
        "Sources/Camcord/App/DesignLab/ComponentGallery.swift",
        "Sources/Camcord/App/MainWindow",
        "Sources/Camcord/App/FirstRun",
    ]
    /// Where the literals are defined.
    static let definitions: Set<String> = [
        "Sources/Camcord/App/Design/Theme.swift",
        "Sources/Camcord/App/Design/Glass.swift",
    ]

    /// (what, pattern). A hit on a code line (comments stripped) is a failure.
    static let rules: [(String, String)] = [
        ("literal colour", #"(?:Color|NSColor)\s*\(\s*(?:red|white|hue|srgbRed|calibratedRed|calibratedWhite|deviceRed|deviceWhite|displayP3Red|\.sRGB|genericGamma)"#),
        ("literal colour", #"#colorLiteral"#),
        ("literal colour", #"(?:Color|NSColor)\.(?:red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|white|black|gray|system[A-Z]\w*)\b"#),
        ("literal colour", #"(?:foregroundStyle|foregroundColor|fill|stroke|tint|background)\(\s*\.(?:red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|white|black|gray)\b"#),
        ("literal font size", #"\.system\(\s*size:"#),
        ("literal font size", #"NSFont\.(?:systemFont|boldSystemFont|monospacedSystemFont|monospacedDigitSystemFont)\(\s*ofSize:"#),
        ("literal font size", #"\.custom\("#),
        ("literal duration", #"\.(?:spring|easeOut|easeIn|easeInOut|linear|smooth|snappy|bouncy|interactiveSpring|interpolatingSpring|timingCurve)\("#),
        ("literal duration", #"(?:withDuration|animationDuration|\.duration)\s*[:=]\s*[0-9]"#),
        ("literal duration", #"\.animation\(\.default"#),
    ]

    static func swiftFiles() throws -> [URL] {
        var files: [URL] = []
        for path in enforced {
            let url = root.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
            }
            if isDirectory.boolValue {
                let found = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?
                    .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
                files += found
            } else {
                files.append(url)
            }
        }
        return files.filter { !definitions.contains($0.path.replacingOccurrences(of: root.path + "/", with: "")) }
    }

    /// The code of `line`: no trailing `//` comment, and string literal contents blanked, so
    /// a word inside a string or a comment is never taken for code.
    static func code(_ line: String) -> String {
        var inString = false
        var previous: Character = " "
        var result = ""
        for character in line {
            if character == "\"" && previous != "\\" {
                inString.toggle()
                result.append(character)
            } else if inString {
                result.append(" ")
            } else if character == "/" && previous == "/" {
                result.removeLast()
                break
            } else {
                result.append(character)
            }
            previous = character
        }
        return result
    }

    static func violations(in text: String, file: String) throws -> [String] {
        let patterns = try rules.map { ($0.0, try NSRegularExpression(pattern: $0.1)) }
        var found: [String] = []
        for (number, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            let code = Self.code(line)
            for (what, regex) in patterns where regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                found.append("\(file):\(number + 1) \(what): \(trimmed)")
            }
        }
        return found
    }

    @Test("new and restyled surfaces carry no literal colour, font size or duration")
    func noLiterals() throws {
        let files = try Self.swiftFiles()
        #expect(files.count >= 2)
        var all: [String] = []
        for file in files {
            all += try Self.violations(in: String(contentsOf: file, encoding: .utf8), file: file.lastPathComponent)
        }
        #expect(all.isEmpty, "\(all.joined(separator: "\n"))")
    }

    @Test("the rules catch what they are for, and let token use through")
    func rulesWork() throws {
        let bad = [
            #".foregroundStyle(Color(red: 0.2, green: 0.3, blue: 0.4))"#,
            #".fill(.blue)"#,
            #"let c = NSColor.systemOrange"#,
            #".font(.system(size: 13))"#,
            #"label.font = NSFont.systemFont(ofSize: 12)"#,
            #"withAnimation(.spring(duration: 0.3)) { }"#,
            #"context.duration = 0.2"#,
            #".animation(.easeOut(duration: 0.12), value: x)"#,
        ]
        for line in bad {
            #expect(try !Self.violations(in: line, file: "x").isEmpty, "\(line)")
        }
        let good = [
            #".foregroundStyle(Theme.Palette.ink.color)"#,
            #".font(Theme.Font.body)"#,
            #"withAnimation(Theme.Motion.fast) { }"#,
            #".animation(Theme.Motion.resolve(Theme.Motion.panel, reduceMotion: rm), value: x)"#,
            #"Text("fill(.blue) in a string is fine") // .font(.system(size: 9)) in a comment"#,
        ]
        for line in good {
            #expect(try Self.violations(in: line, file: "x").isEmpty, "\(line)")
        }
    }
}
