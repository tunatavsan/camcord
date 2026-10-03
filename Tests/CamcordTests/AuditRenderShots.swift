import AppKit
import SwiftUI
import Testing

@testable import Camcord

/// RUN UI-1 B1: an OFFSCREEN render of every surface that can be built without a live screen,
/// for the UI audit (docs/design/audit). Not a screenshot: materials and Liquid Glass are
/// compositor effects and render flat or empty here. Off unless CAMCORD_AUDIT_SHOTS=<dir>.
@MainActor
@Suite("Audit render shots", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CAMCORD_AUDIT_SHOTS"] != nil))
struct AuditRenderShots {
    private let directory = ProcessInfo.processInfo.environment["CAMCORD_AUDIT_SHOTS"] ?? NSTemporaryDirectory()
    private let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    /// Draws `view` in an offscreen window at 2×, in the given appearance.
    private func shoot(_ view: NSView, size: CGSize, name: String, appearance: NSAppearance.Name) throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = appearance == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        view.frame = CGRect(origin: .zero, size: size)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        view.layoutSubtreeIfNeeded()
        try write(view, name: name)
        window.contentView = nil
    }

    private func write(_ view: NSView, name: String) throws {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
    }

    /// The content views of windows that appeared since `before`.
    private func newWindows(since before: Set<ObjectIdentifier>) -> [NSWindow] {
        NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) }
    }

    @Test("panel states")
    func panel() throws {
        _ = NSApplication.shared
        let model = RecordingStateModel()
        let states: [(String, () -> Void)] = [
            ("idle", { model.state = .idle; model.isArmed = false; model.finishedURL = nil; model.isFinishing = false }),
            ("armed", { model.state = .idle; model.isArmed = true }),
            ("recording", { model.isArmed = false; model.state = .recording; model.elapsed = "1:24" }),
            ("paused", { model.state = .paused }),
            ("finished", { model.state = .idle; model.finishedURL = URL(fileURLWithPath: "/tmp/camcord.mov") }),
        ]
        for (state, apply) in states {
            apply()
            for (look, appearance) in appearances {
                let host = NSHostingView(rootView: CapturePanelView(model: model, actions: PanelActions())
                    .environment(\.camcordDesignPreview, true))
                try shoot(host, size: host.fittingSize, name: "panel-\(state)-\(look)", appearance: appearance)
            }
        }
    }

    @Test("settings pages")
    func settings() throws {
        _ = NSApplication.shared
        let store = SettingsStore(defaults: .standard, eventTapEngine: nil)
        for group in SettingsGroup.allCases {
            for (look, appearance) in appearances {
                let host = NSHostingView(rootView: SettingsPageView(group: group, store: store))
                try shoot(host, size: CGSize(width: 800, height: 640), name: "settings-\(group.rawValue)-\(look)",
                          appearance: appearance)
            }
        }
    }

    @Test("main window modules")
    func mainWindow() throws {
        _ = NSApplication.shared
        let defaults = try #require(UserDefaults(suiteName: "camcord.audit.shots"))
        for id in ModuleID.allCases {
            defaults.set(id.rawValue, forKey: ModuleSelection.defaultsKey)
            for (look, appearance) in appearances {
                let host = NSHostingView(rootView: MainWindowView(defaults: defaults))
                try shoot(host, size: CGSize(width: 980, height: 640), name: "main-\(id.rawValue)-\(look)",
                          appearance: appearance)
            }
        }
        defaults.removePersistentDomain(forName: "camcord.audit.shots")
    }

    @Test("hub, camera tile, toast, screenshot card, scroll HUD")
    func floatingSurfaces() throws {
        _ = NSApplication.shared
        let area = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        for mode in [RecordingHubMode.armed, .recording] {
            for open in [false, true] {
                let hub = RecordingHubPanel(defaults: UserDefaults(suiteName: "camcord.audit.hub")!, panelPresenter: { _ in })
                hub.tileFrame = { nil }
                hub.showForTesting(mode: mode, area: area)
                hub.setElapsed("1:24")
                if open { hub.setHoveredForTesting(true) }
                hub.settleForTesting()
                // Glass and frost are compositor effects and draw nothing offscreen: this is the
                // hub's own marks on a dark stand-in for them.
                let content = hub.viewForTesting
                let rep = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor(white: 0.1, alpha: 1).setFill()
                NSBezierPath(roundedRect: content.bounds, xRadius: content.bounds.height / 2, yRadius: content.bounds.height / 2).fill()
                NSGraphicsContext.restoreGraphicsState()
                content.cacheDisplay(in: content.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: "\(directory)/hub-\(mode == .armed ? "armed" : "recording")-\(open ? "open" : "closed").png"))
                hub.hide()
            }
        }

        let tile = FloatingCameraView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let video = NSImage(size: NSSize(width: 320, height: 180))
        video.lockFocus()
        NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: NSRect(x: 0, y: 0, width: 320, height: 180), angle: 30)
        video.unlockFocus()
        tile.image = video
        try shoot(tile, size: tile.frame.size, name: "camera-tile-live", appearance: .darkAqua)
        let warming = FloatingCameraView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        try shoot(warming, size: warming.frame.size, name: "camera-tile-warming", appearance: .darkAqua)

        let drawn = NSImage(size: NSSize(width: 800, height: 500), flipped: false) { rect in
            NSGradient(starting: .white, ending: .systemBlue)?.draw(in: rect, angle: 90)
            return true
        }
        let shot = try #require(drawn.cgImage(forProposedRect: nil, context: nil, hints: nil))

        for (name, show) in [
            ("toast", { HUDToast().show(text: "Kopyalandı", systemSymbol: "checkmark.circle.fill", respectsSetting: false, duration: 30) }),
            ("screenshot-card", { ScreenshotPreviewCard().show(capture: CapturedScreenshot(id: UUID(), image: shot, pointSize: drawn.size, kind: .screenshot, saveToDiskRequested: false)) }),
            ("scroll-hud", { ScrollPreviewPanel().show(near: CGRect(x: 400, y: 300, width: 600, height: 500),
                                                        onDone: {}, onCancel: {}, onToggleAuto: {}) }),
        ] as [(String, () -> Void)] {
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            show()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            for (index, window) in newWindows(since: before).enumerated() {
                guard let content = window.contentView, content.bounds.width > 1 else { continue }
                try write(content, name: "\(name)-\(index)")
                window.orderOut(nil)
            }
        }
    }
}
