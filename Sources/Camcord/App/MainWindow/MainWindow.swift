import AppKit
import SwiftUI

/// The main window: a sidebar of modules (the registry) and the selected module's view.
/// Visual-neutral in this run — the system's own split view, sidebar and empty states.
struct MainWindowView: View {
    let defaults: UserDefaults
    @State private var selection: ModuleID

    init(defaults: UserDefaults) {
        self.defaults = defaults
        _selection = State(initialValue: ModuleSelection.load(from: defaults))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
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
            (ModuleRegistry.module(selection) ?? ModuleRegistry.all[0]).makeView()
                .id(selection)
        }
        .onChange(of: selection) { _, id in ModuleSelection.save(id, to: defaults) }
        .frame(minWidth: 760, minHeight: 520)
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
    private let present: @MainActor (NSWindow) -> Void
    private var window: NSWindow?

    init(defaults: UserDefaults = .standard, dock: DockController,
         present: (@MainActor (NSWindow) -> Void)? = nil) {
        self.defaults = defaults
        self.dock = dock
        self.present = present ?? { window in
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        super.init()
    }

    var isOpen: Bool { window?.isVisible == true }
    var windowForTesting: NSWindow? { window }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // The Dock icon first, so the window opens as a regular app's window, in front.
        dock.windowDidOpen()
        present(window)
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
        window.contentViewController = NSHostingController(rootView: MainWindowView(defaults: defaults))
        window.setContentSize(NSSize(width: 980, height: 640))
        window.center()
        // After the first placement, so a saved frame wins over the centred default.
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.setFrameUsingName(Self.frameAutosaveName)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        dock.windowDidClose()
    }
}
