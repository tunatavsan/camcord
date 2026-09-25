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

/// The main window (docs/design/native/SPEC.md S1): the system's split view with its glass
/// sidebar of modules, the selected module's page, and the capture keys and Record in the
/// window's own toolbar. Native first (SPEC N1): nothing here draws its own chrome.
struct MainWindowView: View {
    @Bindable var model: MainWindowModel
    let services: AppServices?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: MainWindowModel, services: AppServices? = nil) {
        self.model = model
        self.services = services
    }

    /// A window of its own for offscreen renders and tests.
    init(defaults: UserDefaults, services: AppServices? = nil) {
        self.init(model: MainWindowModel(defaults: defaults), services: services)
    }

    private var module: any CamcordModule { ModuleRegistry.module(model.selection) ?? ModuleRegistry.all[0] }

    var body: some View {
        NavigationSplitView {
            MainWindowSidebar(selection: $model.selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 228, max: 280)
        } detail: {
            ZStack {
                module.makeView()
                    .id(model.selection)
                    .transition(.opacity)
            }
            .animation(Theme.Motion.resolve(Theme.Motion.moduleSwitch, reduceMotion: reduceMotion), value: model.selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Palette.window.color)
            .navigationTitle(Text(module.title))
            .toolbar { CaptureToolbar(services: services) }
        }
        .frame(minWidth: 880, minHeight: 560)
        .tint(Theme.Palette.ink.color)
        .environment(\.appServices, services)
    }
}

/// The sidebar: the mark, then the modules by section, each with its ⌘ key (K1). The system
/// draws the glass and the selection; the rows are plain labels.
private struct MainWindowSidebar: View {
    @Binding var selection: ModuleID

    var body: some View {
        List(selection: $selection) {
            ForEach(ModuleRegistry.sections, id: \.self) { section in
                Section {
                    ForEach(ModuleRegistry.modules(in: section), id: \.id) { module in
                        SidebarRow(title: module.title, symbol: module.symbol,
                                   tag: (module as? any ModuleBadging)?.badge,
                                   key: ModuleShortcut.label(for: module.id))
                            .tag(module.id)
                            .selectionDisabled(!module.isAvailable)
                    }
                } header: {
                    if let title = section.title { Text(title) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { SidebarHeader() }
    }
}

/// The mark and the app's name at the top of the sidebar.
private struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ViewfinderMarkView(dot: .plain)
                .frame(width: 18, height: 18)
            Text(verbatim: "Camcord")
                .font(Theme.Font.rowStrong)
        }
        .foregroundStyle(Theme.Palette.ink.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension ModuleSection {
    /// The sidebar's section headers: the first section needs none.
    var title: LocalizedStringResource? {
        switch self {
        case .capture: nil
        case .create: LocalizedStringResource("Create", comment: "Sidebar section: making things from captures")
        case .app: LocalizedStringResource("App", comment: "Sidebar section: the app itself")
        }
    }
}

/// ⌘1…⌘4 pick the modules in registry order (K1).
enum ModuleShortcut {
    @MainActor static func index(of id: ModuleID) -> Int? {
        ModuleRegistry.all.firstIndex { $0.id == id }.flatMap { $0 < 9 ? $0 + 1 : nil }
    }

    @MainActor static func label(for id: ModuleID) -> String? {
        index(of: id).map { "⌘\($0)" }
    }
}

/// The window's capture entry (K1): the five capture keys as one toolbar group, then Record on
/// its own. System toolbar items; the system draws their glass (K2.1).
private struct CaptureToolbar: ToolbarContent {
    let services: AppServices?

    var body: some ToolbarContent {
        // Trailing, as in Apple's own windows: the actions sit at the far end of the toolbar.
        ToolbarItemGroup(placement: .automatic) {
            ForEach(CaptureKind.allCases) { kind in
                Button {
                    services?.capture(kind)
                } label: {
                    Label { Text(kind.title) } icon: { Image(systemName: kind.symbol) }
                }
                .help(CaptureToolbar.help(for: kind))
                .accessibilityLabel(Text(kind.actionTitle))
            }
        }
        ToolbarSpacer(.fixed, placement: .automatic)
        ToolbarItem(placement: .automatic) {
            ToolbarRecordButton(services: services)
                .labelStyle(.titleAndIcon)
        }
    }

    /// "Region  ⇧⌘2": the name and, when one is set, the hotkey.
    @MainActor static func help(for kind: CaptureKind) -> String {
        let name = String(localized: kind.title)
        guard let shortcut = kind.shortcut else { return name }
        return "\(name)  \(shortcut.description)"
    }
}

private struct ToolbarRecordButton: View {
    let services: AppServices?

    var body: some View {
        if let services {
            LiveRecordButton(state: services.recordingState) { services.toggleRecording() }
        } else {
            RecordButton(size: .toolbar) {}
        }
    }
}

/// Record / Stop, following the recording state.
private struct LiveRecordButton: View {
    @ObservedObject var state: RecordingStateModel
    let action: () -> Void

    var body: some View {
        RecordButton(size: .toolbar,
                     isRecording: state.state != .idle,
                     isBusy: state.isStarting || state.isFinishing,
                     action: action)
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

    /// The window steps out of the way while `work` captures the screen, then comes back as it
    /// was, so a capture started from the toolbar never shows Camcord's own window.
    func stepAside(during work: @MainActor () async -> Void) async {
        guard let window, window.isVisible else {
            await work()
            return
        }
        let wasKey = window.isKeyWindow
        window.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(160))   // the window server removes it from the next frame
        await work()
        if wasKey, NSApp.isActive { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
    }

    /// A fresh SwiftUI tree. Setting a content view controller resizes the window to the
    /// controller's view, so the frame the owner left is put back afterwards.
    private func installContent(in window: NSWindow) {
        let frame = window.frame
        let host = NSHostingController(rootView: MainWindowView(model: model, services: services))
        // SwiftUI's .toolbar and .navigationTitle become the NSWindow's own toolbar and title.
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = host
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
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        installContent(in: window)
        window.setContentSize(NSSize(width: 1180, height: 760))
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
