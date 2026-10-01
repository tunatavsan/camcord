import AppKit
import CoreText
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import Camcord

/// Root-only passive evidence. Normal tests create no window, app service or capture device here.
@MainActor
@Suite("Menu panel native evidence", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CAMCORD_MENU_WINDOWS"] == "1"))
struct MenuPanelRenderTests {
    @Test("Owned idle panel with actual isolated Library files")
    func nativePanel() async throws {
        let environment = ProcessInfo.processInfo.environment
        let sentinel = URL(fileURLWithPath: try #require(environment["CAMCORD_MENU_GUI_SENTINEL"]))
        let output = URL(fileURLWithPath: try #require(environment["CAMCORD_MENU_OUTPUT"]), isDirectory: true)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: sentinel.path),
              output.path == LibraryFiles.physicalPath(output),
              output.path != package.path, !output.path.hasPrefix(package.path + "/"),
              (try output.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
              try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty else {
            throw LibraryFiles.Failure.unsafePath
        }
        _ = NSApplication.shared
        #expect(!NSApp.isActive)
        let appearance: NSAppearance.Name = environment["CAMCORD_MENU_APPEARANCE"] == "light" ? .aqua : .darkAqua
        let empty = environment["CAMCORD_MENU_LIBRARY"] == "empty"
        let suite = "camcord.menu-render." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = output.appendingPathComponent("captures", isDirectory: true)
        let cache = output.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        if !empty {
            for (index, title) in ["Capture workflow", "Review checklist", "Layout notes", "Source selection",
                                    "Export review", "Window details"].enumerated() {
                let url = saved.appendingPathComponent(title + ".png")
                try MenuCaptureImage.write(index: index, title: title, to: url)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(index - 6) * 60)],
                                                     ofItemAtPath: url.path)
            }
        }
        var settings = RecordingSettings()
        settings.camera.enabled = false; settings.microphone = false; settings.systemAudio = false
        settings.save(to: defaults)
        var retention = LibrarySettings(); retention.keepCopied = false; retention.save(to: defaults)
        let store = LibraryStore(defaults: defaults, roots: [.init(url: saved, origin: .savedFile)], cacheDirectory: cache)
        await store.refresh()
        #expect(store.items.count == (empty ? 0 : 6))
        let model = RecordingStateModel()
        model.isPanelVisible = true
        var actions = PanelActions()
        actions.quit = { Issue.record("Passive Menu evidence must not terminate the app") }
        // Other closures are the inert defaults; this host has no clipboard or hardware owner.
        let host = NSHostingController(rootView: CapturePanelView(model: model, actions: actions,
                                                                 library: store, defaults: defaults))
        host.sizingOptions = []
        let size = CGSize(width: CapturePanelView.panelWidth, height: CapturePanelView.panelHeight)
        let screen = try #require(NSScreen.screens.first)
        let origin = CGPoint(x: screen.visibleFrame.midX - size.width / 2,
                             y: screen.visibleFrame.midY - size.height / 2)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.title = "Camcord owned Menu evidence"
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = host
        // Installing the host can adopt its initial zero-sized view. Restore the
        // owned window's actual frame after installation, as the shell fixture does.
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        let underlay = NSWindow(contentRect: window.frame.insetBy(dx: -40, dy: -40), styleMask: .borderless,
                                backing: .buffered, defer: false)
        underlay.isReleasedWhenClosed = false
        underlay.level = .normal
        underlay.hidesOnDeactivate = false
        underlay.ignoresMouseEvents = true
        underlay.setAccessibilityHidden(true)
        underlay.setAccessibilityElement(false)
        underlay.isExcludedFromWindowsMenu = true
        underlay.appearance = window.appearance
        underlay.title = "Camcord owned Menu neutral underlay"
        underlay.contentView = MenuUnderlayView(frame: NSRect(origin: .zero, size: underlay.frame.size),
                                               appearance: appearance)
        defer {
            model.isPanelVisible = false
            host.rootView = CapturePanelView(model: model, actions: actions)
            window.orderOut(nil)
            window.close()
            underlay.orderOut(nil)
            underlay.close()
        }
        underlay.orderBack(nil)
        window.order(.above, relativeTo: underlay.windowNumber)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(!window.isKeyWindow && !NSApp.isActive)
        let finish = output.appendingPathComponent("finish")
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(180))
        while clock.now < deadline, FileManager.default.fileExists(atPath: sentinel.path),
              !FileManager.default.fileExists(atPath: finish.path), !Task.isCancelled {
            try writeMetadata(window: window, underlay: underlay, model: model, store: store, output: output)
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(model.state == .idle && model.elapsed == nil && model.finishedURL == nil)
        #expect(!NSApp.isActive)
    }

    private func writeMetadata(window: NSWindow, underlay: NSWindow, model: RecordingStateModel, store: LibraryStore, output: URL) throws {
        let frame = window.frame
        let contentBounds = try #require(window.contentView?.bounds)
        guard frame.size == CGSize(width: 320, height: 370),
              contentBounds.width > 0, contentBounds.height > 0 else {
            throw CocoaError(.featureUnsupported)
        }
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        var recordSRGB = [CGFloat]()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let color = Theme.Palette.record.ns.usingColorSpace(.sRGB) {
                recordSRGB = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            }
        }
        let state: [String: Any] = ["pid": pid, "executablePath": Bundle.main.executableURL?.path ?? "",
            "appActive": NSApp.isActive, "module": "panel", "actualrecordingState": model.state == .idle ? "idle" : "unexpected",
            "captureCount": store.items.count, "requestedOuterSize": [320, 370], "panelVisible": model.isPanelVisible,
            "appearance": window.effectiveAppearance.name.rawValue,
            "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            "resolvedRecordSRGB": recordSRGB, "resolvedRecordSRGB8": recordSRGB.map { Int(($0 * 255).rounded()) },
            "underlay": "owned CSS-wall gradient behind primary; primary-only OS capture",
            "nativeGlassRegions": nativeGlassRegions(in: window.contentView)]
        let windows: [[String: Any]] = [["primaryID": window.windowNumber, "windowID": window.windowNumber, "pid": pid,
            "frame": [frame.minX, frame.minY, frame.width, frame.height], "key": window.isKeyWindow,
            "contentViewBounds": [contentBounds.minX, contentBounds.minY, contentBounds.width, contentBounds.height],
            "visible": window.isVisible, "title": window.title, "role": "primary"],
            ["windowID": underlay.windowNumber, "pid": pid, "role": "underlay",
             "frame": [underlay.frame.minX, underlay.frame.minY, underlay.frame.width, underlay.frame.height],
             "key": underlay.isKeyWindow, "visible": underlay.isVisible, "title": underlay.title]]
        try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("state.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: windows, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("windows.json"), options: .atomic)
    }

    private func nativeGlassRegions(in root: NSView?) -> [[String: Any]] {
        guard let root else { return [] }
        var result = [[String: Any]]()
        if let glass = root as? NSGlassEffectView {
            let tint = glass.tintColor?.usingColorSpace(.sRGB)
            result.append([
                "class": String(describing: type(of: glass)),
                "bounds": [glass.bounds.minX, glass.bounds.minY, glass.bounds.width, glass.bounds.height],
                "frameInWindow": rectValues(glass.convert(glass.bounds, to: nil)),
                "appearance": glass.effectiveAppearance.name.rawValue,
                "style": String(describing: glass.style), "cornerRadius": glass.cornerRadius,
                "hidden": glass.isHidden, "alphaValue": glass.alphaValue,
                "hasContentView": glass.contentView != nil,
                "tintSRGB": tint.map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent] } ?? []
            ])
        }
        for child in root.subviews { result.append(contentsOf: nativeGlassRegions(in: child)) }
        return result
    }

    private func rectValues(_ rect: NSRect) -> [CGFloat] {
        [rect.minX, rect.minY, rect.width, rect.height]
    }
}

@MainActor private enum MenuCaptureImage {
    static func write(index: Int, title: String, to url: URL) throws {
        let context = try #require(CGContext(data: nil, width: 960, height: 600, bitsPerComponent: 8,
            bytesPerRow: 3840, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 600))
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.fill(CGRect(x: 60, y: 496, width: CGFloat(280 + index * 24), height: 8))
        let font = CTFontCreateWithName(NSFont.systemFont(ofSize: 30).fontName as CFString, 30, nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 0.18, alpha: 1)]
        context.textPosition = CGPoint(x: 60, y: 436)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: attributes)), context)
        for row in 0..<4 {
            context.setFillColor(CGColor(gray: 0.70 + CGFloat(row) * 0.035, alpha: 1))
            context.fill(CGRect(x: 60, y: CGFloat(344 - row * 66), width: CGFloat(580 - row * 58 + index * 8), height: 20))
        }
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

/// Test-only neutral backdrop, using literal Graphite II desktop colors; no application pixels.
private final class MenuUnderlayView: NSView {
    private let light: Bool

    init(frame: NSRect, appearance: NSAppearance.Name) {
        light = appearance == .aqua
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let first = color(light ? 0xB3C1CC : 0x141A22)
        let last = color(light ? 0xE3D7CB : 0x2A2420)
        first.setFill()
        bounds.fill()
        NSGradient(starting: first, ending: last)?.draw(
            from: NSPoint(x: bounds.minX, y: bounds.maxY),
            to: NSPoint(x: bounds.maxX, y: bounds.minY), options: [])
        radial(color(light ? 0xFFF5E8 : 0x325C70, alpha: light ? 0.92 : 0.72),
               at: NSPoint(x: bounds.width * 0.18, y: bounds.height * 0.80), radius: bounds.width * 0.42)
        radial(color(light ? 0x7A9CB8 : 0x925E42, alpha: light ? 0.72 : 0.50),
               at: NSPoint(x: bounds.width * 0.85, y: bounds.height * 0.25), radius: bounds.width * 0.38)
        radial(color(light ? 0xCCC4E4 : 0x544E80, alpha: light ? 0.62 : 0.42),
               at: NSPoint(x: bounds.width * 0.70, y: bounds.height * 0.82), radius: bounds.width * 0.30)
    }

    private func radial(_ color: NSColor, at center: NSPoint, radius: CGFloat) {
        NSGradient(starting: color, ending: color.withAlphaComponent(0))?.draw(
            fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
    }

    private func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
}
