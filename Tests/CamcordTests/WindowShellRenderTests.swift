import AppKit
import CoreText
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import Camcord

/// Root-only compositor/CUA evidence. The default test run creates no app or window here.
@MainActor
@Suite("Window shell native evidence", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CAMCORD_SHELL_WINDOWS"] == "1"))
struct WindowShellRenderTests {
    @Test("Present the actual controller shell with isolated Library content and native chrome")
    func nativeShell() async throws {
        let configuration = try ShellConfiguration()
        guard configuration.isAuthorized else { throw CocoaError(.userCancelled) }
        let fixture = try await ShellFixture(configuration: configuration)
        defer { fixture.close() }
        try await fixture.present()
        try fixture.writeMetadata()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(180))
        while clock.now < deadline, configuration.isAuthorized,
              !FileManager.default.fileExists(atPath: configuration.finish.path), !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(250))
            // Observe actual CUA navigation/visibility changes; never drive a product state.
            try fixture.writeMetadata()
        }
        #expect(!fixture.services.recordingController.isBusy)
        #expect(!fixture.services.studioSession.cameraPreviewRequested)
        #expect(!fixture.services.studioSession.microphoneTestRequested)
    }
}

@MainActor
private struct ShellConfiguration {
    let output: URL
    let sentinel: URL
    let size: CGSize
    let appearance: NSAppearance.Name
    let module: ModuleID
    let emptyLibrary: Bool
    var finish: URL { output.appendingPathComponent("finish") }
    var isAuthorized: Bool { FileManager.default.fileExists(atPath: sentinel.path) }

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        sentinel = URL(fileURLWithPath: try #require(environment["CAMCORD_SHELL_GUI_SENTINEL"]))
        output = URL(fileURLWithPath: try #require(environment["CAMCORD_SHELL_OUTPUT"]), isDirectory: true)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard output.path == LibraryFiles.physicalPath(output),
              output.path != package.path, !output.path.hasPrefix(package.path + "/"),
              (try output.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
              try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty else {
            throw LibraryFiles.Failure.unsafePath
        }
        size = environment["CAMCORD_SHELL_SIZE"] == "small"
            ? CGSize(width: 980, height: 640) : CGSize(width: 1180, height: 772)
        appearance = environment["CAMCORD_SHELL_APPEARANCE"] == "light" ? .aqua : .darkAqua
        module = environment["CAMCORD_SHELL_MODULE"] == "settings" ? .settings : .library
        emptyLibrary = environment["CAMCORD_SHELL_LIBRARY"] == "empty"
    }
}

@MainActor
private final class ShellFixture {
    let configuration: ShellConfiguration
    let services: AppServices
    let controller: MainWindowController
    private let suite: String
    private let defaults: UserDefaults
    private let captures: URL
    private let cache: URL
    private let ownedImages: [URL]
    private var neutral: NSWindow?
    private var launchCompletion: [String: Any] = [:]

    init(configuration: ShellConfiguration) async throws {
        self.configuration = configuration
        suite = "camcord.window-shell." + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suite))
        captures = configuration.output.appendingPathComponent("captures", isDirectory: true)
        cache = configuration.output.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        var images: [URL] = []
        if !configuration.emptyLibrary {
            for (index, name) in ["Capture workflow", "Review checklist", "Layout notes", "Source selection",
                                  "Export review", "Window details"].enumerated() {
                let url = captures.appendingPathComponent(name + ".png")
                try ShellCaptureImage.write(index: index, title: name, to: url)
                images.append(url)
            }
        }
        ownedImages = images
        var screenshot = ScreenshotSettings()
        screenshot.saveDirectoryPath = captures.path
        screenshot.save(to: defaults)
        var recording = RecordingSettings()
        recording.outputDirectoryPath = captures.path
        recording.camera.enabled = false
        recording.microphone = false
        recording.systemAudio = false
        recording.save(to: defaults)
        var retention = LibrarySettings()
        retention.keepCopied = false
        retention.save(to: defaults)
        let library = LibraryStore(defaults: defaults, roots: [.init(url: captures, origin: .savedFile)],
                                   cacheDirectory: cache)
        await library.refresh()
        #expect(library.items.count == images.count)
        library.selection = Set(library.items.prefix(1).map(\.id))
        for item in library.items { _ = await library.thumbnails.image(for: item) }

        let fixtureDefaults = defaults
        let coordinator = CaptureCoordinator(operations: .init(
            screenCaptureAuthorized: { false }, screenshotSettings: { ScreenshotSettings.load(from: fixtureDefaults) },
            fullScreen: { throw CocoaError(.featureUnsupported) },
            captureFrozenDesktop: { _, _ in throw CocoaError(.featureUnsupported) },
            publishText: { _ in Issue.record("Shell evidence must not publish clipboard text"); return false },
            copyPNG: { _, _, _, _, _ in Issue.record("Shell evidence must not copy pixels"); return false },
            feedback: false))
        let recordingController = RecordingController(coordinator: coordinator, defaults: defaults)
        let state = RecordingStateModel()
        let microphone = MicrophoneMonitor(operations: .init(authorize: {
            Issue.record("Shell evidence must not request microphone access"); return false
        }))
        let camera = CameraPreviewMonitor(operations: .init(authorize: { _ in
            Issue.record("Shell evidence must not request camera access"); return false
        }))
        let studio = StudioSession(defaults: defaults, controller: recordingController, recordingState: state,
                                   coordinator: coordinator, microphoneMonitor: microphone, cameraMonitor: camera,
                                   operations: .init(screenCaptureAuthorized: { false }, content: { _ in
            Issue.record("Shell evidence must not discover screen sources"); throw CocoaError(.featureUnsupported)
        }))
        let editor = EditorSession(defaults: defaults)
        let eventTap = EventTapEngine(coordinator: coordinator, recordingController: recordingController,
                                     buttonIsDown: { _ in false }, monitorsLifecycle: false)
        services = AppServices(defaults: defaults, coordinator: coordinator, recordingController: recordingController,
                               eventTapEngine: eventTap, recordingState: state, library: library, editor: editor,
                               studioSession: studio)
        // The tour is of shell callbacks. Even accidental body Copy cannot change the owner's clipboard.
        library.claimClipboardPublication = { { false } }
        editor.claimClipboardPublication = { { false } }
        controller = MainWindowController(presentBackground: { $0.orderBack(nil) }, isAppActive: { false },
            defaults: defaults, dock: DockController(defaults: defaults) { _ in }, services: services,
            frameAutosaveName: nil, present: { _ in Issue.record("Shell evidence must not activate") })
        services.mainWindow = controller
        controller.model.settingsGroup = .general
    }

    func present() async throws {
        guard configuration.isAuthorized else { throw CocoaError(.userCancelled) }
        _ = NSApplication.shared
        let wasActive = NSApp.isActive
        let wasFinishedLaunching = NSRunningApplication.current.isFinishedLaunching
        let fixtureHost = Bundle.main.bundleIdentifier == "dev.tavsan.camcord.window-shell-fixture"
            && NSApp.activationPolicy() == .accessory
        let finishLaunchingCalled = fixtureHost && !wasFinishedLaunching
        if finishLaunchingCalled { NSApp.finishLaunching() }
        launchCompletion = [
            "eligibleFixtureHost": fixtureHost, "finishLaunchingCalled": finishLaunchingCalled,
            "activeBefore": wasActive, "activeAfter": NSApp.isActive,
            "finishedLaunchingBefore": wasFinishedLaunching,
            "finishedLaunchingAfterCall": NSRunningApplication.current.isFinishedLaunching
        ]
        #expect(NSApp.isActive == wasActive)
        controller.show(module: configuration.module, activate: false)
        let window = try #require(controller.windowForTesting)
        window.appearance = NSAppearance(named: configuration.appearance)
        // Comparison geometry is the outer native frame, matching the actual CSS window crop.
        window.setFrame(NSRect(origin: window.frame.origin, size: configuration.size), display: true)
        #expect(window.frameAutosaveName.isEmpty)
        #expect(window.contentViewController is NSHostingController<MainWindowView>)
        #expect(window.toolbarStyle == .unified)
        #expect(window.styleMask.contains(.fullSizeContentView))
        let underlay = NSWindow(contentRect: window.frame.insetBy(dx: -40, dy: -40), styleMask: .borderless,
                                backing: .buffered, defer: false)
        underlay.isReleasedWhenClosed = false
        underlay.hidesOnDeactivate = false
        underlay.ignoresMouseEvents = true
        underlay.setAccessibilityHidden(true)
        underlay.setAccessibilityElement(false)
        underlay.isExcludedFromWindowsMenu = true
        underlay.appearance = window.appearance
        underlay.contentView = ShellUnderlayView(frame: NSRect(origin: .zero, size: underlay.frame.size),
                                                appearance: configuration.appearance)
        underlay.title = "Camcord shell neutral underlay"
        neutral = underlay
        underlay.orderBack(nil)
        window.order(.above, relativeTo: underlay.windowNumber)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // Yield to native toolbar installation, checking readiness instead of a fixed render delay.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while window.toolbar == nil, clock.now < deadline, configuration.isAuthorized {
            await Task.yield()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        _ = try #require(window.toolbar)
        #expect(NSApp.isActive == wasActive)
        #expect(!window.isKeyWindow)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try #require(window.standardWindowButton(kind))
            #expect(button.window === window)
            #expect(!button.isHidden && button.bounds.width > 0 && button.bounds.height > 0)
        }
    }

    func writeMetadata() throws {
        guard let window = controller.windowForTesting else { return }
        let windows = ([window] + (neutral.map { [$0] } ?? [])).map { nativeWindow in
            var buttons: [[String: Any]] = []
            for (name, kind) in [("close", NSWindow.ButtonType.closeButton), ("minimize", .miniaturizeButton),
                                 ("fullscreen", .zoomButton)] {
                guard let button = nativeWindow.standardWindowButton(kind) else { continue }
                buttons.append(["name": name, "frameInWindow": rect(button.convert(button.bounds, to: nil)),
                                "hidden": button.isHidden, "enabled": button.isEnabled])
            }
            return ["windowID": nativeWindow.windowNumber, "pid": Int(ProcessInfo.processInfo.processIdentifier),
                    "title": nativeWindow.title, "frame": rect(nativeWindow.frame),
                    "contentRect": rect(nativeWindow.contentRect(forFrameRect: nativeWindow.frame)),
                    "contentViewBounds": rect(nativeWindow.contentView?.bounds ?? .zero),
                    "styleMask": nativeWindow.styleMask.rawValue, "key": nativeWindow.isKeyWindow,
                    "visible": nativeWindow.isVisible, "miniaturized": nativeWindow.isMiniaturized,
                    "buttons": buttons, "toolbarItems": nativeWindow.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []]
                as [String: Any]
        }
        try write(windows, to: "windows.json")
        let metadata: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "executablePath": ProcessInfo.processInfo.arguments.first ?? "",
            "bundleIdentifier": Bundle.main.bundleIdentifier as Any? ?? NSNull(),
            "bundleURL": Bundle.main.bundleURL.path,
            "bundleExecutableURL": Bundle.main.executableURL?.path as Any? ?? NSNull(),
            "bundleShortVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as Any? ?? NSNull(),
            "activationPolicy": NSApp.activationPolicy().rawValue,
            "finishedLaunching": NSRunningApplication.current.isFinishedLaunching,
            "launchCompletion": launchCompletion,
            "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            "increaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "appActive": NSApp.isActive, "module": controller.model.selection.rawValue,
            "sidebarVisible": controller.model.sidebarVisible,
            "settingsGroup": controller.model.settingsGroup.rawValue,
            "captureCount": services.library.items.count,
            "knownBytes": MainWindowLayout.totalKnownBytes(services.library.items.map(\.byteSize)),
            "requestedOuterSize": [configuration.size.width, configuration.size.height],
            "appearance": configuration.appearance.rawValue,
            "frameAutosaveName": window.frameAutosaveName,
            "underlay": "owned reference-wall gradient; no foreground overlay",
            "sidebarContentWidth": Theme.Navigation.sidebarWidth,
            "referenceSidebarBoundary": Theme.Navigation.sidebarBoundary,
            "measuredNativeSidebarInset": Theme.Navigation.nativeSidebarInset
        ]
        try write(metadata, to: "state.json")
        if let root = window.contentView?.superview ?? window.contentView {
            try write(["windowID": window.windowNumber,
                       "pid": Int(ProcessInfo.processInfo.processIdentifier),
                       "root": nativeView(root)] as [String: Any], to: "view-tree.json")
        }
    }

    private func rect(_ rect: NSRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }

    /// Public AppKit properties of the actual controller window, including native frame views.
    private func nativeView(_ view: NSView) -> [String: Any] {
        var data: [String: Any] = [
            "class": NSStringFromClass(type(of: view)), "frame": rect(view.frame),
            "bounds": rect(view.bounds), "frameInWindow": rect(view.convert(view.bounds, to: nil)),
            "hidden": view.isHidden, "hiddenByAncestor": view.isHiddenOrHasHiddenAncestor,
            "alpha": view.alphaValue, "appearance": view.effectiveAppearance.name.rawValue
        ]
        if let effect = view as? NSVisualEffectView {
            data["visualEffect"] = [
                "material": effect.material.rawValue, "blendingMode": effect.blendingMode.rawValue,
                "state": effect.state.rawValue, "emphasized": effect.isEmphasized
            ]
        }
        if let glass = view as? NSGlassEffectView {
            var effect: [String: Any] = ["style": glass.style.rawValue, "cornerRadius": glass.cornerRadius,
                                        "hasContentView": glass.contentView != nil]
            glass.effectiveAppearance.performAsCurrentDrawingAppearance {
                if let tint = glass.tintColor?.usingColorSpace(.sRGB) {
                    effect["tintRGBA"] = [tint.redComponent, tint.greenComponent, tint.blueComponent, tint.alphaComponent]
                }
            }
            data["glassEffect"] = effect
        }
        data["subviews"] = view.subviews.map(nativeView)
        return data
    }

    private func write(_ object: Any, to name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configuration.output.appendingPathComponent(name), options: [.atomic])
    }

    func close() {
        controller.close()
        neutral?.orderOut(nil)
        neutral?.close()
        neutral = nil
        services.editor.stop()
        services.studioSession.setVisibility(moduleVisible: false, windowAllowsPreview: false, captureTransition: false)
        defaults.removePersistentDomain(forName: suite)
        // Exact owned image files only; evidence metadata remains for review.
        for url in ownedImages where (try? LibraryFiles.regularFile(url, in: captures)) == true {
            try? FileManager.default.removeItem(at: url)
        }
        for directory in [captures, cache] where
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// The reference's wall colors live behind the real native window, never over its sidebar.
@MainActor
private final class ShellUnderlayView: NSView {
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

/// Owned source images; the actual Library scans/decodes them rather than rendering mock cards.
@MainActor
private enum ShellCaptureImage {
    static func write(index: Int, title: String, to url: URL) throws {
        let context = try #require(CGContext(data: nil, width: 960, height: 600, bitsPerComponent: 8,
            bytesPerRow: 3840, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: index.isMultiple(of: 2) ? 0.96 : 0.90, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 600))
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.fill(CGRect(x: 60, y: 496, width: CGFloat(280 + index * 24), height: 8))
        let font = CTFontCreateWithName(NSFont.systemFont(ofSize: 30).fontName as CFString, 30, nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 0.18, alpha: 1)]
        context.textPosition = CGPoint(x: 60, y: 436)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: attributes)), context)
        for row in 0..<4 {
            context.setFillColor(CGColor(gray: 0.70 + CGFloat(row) * 0.035, alpha: 1))
            context.fill(CGRect(x: 60, y: CGFloat(344 - row * 66),
                                width: CGFloat(580 - row * 58 + index * 8), height: 20))
        }
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
