import AppKit
import SwiftUI

/// Developer-only native layout fixtures. Uses isolated preferences and never starts
/// capture, grants permissions, or registers shortcuts/event taps.
@MainActor
enum SettingsPreviewRenderer {
    static func renderAll(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let suiteName = "dev.tavsan.camcord.settings-preview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var recording = RecordingSettings()
        recording.outputDirectoryPath = directory.appendingPathComponent("Recordings").path
        recording.save(to: defaults)
        ScreenshotSettings(saveToDisk: true, saveDirectoryPath: directory.appendingPathComponent("Screenshots").path)
            .save(to: defaults)
        let coordinator = CaptureCoordinator()
        let controller = RecordingController(coordinator: coordinator)
        let tap = EventTapEngine(coordinator: coordinator, recordingController: controller)
        tap.apply(TapBindings(mouseButton3: nil, mouseButton4: nil, mouseButton5: nil, doubleTapRightCommand: nil))
        for scheme in ["light", "dark"] {
            for section in SettingsSection.allCases {
                let view = SettingsRootView(eventTapEngine: tap, defaultsSuite: defaults, selection: section)
                    .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                    // WindowServer owns behind-window blur; an offscreen cache does not
                    // composite it faithfully. Render the genuine accessibility fallback
                    // for layout checks, and verify the material separately in a live window.
                    .environment(\.camcordOpaqueMaterialPreview, true)
                    .transaction { $0.disablesAnimations = true }
                guard let png = PanelPreviewRenderer.nativePNG(for: view, scheme: scheme, size: CGSize(width: 800, height: 640)) else { continue }
                let url = directory.appendingPathComponent("settings-\(section.rawValue)-\(scheme)-opaque.png")
                try? png.write(to: url)
                print(url.path)
            }
        }
    }
}
