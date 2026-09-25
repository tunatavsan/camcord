// swift-tools-version:6.2
import PackageDescription

// Vendored from sindresorhus/KeyboardShortcuts 3.0.1 (49c3fc0). See VENDORED.md.
let package = Package(
	name: "KeyboardShortcuts",
	platforms: [
		.macOS(.v10_15)
	],
	products: [
		.library(
			name: "KeyboardShortcuts",
			targets: [
				"KeyboardShortcuts"
			]
		)
	],
	targets: [
		.target(
			name: "KeyboardShortcuts",
			// Not a SwiftPM resource: a resource makes SwiftPM generate `Bundle.module`, which
			// looks next to the .app (not inside it) and then at an absolute build path baked
			// into the binary. scripts/build.sh copies these into the app bundle instead.
			exclude: [
				"Localization"
			],
			swiftSettings: [
				.defaultIsolation(MainActor.self),
				.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
				.enableUpcomingFeature("InferIsolatedConformances")
			]
		)
	]
)
