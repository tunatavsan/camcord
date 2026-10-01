import AppKit
import SwiftUI
import Testing

@testable import Camcord

private actor MainWindowEditorDecodeGate {
    private var started = false
    private var observer: CheckedContinuation<Void, Never>?
    private var work: CheckedContinuation<Void, Never>?
    func suspend() async { started = true; observer?.resume(); observer = nil; await withCheckedContinuation { work = $0 } }
    func waitForStart() async { if started { return }; await withCheckedContinuation { observer = $0 } }
    func resume() { work?.resume(); work = nil }
}

@MainActor private struct RetainedModuleTestShell: View {
    @Bindable var model: MainWindowModel
    var body: some View {
        RetainedModuleStack(selection: model.selection, model: model) { RetainedModuleTestPage(id: $0) }
    }
}

@MainActor private struct RetainedModuleTestPage: View {
    let id: ModuleID
    @State private var identity = UUID()
    @State private var edits = 0
    @Environment(\.mainWindowModuleActive) private var active
    var body: some View {
        RetainedModuleProbe(id: id, identity: identity, edits: edits, active: active) { edits += 1 }
    }
}

@MainActor private struct RetainedModuleProbe: NSViewRepresentable {
    let id: ModuleID
    let identity: UUID
    let edits: Int
    let active: Bool
    let edit: () -> Void
    final class ProbeView: NSButton {
        var module = ModuleID.library
        var identity = UUID()
        var edits = 0
        var active = false
        var resigns = 0
        override var acceptsFirstResponder: Bool { true }
        override func resignFirstResponder() -> Bool { resigns += 1; return super.resignFirstResponder() }
        var edit: (() -> Void)?
        @objc func changeValue() { edit?() }
    }
    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.target = view; view.action = #selector(ProbeView.changeValue)
        return view
    }
    func updateNSView(_ view: ProbeView, context: Context) {
        view.module = id; view.identity = identity; view.edits = edits; view.active = active
        view.edit = edit; view.isEnabled = context.environment.isEnabled
    }
}

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

    private func moduleProbes(in view: NSView) -> [RetainedModuleProbe.ProbeView] {
        (view as? RetainedModuleProbe.ProbeView).map { [$0] } ?? view.subviews.flatMap(moduleProbes)
    }

    private func settle(_ host: NSView, until predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate(), "The retained module tree did not reach the expected state")
    }

    @Test("visited modules retain view identity and local edits, inactive controls stop immediately")
    func retainedModuleIdentity() async throws {
        _ = NSApplication.shared
        let defaults = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let model = MainWindowModel(defaults: defaults)
        let host = NSHostingView(rootView: RetainedModuleTestShell(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = offscreenWindow()
        window.contentView = host
        defer { window.contentView = nil }
        try await settle(host) { moduleProbes(in: host).count == 1 }
        let first = try #require(moduleProbes(in: host).first)
        let identity = first.identity
        first.changeValue()
        try await settle(host) { first.edits == 1 }
        for id in [ModuleID.studio, .edit, .settings, .studio, .library] {
            model.select(id)
            try await settle(host) {
                let probes = moduleProbes(in: host)
                return probes.filter(\.active).map(\.module) == [id]
                    && probes.allSatisfy { $0.isEnabled == $0.active }
            }
        }
        let probes = moduleProbes(in: host)
        #expect(probes.count == 4)
        #expect(Set(probes.map(\.module)) == Set(ModuleID.allCases))
        let revisited = try #require(probes.first { $0.module == .library })
        #expect(revisited === first)
        #expect(revisited.identity == identity && revisited.edits == 1)
        #expect(!window.isVisible && !window.isKeyWindow)
        window.contentView = nil
        let reopened = NSHostingView(rootView: RetainedModuleTestShell(model: model))
        reopened.frame = host.frame
        window.contentView = reopened
        try await settle(reopened) { moduleProbes(in: reopened).count == 1 }
        let fresh = try #require(moduleProbes(in: reopened).first)
        #expect(fresh.identity != identity && fresh.edits == 0)
    }

    @Test("module selection clears the retained window responder without activating or touching another window")
    func moduleSelectionFocus() async throws {
        _ = NSApplication.shared
        let defaults = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let model = MainWindowModel(defaults: defaults), lifecycle = MainWindowLifecycle()
        let host = NSHostingView(rootView: RetainedModuleTestShell(model: model)
            .environment(\.mainWindowLifecycle, lifecycle))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = offscreenWindow(), other = offscreenWindow()
        let otherField = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        other.contentView = otherField
        other.makeFirstResponder(otherField)
        let otherResponder = other.firstResponder
        window.fixtureVisible = true
        lifecycle.update(window: window, temporarilyHidden: false)
        window.contentView = host
        defer { window.contentView = nil; other.contentView = nil }
        try await settle(host) { moduleProbes(in: host).count == 1 }
        let probe = try #require(moduleProbes(in: host).first)
        #expect(window.makeFirstResponder(probe))
        #expect(window.firstResponder === probe)
        let active = NSApp.isActive
        let priorResigns = probe.resigns
        model.select(.settings)
        try await settle(host) { window.firstResponder !== probe }
        #expect(probe.resigns == priorResigns + 1)
        #expect(NSApp.isActive == active)
        #expect(other.firstResponder === otherResponder)
        let settings = try #require(moduleProbes(in: host).first { $0.module == .settings })
        #expect(window.makeFirstResponder(settings))
        let settingsResigns = settings.resigns
        window.fixtureVisible = false
        lifecycle.update(window: nil, temporarilyHidden: false)
        try await settle(host) { window.firstResponder !== settings }
        #expect(settings.resigns == settingsResigns + 1)
        #expect(other.firstResponder === otherResponder)
        #expect(NSApp.isActive == active)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test("inactive windows retire detail recorders and preserve unrelated controls, including field editors")
    func detailResponderVisibility() throws {
        _ = NSApplication.shared
        let window = offscreenWindow()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let marker = ModuleSelectionResponderBridge.SelectionView(selection: .settings, windowActive: true)
        marker.frame = NSRect(x: 200, y: 0, width: 400, height: 400)
        let recorder = RetainedModuleProbe.ProbeView(frame: NSRect(x: 240, y: 100, width: 100, height: 30))
        final class EditingControl: NSTextField, NSTextViewDelegate {}
        let sidebar = EditingControl(frame: NSRect(x: 20, y: 100, width: 100, height: 30))
        root.addSubview(marker); root.addSubview(recorder); root.addSubview(sidebar)
        window.contentView = root
        defer { window.contentView = nil }
        #expect(window.makeFirstResponder(recorder))
        let resigns = recorder.resigns
        ModuleSelectionResponderBridge.clearResponder(within: marker)
        #expect(window.firstResponder !== recorder && recorder.resigns == resigns + 1)
        #expect(window.makeFirstResponder(sidebar))
        let fieldEditor = NSTextView(frame: marker.frame)
        fieldEditor.isFieldEditor = true
        fieldEditor.delegate = sidebar
        root.addSubview(fieldEditor)
        #expect(window.makeFirstResponder(fieldEditor))
        ModuleSelectionResponderBridge.clearResponder(within: marker)
        #expect(window.firstResponder === fieldEditor)
        let detailField = EditingControl(frame: recorder.frame)
        root.addSubview(detailField)
        fieldEditor.delegate = detailField
        ModuleSelectionResponderBridge.clearResponder(within: marker)
        #expect(window.firstResponder !== fieldEditor)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test("Reduce Motion keeps the module fade and removes translation")
    func moduleMotion() {
        #expect(Theme.Motion.Duration.moduleSwitch == 0.20)
        #expect(Theme.Motion.moduleOffset(active: true, reduceMotion: false) == 0)
        #expect(Theme.Motion.moduleOffset(active: false, reduceMotion: false) == 8)
        #expect(Theme.Motion.moduleOffset(active: false, reduceMotion: true) == 0)
        let spring = Theme.Motion.interactionSpring(keyPath: "opacity", from: 0, to: 1)
        #expect(Theme.Motion.interactionResponse == 0.35)
        #expect(Theme.Motion.interactionDampingRatio == 0.85)
        #expect(abs(spring.damping / (2 * sqrt(spring.mass * spring.stiffness)) - 0.85) < 0.000001)
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

    @Test("the registry: every module once, in order, grouped by section; Edit is the screenshot editor")
    func registry() {
        #expect(ModuleRegistry.all.map(\.id) == [.library, .studio, .edit, .settings])
        #expect(Set(ModuleRegistry.all.map(\.id)) == Set(ModuleID.allCases))
        #expect(ModuleRegistry.sections == [.capture, .create, .app])
        #expect(ModuleRegistry.modules(in: .capture).map(\.id) == [.library, .studio])
        #expect(ModuleRegistry.modules(in: .create).map(\.id) == [.edit])
        #expect(ModuleRegistry.modules(in: .app).map(\.id) == [.settings])
        #expect(ModuleRegistry.all.allSatisfy { $0.isAvailable })
        #expect((ModuleRegistry.module(.edit) as? any ModuleBadging)?.badge == nil)
        let badges = ModuleRegistry.all.compactMap { ($0 as? any ModuleBadging)?.badge }
        #expect(badges.isEmpty)
        #expect(ModuleSection.capture < .create && ModuleSection.create < .app)
        #expect(ModuleSection.capture.title == nil)
        #expect(ModuleSection.create.title?.key == "Create" && ModuleSection.app.title?.key == "App")
        for module in ModuleRegistry.all {
            #expect(NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil) != nil, "\(module.symbol)")
        }
    }

    @Test("⌘1…⌘4 follow the sidebar, in the View menu and on the rows")
    func moduleShortcuts() throws {
        #expect(ModuleRegistry.all.map { ModuleShortcut.label(for: $0.id) } == ["⌘1", "⌘2", "⌘3", "⌘4"])
        final class Target: NSObject { @objc func go(_ sender: Any?) {} }
        let target = Target()
        let menu = try #require(AppMenus.viewMenuItem(target: target, action: #selector(Target.go(_:)),
                                                      toggleSidebar: #selector(Target.go(_:))).submenu)
        let modules = menu.items.filter { $0.representedObject != nil }
        #expect(modules.map(\.keyEquivalent) == ["1", "2", "3", "4"])
        #expect(modules.compactMap { $0.representedObject as? String } == ["library", "studio", "edit", "settings"])
        #expect(modules.allSatisfy { $0.target === target && $0.keyEquivalentModifierMask == .command })
        // Show or hide the sidebar: ⌃⌘S, as in Apple's apps.
        let sidebar = try #require(menu.items.last)
        #expect(sidebar.keyEquivalent == "s" && sidebar.keyEquivalentModifierMask == [.command, .control])
    }

    @Test("a capture from the window steps the window out of the way, then brings it back")
    func stepAside() async throws {
        _ = NSApplication.shared
        let defaults = try freshDefaults()
        let controller = MainWindowController(defaults: defaults, dock: DockController(defaults: defaults) { _ in }) {
            _ in Issue.record("Background tests must not invoke the activating presenter")
        }
        controller.show(activate: false)
        let window = try #require(controller.windowForTesting)
        window.orderBack(nil)
        #expect(window.isVisible)
        #expect(!window.isKeyWindow)
        var visibleDuringWork: Bool?
        await controller.stepAside { visibleDuringWork = window.isVisible }
        #expect(visibleDuringWork == false)
        #expect(window.isVisible)
        window.setFrameAutosaveName("")
        window.close()
    }

    @MainActor final class OffscreenWindow: NSWindow {
        var fixtureVisible = false
        var key = false
        var minimized = false
        var occluded = false
        var backgroundOrders = 0
        var keyOrders = 0
        override var isVisible: Bool { fixtureVisible }
        override var isKeyWindow: Bool { key }
        override var isMiniaturized: Bool { minimized }
        override var occlusionState: NSWindow.OcclusionState { occluded ? [] : [.visible] }
        override func orderBack(_ sender: Any?) { fixtureVisible = true; key = false; backgroundOrders += 1 }
        override func orderOut(_ sender: Any?) { fixtureVisible = false; key = false }
        override func orderFront(_ sender: Any?) { fixtureVisible = true; key = false }
        override func makeKeyAndOrderFront(_ sender: Any?) { fixtureVisible = true; key = true; keyOrders += 1 }
        override func close() {
            fixtureVisible = false
            delegate?.windowWillClose?(Notification(name: NSWindow.willCloseNotification, object: self))
        }
    }

    @MainActor final class DeferredWork {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func complete() { continuation?.resume(); continuation = nil }
    }

    private func offscreenWindow() -> OffscreenWindow {
        OffscreenWindow(contentRect: NSRect(x: 40, y: 50, width: 980, height: 640),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    }

    @Test("late capture completion cannot restore after close, reopening or cancellation",
          arguments: [0, 1, 2, 3, 4, 5])
    func staleStepAside(action: Int) async throws {
        _ = NSApplication.shared
        let defaults = try freshDefaults()
        let window = offscreenWindow()
        let controller = MainWindowController(windowFactory: { window },
            presentBackground: { $0.orderBack(nil) }, isAppActive: { false }, waitForRemoval: {},
            defaults: defaults, dock: DockController(defaults: defaults) { _ in }, present: { _ in
                Issue.record("must not activate")
            })
        let deferred = DeferredWork()
        controller.show(activate: false)
        let originalFrame = window.frame
        #expect(controller.lifecycle.allowsLivePreview)
        let capture = Task { @MainActor in await controller.stepAside { await deferred.wait() } }
        for _ in 0..<100 where deferred.continuation == nil { await Task.yield() }
        #expect(deferred.continuation != nil)
        #expect(!controller.lifecycle.allowsLivePreview)
        if action == 0 { controller.close() }
        if action == 1 { controller.close(); controller.show(activate: false) }
        if action == 2 { capture.cancel() }
        if action == 3 { await controller.stepAside {} }
        if action == 4 { NotificationCenter.default.post(name: NSApplication.didHideNotification, object: nil) }
        if action == 5 {
            window.minimized = true
            controller.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification))
        }
        let orders = window.backgroundOrders
        deferred.complete()
        await capture.value
        #expect(window.backgroundOrders == orders)
        #expect(window.isVisible == (action == 1))
        #expect(controller.lifecycle.allowsLivePreview == (action == 1))
        #expect(window.frame == originalFrame)
        controller.close()
    }

    @Test("restoration preserves key user windows and keeps background windows behind",
          arguments: [false, true])
    func restorationFocus(wasKey: Bool) async throws {
        _ = NSApplication.shared
        let defaults = try freshDefaults()
        let window = offscreenWindow()
        let controller = MainWindowController(windowFactory: { window },
            presentBackground: { $0.orderBack(nil) }, isAppActive: { true }, waitForRemoval: {},
            defaults: defaults, dock: DockController(defaults: defaults) { _ in },
            present: { $0.makeKeyAndOrderFront(nil) })
        controller.show(activate: wasKey)
        let initialBackground = window.backgroundOrders
        let initialKey = window.keyOrders
        await controller.stepAside { #expect(!window.isVisible) }
        #expect(window.backgroundOrders == initialBackground + (wasKey ? 0 : 1))
        #expect(window.keyOrders == initialKey + (wasKey ? 1 : 0))
        #expect(window.isKeyWindow == wasKey)
        #expect(controller.lifecycle.allowsLivePreview)
        window.occluded = true
        controller.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification))
        #expect(!controller.lifecycle.allowsLivePreview)
        window.occluded = false
        window.minimized = true
        controller.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification))
        #expect(!controller.lifecycle.allowsLivePreview)
        window.minimized = false
        controller.windowDidDeminiaturize(Notification(name: NSWindow.didDeminiaturizeNotification))
        #expect(controller.lifecycle.allowsLivePreview)
        controller.close()
        #expect(!controller.lifecycle.allowsLivePreview)
    }

    @Test("the last selected module comes back; an unknown one falls back to Library")
    func selectionPersistence() throws {
        let defaults = try freshDefaults()
        #expect(ModuleSelection.load(from: defaults) == .library)
        ModuleSelection.save(.studio, to: defaults)
        #expect(ModuleSelection.load(from: defaults) == .studio)
        ModuleSelection.save(.settings, to: defaults)
        #expect(ModuleSelection.load(from: defaults) == .settings)
        ModuleSelection.save(.edit, to: defaults)
        #expect(ModuleSelection.load(from: defaults) == .edit)
        defaults.set("timeline", forKey: ModuleSelection.defaultsKey)
        #expect(ModuleSelection.load(from: defaults) == .library)
    }

    @Test("native split view normalizes public visibility values and shares View menu intent")
    func sidebarVisibility() throws {
        let defaults = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let model = MainWindowModel(defaults: defaults)
        #expect(model.sidebarColumnVisibility == .all)
        model.sidebarColumnVisibility = .detailOnly
        #expect(!model.sidebarVisible)
        model.sidebarColumnVisibility = .automatic
        #expect(model.sidebarVisible && model.sidebarColumnVisibility == .all)
        model.sidebarVisible.toggle()
        #expect(model.sidebarColumnVisibility == .detailOnly)
        model.sidebarColumnVisibility = .all
        #expect(model.sidebarColumnVisibility == .all)
        model.sidebarColumnVisibility = .detailOnly
        model.sidebarColumnVisibility = .doubleColumn
        #expect(model.sidebarVisible)
        model.select(.settings)
        #expect(model.sidebarColumnVisibility == .all)
        model.leaveSettings()
        #expect(model.sidebarVisible && model.selection == .library)
    }

    @Test("sidebar Library facts saturate known byte sizes and ignore unknown negative sizes")
    func sidebarLibraryBytes() {
        #expect(MainWindowLayout.totalKnownBytes([Int64]()) == 0)
        #expect(MainWindowLayout.totalKnownBytes([-1, 10, 20]) == 30)
        #expect(MainWindowLayout.totalKnownBytes([Int64.max - 1, 5]) == .max)
    }

    @Test("the window model persists its selection, refuses an unavailable module, and show(module:) moves it")
    func modelSelection() throws {
        _ = NSApplication.shared
        let defaults = try freshDefaults()
        let model = MainWindowModel(defaults: defaults)
        #expect(model.selection == .library)
        model.select(.settings)
        #expect(model.selection == .settings)
        #expect(ModuleSelection.load(from: defaults) == .settings)
        let unavailable = ModuleRegistry.all.first { !$0.isAvailable }?.id
        if let unavailable {
            model.select(unavailable)
            #expect(model.selection == .library)
        }
        let dock = DockController(defaults: defaults) { _ in }
        let controller = MainWindowController(defaults: defaults, dock: dock) { _ in Issue.record("Background tests must not invoke the activating presenter") }
        controller.show(module: .studio, activate: false)
        #expect(controller.model.selection == .studio)
        #expect(ModuleSelection.load(from: defaults) == .studio)
        // Free the autosave name: only one live window may hold it, and the next test needs it.
        controller.windowForTesting?.setFrameAutosaveName("")
        controller.windowForTesting?.close()
    }

    @Test("opening the window gives the Dock icon, closing it takes it away and keeps the window")
    func windowOpensAndCloses() throws {
        _ = NSApplication.shared
        let defaults = try freshDefaults()
        var applied: [NSApplication.ActivationPolicy] = []
        let dock = DockController(defaults: defaults) { applied.append($0) }
        var presented = 0
        let controller = MainWindowController(defaults: defaults, dock: dock) { _ in
            presented += 1
            Issue.record("Background tests must not invoke the activating presenter")
        }
        let wasActive = NSApp.isActive
        controller.show(activate: false)
        let window = try #require(controller.windowForTesting)
        #expect(NSApp.isActive == wasActive)
        #expect(applied == [.regular])
        #expect(presented == 0)
        #expect(window.isVisible)
        #expect(!window.isKeyWindow)
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
        controller.show(activate: false)
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

    /// Builds the real view offscreen; assertions inspect rendered controls and their store.
    private func render(_ view: some View) throws {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 720, height: 480)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

    }

    @Test("Library editor routing preserves pending edits and changes modules only after acceptance")
    func editorRoutingUsesSharedSession() async throws {
        let defaults = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let root = EditorTemporaryExports().directory.deletingLastPathComponent().appendingPathComponent("mainwindow-editor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.png")
        let image = try EditorRendererTests.image()
        try EditorRendered(image: image, pointSize: CGSize(width: 8, height: 6)).png.write(to: source)
        var operations = CaptureCoordinator.Operations(); operations.feedback = false
        let coordinator = CaptureCoordinator(operations: operations)
        let recording = RecordingController(coordinator: coordinator)
        let engine = EventTapEngine(coordinator: coordinator, recordingController: recording,
            bindings: TapBindings(mouseButton3: nil, mouseButton4: nil, mouseButton5: nil, doubleTapRightCommand: nil), buttonIsDown: { _ in false })
        let library = LibraryStore(defaults: defaults, roots: [], cacheDirectory: root.appendingPathComponent("library"))
        let decodeGate = MainWindowEditorDecodeGate()
        let editor = EditorSession(defaults: defaults, worker: EditorWorker(decoder: { url in
            if url.lastPathComponent == "slow.png" { await decodeGate.suspend(); throw EditorError.invalidImage }
            return try EditorRenderer.decode(url)
        }))
        let services = AppServices(defaults: defaults, coordinator: coordinator, recordingController: recording,
                                   eventTapEngine: engine, recordingState: RecordingStateModel(), library: library, editor: editor)
        var presentations = 0
        let window = MainWindowController(defaults: defaults, dock: DockController(defaults: defaults) { _ in },
                                          services: services, present: { _ in presentations += 1 })
        services.mainWindow = window
        #expect(services.editor === editor)
        let open = try #require(library.onOpenScreenshot)
        window.model.select(.library)
        try await open(source)
        #expect(window.model.selection == .edit); #expect(presentations == 0)
        let originalID = editor.document?.id
        editor.add(tool: .redact, from: .zero, to: CGPoint(x: 3, y: 3))
        window.model.select(.library)
        try await open(source)
        #expect(editor.document?.id == originalID); #expect(editor.hasUnsavedEdits)
        #expect(editor.pendingURL == source); #expect(window.model.selection == .library)
        editor.cancelPending(); #expect(window.model.selection == .library)
        try await open(source); await editor.discardAndOpenPending()
        #expect(window.model.selection == .edit); #expect(editor.document?.id != originalID)
        window.model.select(.library)
        await #expect(throws: LibraryStore.ActionFailure.self) { try await open(root.appendingPathComponent("missing.png")) }
        #expect(window.model.selection == .library); #expect(presentations == 0)
        let slow = Task { try await open(root.appendingPathComponent("slow.png")) }
        await decodeGate.waitForStart(); try await open(source); await decodeGate.resume()
        try await slow.value
        #expect(editor.error == nil); #expect(window.model.selection == .edit); #expect(presentations == 0)
        try render(EditModule().makeView())
        try render(EditModule().makeView().environment(\.screenshotEditorSession, editor))
        editor.stop()
    }

    @Test("The actual Editor window routes native Edit menu Undo through toolbar, canvas and its focused text, retaining other-module history")
    func editorNativeUndoRoute() async throws {
        let defaults = try freshDefaults(); defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        var operations = CaptureCoordinator.Operations(); operations.feedback = false
        let coordinator = CaptureCoordinator(operations: operations)
        let recording = RecordingController(coordinator: coordinator)
        let engine = EventTapEngine(coordinator: coordinator, recordingController: recording,
            bindings: TapBindings(mouseButton3: nil, mouseButton4: nil, mouseButton5: nil, doubleTapRightCommand: nil), buttonIsDown: { _ in false })
        let editor = EditorSession()
        let library = LibraryStore(defaults: defaults, roots: [], cacheDirectory: EditorTemporaryExports().directory.appendingPathComponent(UUID().uuidString))
        let services = AppServices(defaults: defaults, coordinator: coordinator, recordingController: recording, eventTapEngine: engine, recordingState: RecordingStateModel(), library: library, editor: editor)
        let controller = MainWindowController(presentBackground: { _ in }, defaults: defaults, dock: DockController(defaults: defaults) { _ in }, services: services, frameAutosaveName: nil, present: { _ in })
        controller.show(module: .edit, activate: false)
        let window = try #require(controller.windowForTesting)
        defer { editor.stop(); controller.close() }
        #expect(window.undoManager === editor.editUndoManager)
        editor.open(CapturedScreenshot(id: UUID(), image: try EditorRendererTests.image(), pointSize: CGSize(width:8,height:6), kind:.screenshot, saveToDiskRequested:false))
        editor.add(tool:.text,from:.zero,to:CGPoint(x:8,y:8))
        let menu = try #require(AppMenus.editingMenuItem().submenu)
        let undoItem = try #require(menu.items.first), redoItem = menu.items[1]
        #expect(undoItem.target == nil && redoItem.target == nil)
        let host = try #require(window.contentViewController as? EditorUndoHostingController<MainWindowView>)
        let button = NSButton(frame:CGRect(x:0,y:0,width:40,height:28)); host.view.addSubview(button)
        #expect(button.tryToPerform(try #require(undoItem.action), with:undoItem))
        #expect(editor.document?.edits.annotations.isEmpty == true)
        #expect(button.tryToPerform(try #require(redoItem.action), with:redoItem))
        #expect(editor.document?.edits.annotations.count == 1)
        let text = EditorAnnotationTextView(frame:CGRect(x:0,y:0,width:160,height:60)); text.session = editor; text.allowsUndo = false; text.delegate = text
        text.string = editor.selectedAnnotation?.text ?? ""
        host.view.addSubview(text); #expect(window.makeFirstResponder(text))
        text.selectAll(nil); text.insertText("One", replacementRange:text.selectedRange())
        text.selectAll(nil); text.insertText("Two", replacementRange:text.selectedRange())
        #expect(editor.selectedAnnotation?.text == "Two")
        #expect(text.undoManager === window.undoManager)
        #expect(text.tryToPerform(try #require(undoItem.action), with:undoItem))
        #expect(editor.selectedAnnotation?.text == "Text" && text.string == "Text")
        #expect(text.tryToPerform(try #require(redoItem.action), with:redoItem))
        #expect(editor.selectedAnnotation?.text == "Two" && text.string == "Two")
        let commandZ = try #require(NSEvent.keyEvent(with:.keyDown, location:.zero, modifierFlags:.command, timestamp:0, windowNumber:window.windowNumber, context:nil, characters:"z", charactersIgnoringModifiers:"z", isARepeat:false, keyCode:6))
        let redoZ = try #require(NSEvent.keyEvent(with:.keyDown, location:.zero, modifierFlags:[.command,.shift], timestamp:0, windowNumber:window.windowNumber, context:nil, characters:"Z", charactersIgnoringModifiers:"z", isARepeat:false, keyCode:6))
        #expect(text.performKeyEquivalent(with:commandZ)); #expect(editor.selectedAnnotation?.text == "Text")
        #expect(text.performKeyEquivalent(with:redoZ)); #expect(editor.selectedAnnotation?.text == "Two")
        window.makeFirstResponder(button)
        let count = editor.document?.edits.annotations.count
        controller.model.select(.settings)
        let standard = try #require(window.undoManager)
        #expect(standard !== editor.editUndoManager)
        #expect(editor.document?.edits.annotations.count == count && editor.canUndo)
        standard.beginUndoGrouping()
        standard.registerUndo(withTarget:button) { button in MainActor.assumeIsolated { button.title = "retained undo" } }
        standard.endUndoGrouping()
        controller.model.select(.edit); #expect(window.undoManager === editor.editUndoManager)
        editor.open(CapturedScreenshot(id:UUID(),image:try EditorRendererTests.image(),pointSize:CGSize(width:8,height:6),kind:.screenshot,saveToDiskRequested:false))
        await editor.discardAndOpenPending()
        #expect(!editor.canUndo && standard.canUndo)
        controller.model.select(.settings); standard.undo(); #expect(button.title == "retained undo")
        #expect(!window.isVisible && !window.isKeyWindow)
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
        let libraryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("mainwindow-library-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: libraryRoot) }
        let library = LibraryStore(defaults: defaults, roots: [], cacheDirectory: libraryRoot)
        let services = AppServices(defaults: defaults, coordinator: coordinator, recordingController: recording,
                                   eventTapEngine: engine, recordingState: RecordingStateModel(), library: library)
        let module = SettingsModule()
        let recorder = SettingsKeyRecorder()
        SettingsKeyRecorder.active = recorder
        defer {
            SettingsKeyRecorder.active = nil
            defaults.removePersistentDomain(forName: Self.suiteName)
        }
        try render(module.makeView())
        #expect(recorder.keys.isEmpty)
        #expect(recorder.stores.isEmpty)
        try render(module.makeView().environment(\.appServices, services))
        #expect(recorder.keys.contains(DockIconMode.defaultsKey))
        #expect(recorder.stores.allSatisfy { $0.defaults === defaults })
        let injectedStore = try #require(recorder.stores.last)
        injectedStore.copyToast = false
        #expect(!HUDToast.isEnabled(in: defaults))

        // The actual window supplies the same services to its Settings module.
        recorder.reset()
        ModuleSelection.save(.settings, to: defaults)
        try render(MainWindowView(defaults: defaults, services: services))
        #expect(!recorder.stores.isEmpty)
        #expect(recorder.stores.allSatisfy { $0.defaults === defaults })
    }
}
