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
            path: "Sources/Camcord"
        ),
        .testTarget(
            name: "CamcordTests",
            dependencies: ["Camcord"],
            path: "Tests/CamcordTests"
        )
    ]
)
