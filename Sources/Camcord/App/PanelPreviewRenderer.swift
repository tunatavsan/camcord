import AppKit
import SwiftUI

/// Headless design harness: renders the panel's visual states to PNG files so the
/// design can be inspected and iterated without launching the app and clicking.
/// Invoked via `Camcord --render-panel <dir>` (see main.swift).
@MainActor
enum PanelPreviewRenderer {
    static func renderAll(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let states: [(name: String, state: RecordingController.UIState, elapsed: String?)] = [
            ("panel-idle", .idle, nil),
            ("panel-recording", .recording, "1:07"),
            ("panel-paused", .paused, "1:07"),
        ]

        for scheme in ["dark", "light"] {
            for entry in states {
                let model = RecordingStateModel()
                model.state = entry.state
                model.elapsed = entry.elapsed
                // ImageRenderer can't render AppKit-backed views — simulate the
                // popover backdrop with a flat color per scheme.
                let backdrop = scheme == "dark"
                    ? Color(red: 0.16, green: 0.16, blue: 0.17)
                    : Color(red: 0.94, green: 0.94, blue: 0.95)
                let view = CapturePanelView(model: model, actions: PanelActions())
                    .background(backdrop)
                    .environment(\.colorScheme, scheme == "dark" ? .dark : .light)

                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard
                    let nsImage = renderer.nsImage,
                    let tiff = nsImage.tiffRepresentation,
                    let rep = NSBitmapImageRep(data: tiff),
                    let png = rep.representation(using: .png, properties: [:])
                else {
                    FileHandle.standardError.write(Data("render failed: \(entry.name)-\(scheme)\n".utf8))
                    continue
                }
                let url = directory.appendingPathComponent("\(entry.name)-\(scheme).png")
                try? png.write(to: url)
                print(url.path)
            }
        }
    }
}
