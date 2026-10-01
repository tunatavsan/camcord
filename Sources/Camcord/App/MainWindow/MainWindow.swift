import AppKit
import Observation
import SwiftUI

/// The window's module selection, owned by the controller so the menu (⌘, and ⌘1…⌘4) and the
/// live check can move it from outside the view tree. Every change is persisted.
@MainActor @Observable
final class MainWindowModel {
    @ObservationIgnored let defaults: UserDefaults
    var selection: ModuleID {
        didSet {
            guard selection != oldValue else { return }
            ModuleSelection.save(selection, to: defaults)
            if oldValue != .settings { returnModule = oldValue }
        }
    }

    /// The sidebar is shown (the toolbar button and ⌃⌘S hide it).
    var sidebarVisible = true

    /// The native split view and View menu mutate the same visibility value.
    var sidebarColumnVisibility: NavigationSplitViewVisibility {
        get { sidebarVisible ? .all : .detailOnly }
        set {
            // In this SwiftUI runtime, .automatic compares equal to .doubleColumn.
            // Both resolve to the shown two-column shell; only .detailOnly hides it.
            sidebarVisible = newValue != .detailOnly
        }
    }

    /// The Settings group on screen; while Settings is open the sidebar lists the groups (SPEC N3).
    var settingsGroup: SettingsGroup {
        didSet { defaults.set(settingsGroup.rawValue, forKey: SettingsGroup.defaultsKey) }
    }

    /// Where "← Camcord" in the Settings sidebar goes back to.
    private(set) var returnModule: ModuleID = .library

    init(defaults: UserDefaults) {
        self.defaults = defaults
        selection = ModuleSelection.load(from: defaults)
        settingsGroup = SettingsGroup.load(from: defaults)
    }

    /// Leaves Settings for the module it was opened from.
    func leaveSettings() { select(returnModule == .settings ? .library : returnModule) }

    /// Selects `id`, or the first available module when `id` cannot be selected.
    func select(_ id: ModuleID) { selection = ModuleRegistry.selectable(id) }
}

/// Controller-owned visibility of the main window. Studio consumers may run preview/test
/// resources only while `allowsLivePreview` is true; active recording has a separate owner.
@MainActor @Observable
final class MainWindowLifecycle {
    private(set) var allowsLivePreview = false

    func update(window: NSWindow?, temporarilyHidden: Bool) {
        allowsLivePreview = window?.isVisible == true && !temporarilyHidden
            && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true
    }
}

/// The native inset sidebar and unified toolbar frame the module's lightly frosted content.
/// Window chrome belongs to the split view; toolbar actions belong to the current module.
struct MainWindowView: View {
    @Bindable var model: MainWindowModel
    let services: AppServices?
    let lifecycle: MainWindowLifecycle?
    let studioPresentationProvider: (any StudioPresentationProvider)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: MainWindowModel, services: AppServices? = nil, lifecycle: MainWindowLifecycle? = nil,
         studioPresentationProvider: (any StudioPresentationProvider)? = nil) {
        self.model = model
        self.services = services
        self.lifecycle = lifecycle
        self.studioPresentationProvider = studioPresentationProvider
    }

    /// A window of its own for offscreen renders and tests.
    init(defaults: UserDefaults, services: AppServices? = nil) {
        self.init(model: MainWindowModel(defaults: defaults), services: services)
    }

    private var module: any CamcordModule { ModuleRegistry.module(model.selection) ?? ModuleRegistry.all[0] }

    var body: some View {
        NavigationSplitView(columnVisibility: $model.sidebarColumnVisibility) {
            ZStack {
                if model.selection == .settings {
                    SettingsSidebar(model: model)
                        .transition(.opacity)
                } else {
                    MainWindowSidebar(selection: $model.selection)
                        .transition(.opacity)
                }
            }
            .animation(Theme.Motion.resolve(Theme.Motion.panel, reduceMotion: reduceMotion),
                       value: model.selection == .settings)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let library = services?.library { LibrarySidebarFooter(store: library) }
            }
            .navigationSplitViewColumnWidth(Theme.Navigation.sidebarWidth)
        } detail: {
            ZStack {
                module.makeView()
                    .id(model.selection)
                    .transition(.opacity)
            }
            .animation(Theme.Motion.resolve(Theme.Motion.moduleSwitch, reduceMotion: reduceMotion), value: model.selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .windowBackdrop(.content)
            .navigationTitle(Text(module.title))
        }
        .navigationSplitViewStyle(.balanced)
        .animation(Theme.Motion.resolve(Theme.Motion.panel, reduceMotion: reduceMotion), value: model.sidebarVisible)
        .frame(minWidth: 880, minHeight: 560)
        .tint(Theme.Palette.ink.color)
        .environment(\.appServices, services)
        .environment(\.screenshotEditorSession, services?.editor)
        .environment(\.studioSession, services?.studioSession)
        .environment(\.studioPresentationProvider, studioPresentationProvider)
        .environment(\.studioSelectRegionAction, StudioRuntimeCallbacks.regionAction(services))
        .environment(\.studioClipboardClaim, StudioRuntimeCallbacks.clipboardClaim(services))
        .modifier(EditorOpeningConfirmationModifier(session: services?.editor))
        .environment(\.mainWindowModel, model)
        .environment(\.mainWindowLifecycle, lifecycle)
        .background(EditorDocumentEditedBridge(edited: services?.editor.hasUnsavedEdits == true)
            .frame(width: 0, height: 0))
    }
}

private struct EditorDocumentEditedBridge: NSViewRepresentable {
    let edited: Bool
    func makeNSView(context: Context) -> EditedDocumentView { EditedDocumentView() }
    func updateNSView(_ view: EditedDocumentView, context: Context) {
        view.edited = edited
        view.window?.isDocumentEdited = edited
    }
    final class EditedDocumentView: NSView {
        var edited = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isDocumentEdited = edited
        }
    }
}

extension EnvironmentValues {
    /// The window's model, for modules that drive the window (Settings takes over the sidebar).
    @Entry var mainWindowModel: MainWindowModel?
    @Entry var mainWindowLifecycle: MainWindowLifecycle?
}

enum MainWindowLayout {
    static let sidebarWidth = Theme.Navigation.sidebarWidth

    static func totalKnownBytes(_ sizes: some Sequence<Int64>) -> Int64 {
        sizes.reduce(Int64(0)) { total, size in
            let (sum, overflow) = total.addingReportingOverflow(max(size, 0))
            return overflow ? .max : sum
        }
    }
}

/// The sidebar: the mark, then the modules by section, each with its ⌘ key (K1), on its own
/// frosted backdrop. The rows draw the ink selection capsule (KARAR-1), never the user's accent.
private struct MainWindowSidebar: View {
    @Binding var selection: ModuleID

    private var order: [ModuleID] { ModuleRegistry.all.filter(\.isAvailable).map(\.id) }

    var body: some View {
        InkNavigationList(selection: $selection, order: order) { focus in
            ForEach(ModuleRegistry.sections, id: \.self) { section in
                if let title = section.title { InkNavigationHeader(title: title) }
                ForEach(ModuleRegistry.modules(in: section), id: \.id) { module in
                    InkNavigationRow(id: module.id, selection: $selection, focus: focus) {
                        SidebarRow(title: module.title, symbol: module.symbol,
                                   tag: (module as? any ModuleBadging)?.badge,
                                   key: ModuleShortcut.label(for: module.id))
                    }
                    .disabled(!module.isAvailable)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { SidebarBrandHeader() }
        .accessibilityLabel(Text("Modules", comment: "Accessibility: the main window's sidebar"))
    }
}

/// Reference shell facts come from the existing Library, without acquiring a watcher lease.
private struct LibrarySidebarFooter: View {
    @Bindable var store: LibraryStore

    private var version: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Navigation.footerSpacing) {
                decoration
                if let version {
                    Text(verbatim: version)
                    separator
                }
                facts
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if let version {
                    HStack(spacing: Theme.Navigation.footerSpacing) {
                        decoration
                        Text(verbatim: version)
                    }
                }
                facts
            }
        }
        .font(Theme.Font.dataSmall)
        .foregroundStyle(Theme.Palette.ink2.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Theme.Space.s + Theme.Navigation.rowInset)
        .padding(.trailing, Theme.Navigation.rowInset)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.m)
        .accessibilityElement(children: .combine)
    }

    private var facts: some View {
        HStack(spacing: Theme.Navigation.footerSpacing) {
            Text("\(store.items.count) captures")
            separator
            Text(verbatim: ByteCountFormatter.string(
                fromByteCount: MainWindowLayout.totalKnownBytes(store.items.map(\.byteSize)), countStyle: .file))
        }
    }

    private var separator: some View {
        Text(verbatim: "·").accessibilityHidden(true)
    }

    private var decoration: some View {
        // Decorative punctuation, with no assertion about device/store health.
        Circle().fill(Theme.Palette.ink2.color)
            .frame(width: Theme.Navigation.footerDotSize, height: Theme.Navigation.footerDotSize)
            .accessibilityHidden(true)
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

/// Owns the one main window. Closing it (⌘W or the red button) hides it and never quits;
/// the menu-bar item stays. Its frame is autosaved.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let frameAutosaveName = "CamcordMainWindow"

    private let defaults: UserDefaults
    private let frameAutosaveKey: String?
    private let dock: DockController
    private let services: AppServices?
    let model: MainWindowModel
    private let present: @MainActor (NSWindow) -> Void
    private let presentBackground: @MainActor (NSWindow) -> Void
    private let windowFactory: (@MainActor () -> NSWindow)?
    private let isAppActive: @MainActor () -> Bool
    private let waitForRemoval: @MainActor () async throws -> Void
    private var window: NSWindow?
    private let standardUndoManager = UndoManager()
    let lifecycle = MainWindowLifecycle()
    private var presentationGeneration: UInt64 = 0
    private var temporarilyHidden = false
    private var visibilityObservers: [NSObjectProtocol] = []

    init(windowFactory: (@MainActor () -> NSWindow)? = nil,
         presentBackground: (@MainActor (NSWindow) -> Void)? = nil,
         isAppActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
         waitForRemoval: @escaping @MainActor () async throws -> Void = {
             try await Task.sleep(for: .milliseconds(160))
         },
         defaults: UserDefaults = .standard, dock: DockController, services: AppServices? = nil,
         frameAutosaveName: String? = MainWindowController.frameAutosaveName,
         present: (@MainActor (NSWindow) -> Void)? = nil) {
        self.windowFactory = windowFactory
        self.presentBackground = presentBackground ?? { $0.orderBack(nil) }
        self.isAppActive = isAppActive
        self.waitForRemoval = waitForRemoval
        self.defaults = defaults
        self.frameAutosaveKey = frameAutosaveName
        self.dock = dock
        self.services = services
        self.model = MainWindowModel(defaults: defaults)
        self.present = present ?? { window in
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        super.init()
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            visibilityObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSApplication.didHideNotification {
                        self.presentationGeneration &+= 1
                        self.temporarilyHidden = false
                    }
                    self.refreshVisibility()
                }
            })
        }
    }

    isolated deinit {
        for observer in visibilityObservers { NotificationCenter.default.removeObserver(observer) }
    }

    var isOpen: Bool { window?.isVisible == true }
    var presentationEpoch: UInt64 { presentationGeneration }
    var windowForTesting: NSWindow? { window }

    /// Opens the window, on `module` when one is given. `activate: false` (LiveCheck) neither
    /// takes the owner's focus nor covers their work: the window goes behind their windows,
    /// where a window-ID capture still sees all of it.
    func show(module: ModuleID? = nil, activate: Bool = true) {
        presentationGeneration &+= 1
        temporarilyHidden = false
        if let module { model.select(module) }
        let window = window ?? makeWindow()
        self.window = window
        if window.contentViewController == nil { installContent(in: window) }
        // The Dock icon first, so the window opens as a regular app's window, in front.
        dock.windowDidOpen()
        if activate { present(window) } else { presentBackground(window) }
        refreshVisibility()
    }

    func close() {
        presentationGeneration &+= 1
        temporarilyHidden = false
        window?.close()
        refreshVisibility()
    }

    /// The window steps out of the way while `work` captures the screen, then comes back as it
    /// was, so a capture started from the toolbar never shows Camcord's own window.
    func stepAside(during work: @MainActor () async -> Void) async {
        presentationGeneration &+= 1
        let generation = presentationGeneration
        guard let window, window.isVisible else {
            await work()
            return
        }
        let wasKey = window.isKeyWindow
        temporarilyHidden = true
        window.orderOut(nil)
        refreshVisibility()
        defer {
            if presentationGeneration == generation {
                temporarilyHidden = false
                refreshVisibility()
            }
        }
        do { try await waitForRemoval() } catch { return }
        guard presentationGeneration == generation, !Task.isCancelled else { return }
        await work()
        guard presentationGeneration == generation, self.window === window,
              window.contentViewController != nil, !Task.isCancelled else { return }
        if wasKey, isAppActive() { window.makeKeyAndOrderFront(nil) } else { presentBackground(window) }
    }

    private func refreshVisibility() {
        lifecycle.update(window: window, temporarilyHidden: temporarilyHidden)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { refreshVisibility() }
    func windowDidMiniaturize(_ notification: Notification) {
        presentationGeneration &+= 1
        temporarilyHidden = false
        refreshVisibility()
    }
    func windowDidDeminiaturize(_ notification: Notification) { refreshVisibility() }

    /// A fresh SwiftUI tree. Setting a content view controller resizes the window to the
    /// controller's view, so the frame the owner left is put back afterwards.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        model.selection == .edit ? services?.editor.editUndoManager ?? standardUndoManager : standardUndoManager
    }
    private func installContent(in window: NSWindow) {
        let frame = window.frame
        let host = EditorUndoHostingController(rootView: MainWindowView(model: model, services: services, lifecycle: lifecycle))
        host.activeEditor = { [weak self] in self?.model.selection == .edit ? self?.services?.editor : nil }
        // SwiftUI's .toolbar and .navigationTitle become the NSWindow's own toolbar and title.
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = host
        window.setFrame(frame, display: false)
    }

    private func makeWindow() -> NSWindow {
        let window = windowFactory?() ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Camcord"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        // The system sidebar and the detail's one behind-window backdrop sample the desktop.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.delegate = self
        installContent(in: window)
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.center()
        // After the first placement, so a saved frame wins over the centred default.
        if windowFactory == nil, let frameAutosaveKey {
            window.setFrameAutosaveName(frameAutosaveKey)
            window.setFrameUsingName(frameAutosaveKey)
        }
        return window
    }

    /// The window is kept for its frame, but its SwiftUI tree is dropped: a closed window that
    /// keeps its tree never runs `onDisappear` and never cancels `.task`, so a camera preview,
    /// a mic meter or a permission poll inside a module would run on, unseen, until quit.
    /// `show()` builds a fresh tree.
    func windowWillClose(_ notification: Notification) {
        presentationGeneration &+= 1
        temporarilyHidden = false
        lifecycle.update(window: nil, temporarilyHidden: false)
        window?.contentViewController = nil
        dock.windowDidClose()
    }
}

/// The native Edit menu follows this responder after ordinary controls in the Editor.
@MainActor final class EditorUndoHostingController<Content: View>: NSHostingController<Content>, NSMenuItemValidation {
    var activeEditor: (() -> EditorSession?)?
    override var undoManager: UndoManager? { activeEditor?()?.editUndoManager ?? super.undoManager }
    @objc func undo(_ sender: Any?) {
        if let text = view.window?.firstResponder as? EditorAnnotationTextView { text.undo(sender) }
        else if let canvas = view.window?.firstResponder as? EditorCanvasNSView { canvas.undo(sender) }
        else { undoManager?.undo() }
    }
    @objc func redo(_ sender: Any?) {
        if let text = view.window?.firstResponder as? EditorAnnotationTextView { text.redo(sender) }
        else if let canvas = view.window?.firstResponder as? EditorCanvasNSView { canvas.redo(sender) }
        else { undoManager?.redo() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if activeEditor?() != nil, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            event.modifierFlags.contains(.shift) ? redo(nil) : undo(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let session = activeEditor?() {
            if menuItem.action == #selector(undo(_:)) { return session.canUndo }
            if menuItem.action == #selector(redo(_:)) { return session.canRedo }
        }
        if menuItem.action == #selector(undo(_:)) { return undoManager?.canUndo == true }
        if menuItem.action == #selector(redo(_:)) { return undoManager?.canRedo == true }
        return true
    }
}
