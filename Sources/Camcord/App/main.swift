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

// Motion harness: `Camcord --card-demo` shows ONLY the screenshot preview card (no status
// item / event tap / login item, so it can't disturb a running instance) so its spring-in /
// auto-dismiss motion can be watched. Temporary developer aid.
if CommandLine.arguments.contains("--card-demo") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let demoCard = ScreenshotPreviewCard()
    func makeDemoImage() -> CGImage {
        let w = 620, h = 430
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(NSColor.systemIndigo.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: 210, y: 115, width: 200, height: 200))
        return ctx.makeImage()!
    }
    let demoImage = makeDemoImage()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        demoCard.show(image: demoImage, fileURL: nil)
    }
    // Self-terminate after the spring-in + auto-dismiss has played out.
    DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) { exit(0) }
    _ = demoCard   // keep alive for the process lifetime
    app.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
