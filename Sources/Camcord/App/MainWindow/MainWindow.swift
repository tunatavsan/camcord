import AppKit
import Observation
import SwiftUI

/// The window's module selection, owned by the controller so the menu (⌘, and ⌘1…⌘4) and the
/// live check can move it from outside the view tree. Every change is persisted.
@MainActor @Observable
final class MainWindowModel {
    @ObservationIgnored let defaults: UserDefaults
    var selection: ModuleID {
        didSet { if selection != oldValue { ModuleSelection.save(selection, to: defaults) } }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        selection = ModuleSelection.load(from: defaults)
    }

    /// Selects `id`, or the first available module when `id` cannot be selected.
    func select(_ id: ModuleID) { selection = ModuleRegistry.selectable(id) }
}

/// The main window: a sidebar of modules (the registry) and the selected module's view.
/// Visual-neutral in this run — the system's own split view, sidebar and empty states.
struct MainWindowView: View {
    @Bindable var model: MainWindowModel
    let services: AppServices?

    init(model: MainWindowModel, services: AppServices? = nil) {
        self.model = model
        self.services = services
    }

    /// A window of its own for offscreen renders and tests.
    init(defaults: UserDefaults, services: AppServices? = nil) {
        self.init(model: MainWindowModel(defaults: defaults), services: services)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(ModuleRegistry.sections, id: \.self) { section in
                    Section {
                        ForEach(ModuleRegistry.modules(in: section), id: \.id) { module in
                            ModuleRow(module: module)
                                .tag(module.id)
                                .selectionDisabled(!module.isAvailable)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            (ModuleRegistry.module(model.selection) ?? ModuleRegistry.all[0]).makeView()
                .id(model.selection)
        }
        .frame(minWidth: 760, minHeight: 520)
        .environment(\.appServices, services)
    }
}

private struct ModuleRow: View {
    let module: any CamcordModule

    var body: some View {
        HStack {
            Label { Text(module.title) } icon: { Image(systemName: module.symbol) }
            if !module.isAvailable {
                Spacer()
                Text("Soon", comment: "Badge on a main-window module that is not available yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(module.isAvailable ? .primary : .secondary)
        .accessibilityHint(module.isAvailable ? Text(verbatim: "") : Text("Not available yet", comment: "Accessibility hint on a module marked Soon"))
    }
}

/// Owns the one main window. Closing it (⌘W or the red button) hides it and never quits;
/// the menu-bar item stays. Its frame is autosaved.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let frameAutosaveName = "CamcordMainWindow"

    private let defaults: UserDefaults
    private let dock: DockController
    private let services: AppServices?
    let model: MainWindowModel
    private let present: @MainActor (NSWindow) -> Void
    private var window: NSWindow?

    init(defaults: UserDefaults = .standard, dock: DockController, services: AppServices? = nil,
         present: (@MainActor (NSWindow) -> Void)? = nil) {
        self.defaults = defaults
        self.dock = dock
        self.services = services
        self.model = MainWindowModel(defaults: defaults)
        self.present = present ?? { window in
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        super.init()
    }

    var isOpen: Bool { window?.isVisible == true }
    var windowForTesting: NSWindow? { window }

    /// Opens the window, on `module` when one is given. `activate: false` (LiveCheck) neither
    /// takes the owner's focus nor covers their work: the window goes behind their windows,
    /// where a window-ID capture still sees all of it.
    func show(module: ModuleID? = nil, activate: Bool = true) {
        if let module { model.select(module) }
        let window = window ?? makeWindow()
        self.window = window
        if window.contentViewController == nil { installContent(in: window) }
        // The Dock icon first, so the window opens as a regular app's window, in front.
        dock.windowDidOpen()
        if activate { present(window) } else { window.orderBack(nil) }
    }

    func close() { window?.close() }

    /// A fresh SwiftUI tree. Setting a content view controller resizes the window to the
    /// controller's view, so the frame the owner left is put back afterwards.
    private func installContent(in window: NSWindow) {
        let frame = window.frame
        window.contentViewController = NSHostingController(rootView: MainWindowView(model: model, services: services))
        window.setFrame(frame, display: false)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Camcord"
        window.isReleasedWhenClosed = false
        window.delegate = self
        installContent(in: window)
        window.setContentSize(NSSize(width: 980, height: 640))
        window.center()
        // After the first placement, so a saved frame wins over the centred default.
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.setFrameUsingName(Self.frameAutosaveName)
        return window
    }

    /// The window is kept for its frame, but its SwiftUI tree is dropped: a closed window that
    /// keeps its tree never runs `onDisappear` and never cancels `.task`, so a camera preview,
    /// a mic meter or a permission poll inside a module would run on, unseen, until quit.
    /// `show()` builds a fresh tree.
    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        dock.windowDidClose()
    }
}
