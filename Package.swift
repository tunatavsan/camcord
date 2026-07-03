// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "camcord",
    platforms: [.macOS("15.2")],
    targets: [
        .executableTarget(
            name: "Camcord",
            path: "Sources/Camcord"
        )
    ]
)
