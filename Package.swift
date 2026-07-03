// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "camcord",
    platforms: [.macOS("15.2")],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.0")
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
