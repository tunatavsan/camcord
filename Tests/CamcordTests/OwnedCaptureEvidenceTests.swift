import AppKit
import CoreGraphics
import CryptoKit
import IOKit
@preconcurrency import ScreenCaptureKit
import Testing

@testable import Camcord

/// Explicitly launched evidence only. An ordinary test run creates no window or capture here.
@MainActor
@Suite("Owned window capture evidence", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CAMCORD_OWNED_CAPTURE"] == "1"))
struct OwnedCaptureEvidenceTests {
    @Test("Capture only the exact owned window, then publish real pixels to an isolated board")
    func ownedWindow() async throws {
        let configuration = try OwnedCaptureConfiguration()
        let beforeApplication = OwnedCaptureEnvironment()
        _ = NSApplication.shared
        guard !NSApp.isActive, NSApp.setActivationPolicy(.prohibited) else {
            throw OwnedCaptureFailure.activeApplication
        }
        if !NSRunningApplication.current.isFinishedLaunching { NSApp.finishLaunching() }
        let baseline = OwnedCaptureEnvironment()
        guard baseline.frontmostPID == beforeApplication.frontmostPID,
              baseline.mouse == beforeApplication.mouse else { throw OwnedCaptureFailure.environmentChanged }
        try configuration.check(baseline: baseline)

        let suite = "camcord.owned-capture." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ScreenshotSettings(saveToDisk: false)
        settings.saveDirectoryPath = configuration.output.path
        settings.save(to: defaults)
        let board = NSPasteboard(name: .init("camcord.owned-capture." + UUID().uuidString))
        defer { board.releaseGlobally() }

        let screen = try #require(NSScreen.screens.first)
        let size = CGSize(width: 640, height: 420)
        let frame = CGRect(x: screen.visibleFrame.midX - size.width / 2,
                           y: screen.visibleFrame.midY - size.height / 2,
                           width: size.width, height: size.height)
        let beforeCreate = OwnedCaptureEnvironment()
        var phase = "creating-owned-window"
        var closeWindowID: CGWindowID?
        try configuration.check(baseline: baseline)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        defer {
            let beforeClose = OwnedCaptureEnvironment()
            window.orderOut(nil)
            window.close()
            let afterClose = OwnedCaptureEnvironment()
            try? configuration.write([
                "phase": phase, "pid": Int(configuration.pid),
                "windowID": closeWindowID.map { Int($0) } as Any? ?? NSNull(),
                "executablePath": configuration.executable, "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "beforeApplication": beforeApplication.json, "baseline": baseline.json,
                "beforeCreate": beforeCreate.json, "beforeClose": beforeClose.json, "afterClose": afterClose.json,
                "focusRepairAttempted": false,
            ], name: "closed.json")
        }
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.title = "Camcord owned capture source"
        window.contentView = OwnedCaptureSourceView(frame: CGRect(origin: .zero, size: size))
        let afterCreate = OwnedCaptureEnvironment()
        window.orderBack(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let afterPresent = OwnedCaptureEnvironment()
        let windowID = CGWindowID(try #require(window.windowNumber > 0 ? window.windowNumber : nil))
        closeWindowID = windowID
        let originalFrame = try configuration.ownedBounds(window: window, id: windowID)
        phase = "awaiting-capture-start"
        var measurements: [String: Any] = [:]

        var deliveries: [[String: Any]] = []
        var operations = CaptureCoordinator.Operations()
        operations.feedback = false
        operations.screenCaptureAuthorized = { false }
        operations.screenshotSettings = { ScreenshotSettings.load(from: defaults) }
        operations.fullScreen = { throw OwnedCaptureFailure.unsupportedCapture }
        operations.captureFrozenDesktop = { _, _ in throw OwnedCaptureFailure.unsupportedCapture }
        operations.recognize = { _ in throw OwnedCaptureFailure.unsupportedCapture }
        operations.publishText = { _ in Issue.record("Owned capture must not publish text"); return false }
        operations.copyPNG = { image, pointSize, snapshot, allowed, onSave in
            guard !snapshot.saveToDisk else { return false }
            return await ClipboardWriter.copyPNG(image, pointSize: pointSize, to: board,
                saveSettings: snapshot, shouldPublish: {
                    allowed() && (try? configuration.check(baseline: baseline, window: window,
                                                          id: windowID, bounds: originalFrame, requireStart: true)) != nil
                }, onSaveComplete: onSave)
        }
        let coordinator = CaptureCoordinator(operations: operations)
        coordinator.onScreenshotDelivery = { event in
            let value: CapturedScreenshot
            let name: String
            switch event {
            case .ready(let capture): value = capture; name = "ready"
            case .saved(let capture, _): value = capture; name = "saved"
            case .saveFailed(let capture): value = capture; name = "saveFailed"
            }
            deliveries.append(["event": name, "uuid": value.id.uuidString,
                               "originDisplayID": value.originDisplayID.map { Int($0) } as Any? ?? NSNull(),
                               "saveToDiskRequested": value.saveToDiskRequested,
                               "kind": value.kind.rawValue, "pointSize": [value.pointSize.width, value.pointSize.height],
                               "pixels": [value.image.width, value.image.height],
                               "uptime": ProcessInfo.processInfo.systemUptime])
        }

        func metadata() -> [String: Any] {
            ["phase": phase, "pid": Int(configuration.pid), "windowID": windowID,
             "executablePath": configuration.executable, "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
             "windowFrameCG": OwnedCaptureConfiguration.values(originalFrame),
             "windowFrameAppKit": OwnedCaptureConfiguration.values(window.frame),
             "visible": window.isVisible, "key": window.isKeyWindow,
             "beforeCreate": beforeCreate.json, "afterCreate": afterCreate.json, "afterPresent": afterPresent.json,
             "baseline": baseline.json, "currentEnvironment": OwnedCaptureEnvironment().json,
             "activationPolicy": NSApp.activationPolicy().rawValue,
             "pasteboardName": board.name.rawValue, "saveToDisk": false, "deliveries": deliveries,
             "capturePNG": configuration.output.appendingPathComponent("capture.png").path,
             "evidence": "production ScreenshotService.captureWindow plus CaptureCoordinator guarded delivery",
             "coordinatorAcquisition": "UNMEASURED: own-PID exclusion and private window acquisition remain unchanged",
             "measurements": measurements]
        }

        do {
            try configuration.check(baseline: baseline, window: window, id: windowID, bounds: originalFrame)
            try configuration.write(metadata(), name: "ready.json")
            let deadline = ContinuousClock.now + .seconds(300)
            while !configuration.startExists {
                if configuration.finishExists { phase = "finished-before-capture"; return }
                guard ContinuousClock.now < deadline else { throw OwnedCaptureFailure.startTimedOut }
                try configuration.check(baseline: baseline, window: window, id: windowID, bounds: originalFrame)
                try await Task.sleep(for: .milliseconds(100))
            }

            if configuration.finishExists { phase = "finished-before-capture"; return }

            // No SCK enumeration or pixel request occurs before the explicit start file.
            try configuration.check(baseline: baseline, window: window, id: windowID, bounds: originalFrame, requireStart: true)
            phase = "enumerating-exact-owned-window"
            try configuration.write(metadata(), name: "ready.json")
            let content = try await SCShareableContent.current
            try configuration.check(baseline: baseline, window: window, id: windowID, bounds: originalFrame, requireStart: true)
            let target = try #require(content.windows.first {
                $0.windowID == windowID && $0.owningApplication?.processID == configuration.pid
            })
            guard target.frame == originalFrame else { throw OwnedCaptureFailure.ownershipChanged }
            let displays = content.displays.map { (id: $0.displayID, frame: $0.frame) }
            let origin = try #require(CaptureCoordinator.originDisplayID(for: target.frame, displays: displays))
            measurements["sourceWindowFrameCG"] = OwnedCaptureConfiguration.values(target.frame)
            measurements["originDisplayID"] = origin
            measurements["sourceDisplayFramesCG"] = displays.map {
                ["id": $0.id, "frame": OwnedCaptureConfiguration.values($0.frame)] as [String: Any]
            }
            measurements["hidIdleSecondsBeforeCapture"] = try configuration.hidIdleSeconds()
            phase = "capturing-exact-owned-window"
            try configuration.write(metadata(), name: "ready.json")
            try configuration.check(baseline: baseline, window: window, id: windowID, bounds: originalFrame, requireStart: true)
            let captureStart = ContinuousClock.now
            let image = try await ScreenshotService.captureWindow(target, resolutionScale: .native)
            measurements["captureLatencyMs"] = CaptureCoordinator.elapsedMs(since: captureStart)
            try configuration.check(baseline: baseline, window: window, id: windowID, bounds: originalFrame, requireStart: true)
            let deliveryStart = ContinuousClock.now
            let copied = await coordinator.deliverScreenshotForTesting(image, pointSize: target.frame.size,
                                                                       originDisplayID: origin)
            measurements["deliveryLatencyMs"] = CaptureCoordinator.elapsedMs(since: deliveryStart)
            try configuration.check(baseline: baseline, window: window, id: windowID, bounds: originalFrame, requireStart: true)
            try #require(copied == true && deliveries.count == 1 && deliveries.first?["event"] as? String == "ready")
            let png = try #require(board.data(forType: .png))
            try png.write(to: configuration.output.appendingPathComponent("capture.png"), options: .withoutOverwriting)
            measurements["pngBytes"] = png.count
            measurements["pngSHA256"] = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            phase = "captured-awaiting-finish"
            try configuration.write(metadata(), name: "capture.json")
            try configuration.write(metadata(), name: "ready.json")
            while !configuration.finishExists {
                guard ContinuousClock.now < deadline else { throw OwnedCaptureFailure.finishTimedOut }
                try configuration.check(baseline: baseline, window: window, id: windowID, bounds: originalFrame, requireStart: true)
                try await Task.sleep(for: .milliseconds(100))
            }
            phase = "finished"
        } catch {
            phase = "failed-closed"
            var failure = metadata()
            failure["error"] = String(describing: error)
            try? configuration.write(failure, name: "failure.json")
            throw error
        }
    }
}

private enum OwnedCaptureFailure: Error {
    case unsafePath, inactiveSentinel, activeApplication, environmentChanged, ownershipChanged
    case insufficientIdle, missingPermission, unsupportedCapture, startTimedOut, finishTimedOut
}

@MainActor private struct OwnedCaptureEnvironment {
    let mouse = NSEvent.mouseLocation
    let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    let frontmostBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    let appActive = NSApp?.isActive ?? false
    let uptime = ProcessInfo.processInfo.systemUptime
    var json: [String: Any] {
        ["mouseAppKit": [mouse.x, mouse.y], "frontmostPID": Int(frontmostPID),
         "frontmostBundle": frontmostBundle, "appActive": appActive, "uptime": uptime]
    }
}

@MainActor private struct OwnedCaptureConfiguration {
    let output: URL
    let sentinel: URL
    let pid = ProcessInfo.processInfo.processIdentifier
    let executable = Bundle.main.executableURL?.path ?? ""
    var startExists: Bool { (try? regular(output.appendingPathComponent("capture-start"))) == true }
    var finishExists: Bool { (try? regular(output.appendingPathComponent("finish"))) == true }

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let outputPath = try #require(environment["CAMCORD_CAPTURE_OUTPUT"])
        let sentinelPath = try #require(environment["CAMCORD_CAPTURE_GUI_SENTINEL"])
        guard outputPath.hasPrefix("/"), sentinelPath.hasPrefix("/") else { throw OwnedCaptureFailure.unsafePath }
        output = URL(fileURLWithPath: outputPath, isDirectory: true)
        sentinel = URL(fileURLWithPath: sentinelPath)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try LibraryFiles.validateDirectory(output)
        guard output.path != repo.path, !output.path.hasPrefix(repo.path + "/"),
              try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty,
              !executable.isEmpty, Bundle.main.bundleIdentifier != "dev.tavsan.camcord",
              try regular(sentinel) else { throw OwnedCaptureFailure.unsafePath }
    }

    func regular(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true && LibraryFiles.physicalPath(url) == url.path
    }

    func check(baseline: OwnedCaptureEnvironment, window: NSWindow? = nil, id: CGWindowID? = nil,
               bounds: CGRect? = nil, requireStart: Bool = false) throws {
        try Task.checkCancellation()
        try LibraryFiles.validateDirectory(output)
        guard (try? regular(sentinel)) == true else { throw OwnedCaptureFailure.inactiveSentinel }
        guard !NSApp.isActive, NSApp.activationPolicy() == .prohibited else { throw OwnedCaptureFailure.activeApplication }
        let current = OwnedCaptureEnvironment()
        guard current.frontmostPID == baseline.frontmostPID, current.mouse == baseline.mouse,
              Bundle.main.executableURL?.path == executable else { throw OwnedCaptureFailure.environmentChanged }
        guard try hidIdleSeconds() >= 600 else { throw OwnedCaptureFailure.insufficientIdle }
        guard CGPreflightScreenCaptureAccess() else { throw OwnedCaptureFailure.missingPermission }
        if requireStart, !startExists { throw OwnedCaptureFailure.inactiveSentinel }
        if let window, let id {
            guard window.isVisible, !window.isKeyWindow, !window.isMainWindow,
                  try ownedBounds(window: window, id: id) == bounds else { throw OwnedCaptureFailure.ownershipChanged }
        }
    }

    func ownedBounds(window: NSWindow, id: CGWindowID) throws -> CGRect {
        guard window.windowNumber > 0, CGWindowID(window.windowNumber) == id,
              let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let own = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
              (own[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (own[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let dictionary = own[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else {
            throw OwnedCaptureFailure.ownershipChanged
        }
        return frame
    }

    func hidIdleSeconds() throws -> Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { throw OwnedCaptureFailure.insufficientIdle }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else {
            throw OwnedCaptureFailure.insufficientIdle
        }
        return value.doubleValue / 1_000_000_000
    }

    func write(_ value: [String: Any], name: String) throws {
        try LibraryFiles.validateDirectory(output)
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(name), options: .atomic)
    }

    static func values(_ rect: CGRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }
}

@MainActor private final class OwnedCaptureSourceView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        NSColor(calibratedRed: 0.08, green: 0.14, blue: 0.25, alpha: 1).setFill()
        CGRect(x: 24, y: 24, width: bounds.width - 48, height: 88).fill()
        let label = NSAttributedString(string: "Owned window capture", attributes: [
            .font: NSFont.systemFont(ofSize: 28, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        label.draw(at: CGPoint(x: 48, y: 48))
        for row in 0..<6 {
            for column in 0..<10 {
                (row + column).isMultiple(of: 2) ? NSColor.systemBlue.setFill() : NSColor.systemOrange.setFill()
                CGRect(x: 24 + column * 58, y: 144 + row * 38, width: 48, height: 28).fill()
            }
        }
    }
}
