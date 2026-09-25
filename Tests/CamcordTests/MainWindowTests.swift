import AppKit
import SwiftUI
import Testing

@testable import Camcord

/// The main window's seam (K9) and its Dock behaviour (K10): the module registry, the
/// persisted selection, and every Dock policy transition — pure or with an injected setter,
/// so nothing here touches the real Dock.
@MainActor
@Suite("Main window and Dock", .serialized)
struct MainWindowTests {
    private static let suiteName = "camcord.mainwindow.test"

    private func freshDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        return defaults
    }

    @Test("the Dock policy for every mode, window open or closed")
    func policyTable() {
        #expect(DockPolicy.activationPolicy(mode: .whileWindowOpen, windowOpen: true) == .regular)
        #expect(DockPolicy.activationPolicy(mode: .whileWindowOpen, windowOpen: false) == .accessory)
        #expect(DockPolicy.activationPolicy(mode: .always, windowOpen: true) == .regular)
        #expect(DockPolicy.activationPolicy(mode: .always, windowOpen: false) == .regular)
        #expect(DockPolicy.activationPolicy(mode: .never, windowOpen: true) == .accessory)
        #expect(DockPolicy.activationPolicy(mode: .never, windowOpen: false) == .accessory)
    }

    @Test("launch, open, close: the policy each mode applies, and only on a change",
          arguments: [
            (DockIconMode.whileWindowOpen, [NSApplication.ActivationPolicy.accessory, .regular, .accessory]),
            (.always, [.regular]),
            (.never, [.accessory]),
          ])
    func transitions(mode: DockIconMode, expected: [NSApplication.ActivationPolicy]) throws {
        let defaults = try freshDefaults()
        mode.save(to: defaults)
        var applied: [NSApplication.ActivationPolicy] = []
        let dock = DockController(defaults: defaults) { applied.append($0) }
        dock.apply()          // launch
        dock.windowDidOpen()  // the window opens
        dock.windowDidClose() // ⌘W
        #expect(applied == expected)
    }

    @Test("changing the setting while the window is open takes effect at once")
    func settingChange() throws {
        let defaults = try freshDefaults()
        var applied: [NSApplication.ActivationPolicy] = []
        let dock = DockController(defaults: defaults) { applied.append($0) }
        dock.windowDidOpen()
        #expect(applied == [.regular])
        DockIconMode.never.save(to: defaults)
        dock.apply()
        #expect(applied == [.regular, .accessory])
        DockIconMode.always.save(to: defaults)
        dock.windowDidClose()
        #expect(applied == [.regular, .accessory, .regular])
    }

    @Test("the Dock setting defaults to while-the-window-is-open and survives a bad value")
    func dockModePersistence() throws {
        let defaults = try freshDefaults()
        #expect(DockIconMode.load(from: defaults) == .whileWindowOpen)
        DockIconMode.never.save(to: defaults)
        #expect(DockIconMode.load(from: defaults) == .never)
        defaults.set("sometimes", forKey: DockIconMode.defaultsKey)
        #expect(DockIconMode.load(from: defaults) == .whileWindowOpen)
    }

    @Test("the registry: every module once, in order, grouped by section; Edit is Soon")
    func registry() {
        #expect(ModuleRegistry.all.map(\.id) == [.library, .studio, .edit, .settings])
        #expect(Set(ModuleRegistry.all.map(\.id)) == Set(ModuleID.allCases))
        #expect(ModuleRegistry.sections == [.capture, .create, .app])
        #expect(ModuleRegistry.modules(in: .capture).map(\.id) == [.library, .studio])
        #expect(ModuleRegistry.modules(in: .create).map(\.id) == [.edit])
        #expect(ModuleRegistry.modules(in: .app).map(\.id) == [.settings])
        #expect(ModuleRegistry.module(.edit)?.isAvailable == false)
        #expect(ModuleRegistry.all.filter(\.isAvailable).map(\.id) == [.library, .studio, .settings])
        #expect(ModuleSection.capture < .create && ModuleSection.create < .app)
        for module in ModuleRegistry.all {
            #expect(NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil) != nil, "\(module.symbol)")
        }
    }

    @Test("the last selected module comes back; an unavailable or unknown one falls back to Library")
    func selectionPersistence() throws {
        let defaults = try freshDefaults()
        #expect(ModuleSelection.load(from: defaults) == .library)
        ModuleSelection.save(.studio, to: defaults)
        #expect(ModuleSelection.load(from: defaults) == .studio)
        ModuleSelection.save(.settings, to: defaults)
        #expect(ModuleSelection.load(from: defaults) == .settings)
        ModuleSelection.save(.edit, to: defaults)
        #expect(ModuleSelection.load(from: defaults) == .library)
        defaults.set("timeline", forKey: ModuleSelection.defaultsKey)
        #expect(ModuleSelection.load(from: defaults) == .library)
    }

    @Test("opening the window gives the Dock icon, closing it takes it away and keeps the window")
    func windowOpensAndCloses() throws {
        _ = NSApplication.shared
        let defaults = try freshDefaults()
        var applied: [NSApplication.ActivationPolicy] = []
        let dock = DockController(defaults: defaults) { applied.append($0) }
        var presented = 0
        let controller = MainWindowController(defaults: defaults, dock: dock) { window in
            presented += 1
            window.orderFront(nil)
        }
        controller.show()
        let window = try #require(controller.windowForTesting)
        #expect(applied == [.regular])
        #expect(presented == 1)
        #expect(window.frameAutosaveName == MainWindowController.frameAutosaveName)
        #expect(!window.isReleasedWhenClosed)
        #expect(window.styleMask.contains(.closable))

        #expect(window.contentViewController != nil)
        window.setFrame(NSRect(x: 120, y: 140, width: 1010, height: 660), display: false)
        let frame = window.frame

        window.performClose(nil)
        #expect(applied == [.regular, .accessory])
        #expect(!controller.isOpen)
        // The SwiftUI tree goes with the close, so nothing inside it keeps running unseen.
        #expect(window.contentViewController == nil)

        // Reopening reuses the same window (its frame) with a fresh tree.
        controller.show()
        #expect(controller.windowForTesting === window)
        #expect(window.contentViewController != nil)
        #expect(window.frame == frame)
        #expect(applied == [.regular, .accessory, .regular])
        window.close()
    }

    @Test("two preview surfaces hold the camera preview independently")
    func previewOwnersAreIndependent() {
        let monitor = CameraPreviewMonitor()
        let module = CameraPreviewMonitor.makeOwnerID("settings")
        let window = CameraPreviewMonitor.makeOwnerID("settings")
        #expect(module != window)
        monitor.setVisible(true, owner: module)
        monitor.setVisible(true, owner: window)
        monitor.setVisible(false, owner: window)
        #expect(monitor.isObserved)
        monitor.setVisible(false, owner: module)
        #expect(!monitor.isObserved)
    }

    /// The pixels of `view` rendered offscreen at 1×.
    private func pixels(_ view: some View) throws -> Data {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 720, height: 480)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.tiffRepresentation)
    }

    @Test("the Settings module renders the real settings from the environment's services, the placeholder without")
    func settingsModuleUsesTheEnvironment() throws {
        _ = NSApplication.shared
        let defaults = try freshDefaults()
        let coordinator = CaptureCoordinator()
        let recording = RecordingController(coordinator: coordinator)
        let engine = EventTapEngine(
            coordinator: coordinator, recordingController: recording,
            bindings: TapBindings(mouseButton3: nil, mouseButton4: nil, mouseButton5: nil, doubleTapRightCommand: nil),
            buttonIsDown: { _ in false }
        )
        let services = AppServices(defaults: defaults, coordinator: coordinator, recordingController: recording,
                                   eventTapEngine: engine, recordingState: RecordingStateModel())
        let module = SettingsModule()
        let bare = try pixels(module.makeView())
        let placeholder = try pixels(ModulePlaceholder(
            symbol: module.symbol, title: module.title,
            message: LocalizedStringResource("Settings are loading.", comment: "Settings placeholder")))
        let real = try pixels(module.makeView().environment(\.appServices, services))
        #expect(bare == placeholder)
        #expect(real != placeholder)

        // The window hands its services down to whichever module it shows.
        ModuleSelection.save(.settings, to: defaults)
        let windowWithout = try pixels(MainWindowView(defaults: defaults))
        let windowWith = try pixels(MainWindowView(defaults: defaults, services: services))
        #expect(windowWithout != windowWith)
    }
}
