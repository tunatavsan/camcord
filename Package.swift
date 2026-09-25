// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "camcord",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "Packages/KeyboardShortcuts")
    ],
    targets: [
        .executableTarget(
            name: "Camcord",
            dependencies: ["KeyboardShortcuts"],
            path: "Sources/Camcord",
            swiftSettings: [
                // The compiler writes every localizable key it sees (Text, Button, Toggle,
                // String(localized:) …) to .stringsdata files; LocalizationCatalogTests reads
                // them, so no key can reach the UI without a catalog entry.
                .unsafeFlags([
                    "-emit-localized-strings",
                    "-emit-localized-strings-path", Context.packageDirectory + "/.build/localized-strings",
                ])
            ]
        ),
        .testTarget(
            name: "CamcordTests",
            dependencies: ["Camcord"],
            path: "Tests/CamcordTests",
            // Read by path (#filePath), never bundled: no Bundle.module (docs/RUN-UI-1.md K2).
            exclude: ["Fixtures"]
        )
    ]
)
