import AppKit
import AVFoundation
import SwiftUI

if CommandLine.arguments.contains("--check-scrolling") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in exit(await ScrollCaptureCheck.run()) }
    app.run()
    exit(0)
}

if CommandLine.arguments.contains("--check-camera-recording") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in exit(await CameraRecordingCheck.run()) }
    app.run()
    exit(0)
}

// A bounded hardware check: logs only permission, dimensions and fresh-frame count.
// No camera pixels, screen capture, microphone audio or media files leave memory.
if CommandLine.arguments.contains("--check-camera") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        print("camera permission: \(status.rawValue)")
        guard status == .authorized else { exit(2) }
        let source = CameraCapture()
        do {
            let settings = RecordingSettings.load(from: .standard)
            try await source.start(deviceID: settings.camera.resolved().deviceID, fps: settings.fps)
            let deadline = ContinuousClock.now + .seconds(4)
            var previous: CVPixelBuffer?
            var frames = 0
            var dimensions = "none"
            while ContinuousClock.now < deadline, frames < 30 {
                if let frame = source.latestFrame(), frame !== previous {
                    frames += 1
                    dimensions = "\(CVPixelBufferGetWidth(frame))x\(CVPixelBufferGetHeight(frame))"
                    previous = frame
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
            await source.stop()
            print("camera fresh frames: \(frames), dimensions: \(dimensions)")
            exit(frames >= 10 ? 0 : 3)
        } catch {
            await source.stop()
            print("camera error: \(error)")
            exit(1)
        }
    }
    app.run()
    exit(0)
}

if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-settings") {
    let directory = CommandLine.arguments.indices.contains(flagIndex + 1)
        ? CommandLine.arguments[flagIndex + 1]
        : FileManager.default.temporaryDirectory.path
    SettingsPreviewRenderer.renderAll(to: URL(fileURLWithPath: directory, isDirectory: true))
    exit(0)
}

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

// Development and installed bundles share the same global input bindings. Never
// register a second set. The running-app check also recognizes older releases that
// predate the process lock; flock closes the simultaneous-launch race for new builds.
let bundleID = Bundle.main.bundleIdentifier ?? "dev.tavsan.camcord"
let currentApplication = NSRunningApplication.current
let currentLaunch = currentApplication.launchDate ?? .distantPast
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { candidate in
    guard candidate.processIdentifier != currentApplication.processIdentifier, !candidate.isTerminated else { return false }
    let launch = candidate.launchDate ?? .distantPast
    // Deterministic election: simultaneous launches cannot both see a peer and exit.
    return launch < currentLaunch || (launch == currentLaunch && candidate.processIdentifier < currentApplication.processIdentifier)
}) {
    exit(0)
}
let instanceLock: AppInstanceLock
do {
    instanceLock = try AppInstanceLock(url: AppInstanceLock.defaultURL)
} catch AppInstanceLock.LockError.alreadyRunning {
    exit(0)
} catch {
    FileHandle.standardError.write(Data("Camcord could not acquire its capture session: \(error)\n".utf8))
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
withExtendedLifetime(instanceLock) { app.run() }
