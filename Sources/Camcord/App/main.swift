import AppKit
import SwiftUI

// Design harness: `Camcord --render-panel <dir>` renders the panel's states to
// PNGs and exits — lets the panel be designed/critiqued headlessly, no clicking.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-panel") {
    let directory = CommandLine.arguments.indices.contains(flagIndex + 1)
        ? CommandLine.arguments[flagIndex + 1]
        : FileManager.default.temporaryDirectory.path
    PanelPreviewRenderer.renderAll(to: URL(fileURLWithPath: directory, isDirectory: true))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
