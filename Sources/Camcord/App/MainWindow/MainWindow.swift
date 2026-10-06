import AppKit
import Observation
import SwiftUI

/// The window's module selection, owned by the controller so the menu (⌘, and ⌘1…⌘4) and the
/// live check can move it from outside the view tree. Every change is persisted.
@MainActor @Observable
final class MainWindowModel {
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let performanceDiagnostics = NavigationPerformanceDiagnostics()
    @ObservationIgnored var selectionWillChange: (() -> Void)?
    var selection: ModuleID {
        willSet {
            if newValue != selection {
                performanceDiagnostics.request(.module(newValue))
                if newValue == .settings { performanceDiagnostics.request(.settings(settingsGroup)) }
                selectionWillChange?()
            }
        }
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

    /// The Settings group on screen; while Settings is open the sidebar lists the groups.
    var settingsGroup: SettingsGroup {
        willSet {
            if selection == .settings, newValue != settingsGroup {
                performanceDiagnostics.request(.settings(newValue))
                // Retained shortcut fields must end editing before their page becomes hidden.
                selectionWillChange?()
            }
        }
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
    @ObservationIgnored var willBecomeInactive: (() -> Void)?
    private(set) var allowsLivePreview = false {
        willSet { if allowsLivePreview && !newValue { willBecomeInactive?() } }
    }

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
    private let studioCallbacks: StudioRuntimeCallbacks
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(model: MainWindowModel, services: AppServices? = nil, lifecycle: MainWindowLifecycle? = nil,
         studioPresentationProvider: (any StudioPresentationProvider)? = nil) {
        self.model = model
        self.services = services
        self.lifecycle = lifecycle
        self.studioPresentationProvider = studioPresentationProvider
        studioCallbacks = StudioRuntimeCallbacks(services: services)
    }

    /// A window of its own for offscreen renders and tests.
    init(defaults: UserDefaults, services: AppServices? = nil) {
        self.init(model: MainWindowModel(defaults: defaults), services: services)
    }

    private var module: any CamcordModule { ModuleRegistry.module(model.selection) ?? ModuleRegistry.all[0] }

    var body: some View {
        // The sidebar is always shown: no toggle, no collapse.
        NavigationSplitView(columnVisibility: .constant(.all)) {
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
            RetainedModuleStack(selection: model.selection, model: model) { id in
                RegisteredModuleView(id: id, services: services, studioCallbacks: studioCallbacks)
                    .equatable()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .windowBackdrop(.content)
            .navigationTitle(Text(module.title))
        }
        .navigationSplitViewStyle(.balanced)
        // One frosted tray under the whole window; the sidebar and the module float on it.
        .background {
            if !reduceTransparency { TrayBlur().ignoresSafeArea() }
        }
        .animation(Theme.Motion.resolve(Theme.Motion.panel, reduceMotion: reduceMotion), value: model.sidebarVisible)
        // AppKit owns the outer minimum height; a content minimum would add toolbar chrome.
        .frame(minWidth: MainWindowGeometry.minimumSize.width)
        .tint(Theme.Palette.ink.color)
        .environment(\.appServices, services)
        .environment(\.screenshotEditorSession, services?.editor)
        .environment(\.studioSession, services?.studioSession)
        .environment(\.studioPresentationProvider, studioPresentationProvider)
        .modifier(EditorOpeningConfirmationModifier(session: services?.editor))
        .environment(\.mainWindowModel, model)
        .environment(\.mainWindowLifecycle, lifecycle)
        .background(EditorDocumentEditedBridge(edited: services?.editor.hasUnsavedEdits == true)
            .frame(width: 0, height: 0))
    }
}

/// The sidebar is always shown, so the split view's own toggle is hidden.
/// Hidden, not removed: `toolbar(removing: .sidebarToggle)` narrows the native sidebar to
/// 148 pt even with a fixed column width. SwiftUI re-creates the item as the toolbar changes,
/// so the window re-checks it on every update; the check is a few items, and idempotent.
enum SidebarToggleSuppressor {
    @MainActor private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    @MainActor static func watch(_ window: NSWindow) {
        hideToggles(in: window.toolbar)
        let key = ObjectIdentifier(window)
        guard observers[key] == nil else { return }
        observers[key] = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
                                                                object: window, queue: .main) { [weak window] _ in
            MainActor.assumeIsolated { hideToggles(in: window?.toolbar) }
        }
    }

    @MainActor static func hideToggles(in toolbar: NSToolbar?) {
        for item in toolbar?.items ?? [] where isToggle(item) && !item.isHidden { item.isHidden = true }
    }

    @MainActor static func isToggle(_ item: NSToolbarItem) -> Bool {
        item.itemIdentifier == .toggleSidebar || item.itemIdentifier.rawValue.localizedCaseInsensitiveContains("toggleSidebar")
    }
}

/// The registry's fixed modules do not depend on the window's current selection. Their own
/// environment and observed state still update; only recreating the registered content is skipped.
struct RegisteredModuleView: View, Equatable {
    let id: ModuleID
    private let servicesIdentity: ObjectIdentifier?
    private let callbacksIdentity: ObjectIdentifier?
    private let studioCallbacks: StudioRuntimeCallbacks?

    init(id: ModuleID, services: AppServices?, studioCallbacks: StudioRuntimeCallbacks) {
        self.id = id
        servicesIdentity = services.map(ObjectIdentifier.init)
        self.studioCallbacks = id == .studio ? studioCallbacks : nil
        callbacksIdentity = id == .studio ? ObjectIdentifier(studioCallbacks) : nil
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.servicesIdentity == rhs.servicesIdentity && lhs.callbacksIdentity == rhs.callbacksIdentity
    }

    @ViewBuilder var body: some View {
        if let module = ModuleRegistry.module(id) {
            if id == .studio {
                module.makeView()
                    .environment(\.studioSelectRegionAction, studioCallbacks?.selectRegion)
                    .environment(\.studioClipboardClaim, studioCallbacks?.claimClipboard)
            } else {
                module.makeView()
            }
        }
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
    /// Mounted modules own visible UI work only while selected. Standalone views remain active.
    @Entry var mainWindowModuleActive = true
}

/// Each visited module keeps its identity and local state until the window content is removed.
struct RetainedModuleStack<Content: View>: View {
    let selection: ModuleID
    let model: MainWindowModel?
    private let content: (ModuleID) -> Content
    private let reduceMotionOverride: Bool?
    @State private var visited: Set<ModuleID>
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.mainWindowLifecycle) private var lifecycle

    init(selection: ModuleID, model: MainWindowModel? = nil, reduceMotionOverride: Bool? = nil,
         @ViewBuilder content: @escaping (ModuleID) -> Content) {
        self.selection = selection
        self.model = model
        self.content = content
        self.reduceMotionOverride = reduceMotionOverride
        _visited = State(initialValue: [selection])
    }

    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    private var mountedModules: [ModuleID] {
        ModuleRegistry.all.map(\.id).filter { visited.contains($0) || $0 == selection }
    }

    var body: some View {
        ZStack {
            ForEach(mountedModules, id: \.self) { id in
                let active = id == selection
                content(id)
                    .background(PerformanceLayoutCompletionBridge(target: .module(id),
                        active: active && id != .settings, diagnostics: model?.performanceDiagnostics))
                    .environment(\.mainWindowModuleActive, active)
                    .disabled(!active)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
                    .opacity(active ? 1 : 0)
                    .offset(y: Theme.Motion.moduleOffset(active: active, reduceMotion: reduceMotion))
                    // Hide the outgoing content immediately; only the incoming module fades in.
                    .animation(active ? Theme.Motion.resolve(Theme.Motion.moduleSwitch, reduceMotion: reduceMotion) : nil,
                               value: active)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: Theme.Motion.moduleOffset(active: false, reduceMotion: reduceMotion))),
                        removal: .identity))
            }
        }
        .animation(Theme.Motion.resolve(Theme.Motion.moduleSwitch, reduceMotion: reduceMotion), value: mountedModules)
        .onChange(of: selection) { _, id in visited.insert(id) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ModuleSelectionResponderBridge(selection: selection,
            windowActive: lifecycle?.allowsLivePreview ?? true, model: model, lifecycle: lifecycle))
    }
}

/// Clearing a responder belongs to this window alone and never activates the application.
struct ModuleSelectionResponderBridge: NSViewRepresentable {
    let selection: ModuleID
    let windowActive: Bool
    var model: MainWindowModel? = nil
    var lifecycle: MainWindowLifecycle? = nil
    func makeNSView(context: Context) -> SelectionView {
        let view = SelectionView(selection: selection, windowActive: windowActive)
        view.model = model; view.lifecycle = lifecycle
        return view
    }
    func updateNSView(_ view: SelectionView, context: Context) {
        let oldSelection = view.selection
        let changed = oldSelection != selection || view.windowActive != windowActive
        let retireFocus = oldSelection != selection || (view.windowActive && !windowActive)
        view.selection = selection
        view.windowActive = windowActive
        if changed { view.focusGeneration &+= 1 }
        if retireFocus { Self.scheduleRetirement(within: view, previousModule: oldSelection) }
    }
    private static func scheduleRetirement(within detail: SelectionView, previousModule: ModuleID) {
        guard let window = detail.window, let responder = ownedResponder(within: detail) else { return }
        if detail.pendingResponder !== responder {
            detail.pendingResponder = responder
            detail.pendingModule = previousModule
        }
        let generation = detail.focusGeneration
        let owner = detail.pendingModule
        // Resigning during a representable update reenters SwiftUI's focus graph.
        Task { @MainActor [weak detail, weak window, weak responder] in
            guard let detail, let window, let responder, detail.focusGeneration == generation else { return }
            defer { detail.pendingResponder = nil; detail.pendingModule = nil }
            guard window.firstResponder === responder,
                  !detail.windowActive || detail.selection != owner else { return }
            window.makeFirstResponder(nil)
        }
    }
    static func clearResponder(within detail: NSView) {
        guard let window = detail.window, ownedResponder(within: detail) != nil else { return }
        window.makeFirstResponder(nil)
    }
    private static func ownedResponder(within detail: NSView) -> NSView? {
        guard let window = detail.window, let responder = window.firstResponder as? NSView else { return nil }
        // A field editor belongs to the control it edits, even if AppKit hosts it elsewhere.
        let control: NSView
        if let editor = responder as? NSTextView, editor.isFieldEditor, let delegate = editor.delegate as? NSView {
            control = delegate
        } else { control = responder }
        guard control.window === window else { return nil }
        let bounds = detail.convert(detail.bounds, to: nil)
        let controlBounds = control.convert(control.bounds, to: nil)
        guard !bounds.isEmpty, bounds.contains(NSPoint(x: controlBounds.midX, y: controlBounds.midY)) else { return nil }
        return responder
    }
    final class SelectionView: NSView {
        var selection: ModuleID
        var windowActive: Bool
        var focusGeneration: UInt64 = 0
        weak var pendingResponder: NSView?
        var pendingModule: ModuleID?
        weak var model: MainWindowModel?
        weak var lifecycle: MainWindowLifecycle?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            model?.selectionWillChange = { [weak self] in
                if let self { ModuleSelectionResponderBridge.clearResponder(within: self) }
            }
            lifecycle?.willBecomeInactive = { [weak self] in
                if let self { ModuleSelectionResponderBridge.clearResponder(within: self) }
            }
        }
        init(selection: ModuleID, windowActive: Bool) {
            self.selection = selection; self.windowActive = windowActive
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        required init?(coder: NSCoder) { nil }
    }
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

/// The sidebar: the mark, then the modules by section, each with its ⌘ key, on its own
/// frosted backdrop. The rows draw the ink selection capsule, never the user's accent.
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

/// ⌘1…⌘4 pick the modules in registry order.
enum ModuleShortcut {
    @MainActor static func index(of id: ModuleID) -> Int? {
        ModuleRegistry.all.firstIndex { $0.id == id }.flatMap { $0 < 9 ? $0 + 1 : nil }
    }

    @MainActor static func label(for id: ModuleID) -> String? {
        index(of: id).map { "⌘\($0)" }
    }
}

/// Initial outer-frame placement; AppKit continues to own restoration of saved manual frames.
enum MainWindowGeometry {
    static let minimumSize = NSSize(width: 980, height: 640)
    static let maximumDefaultSize = NSSize(width: 1440, height: 900)
    static let legacyContentSize = NSSize(width: 1180, height: 760)

    @MainActor static func applyMinimum(_ size: NSSize, to window: NSWindow) {
        guard window.minSize != size else { return }
        window.minSize = size
        // AppKit expands this setter for a unified toolbar, even with full-size content.
        // Measure its conversion instead of baking a toolbar height into the shell.
        let measured = window.minSize
        if measured != size {
            window.minSize = NSSize(width: max(0, size.width - (measured.width - size.width)),
                                    height: max(0, size.height - (measured.height - size.height)))
        }
    }

    static func defaultFrame(in visibleFrame: NSRect?) -> NSRect {
        guard let visibleFrame, visibleFrame.width.isFinite, visibleFrame.height.isFinite,
              visibleFrame.origin.x.isFinite, visibleFrame.origin.y.isFinite,
              visibleFrame.width > 0, visibleFrame.height > 0 else {
            return NSRect(origin: .zero, size: minimumSize)
        }
        let size = NSSize(
            width: max(minimumSize.width, min(maximumDefaultSize.width, visibleFrame.width * 0.8)),
            height: max(minimumSize.height, min(maximumDefaultSize.height, visibleFrame.height * 0.8)))
        // On a display smaller than the minimum, keep the title bar and left edge reachable.
        return NSRect(x: visibleFrame.minX + max(0, (visibleFrame.width - size.width) / 2),
                      y: visibleFrame.maxY - size.height - max(0, (visibleFrame.height - size.height) / 2),
                      width: size.width, height: size.height)
    }

    static func migrationKey(for autosaveName: String) -> String {
        "MainWindowDefaultFrameMigration.\(autosaveName).v2"
    }

    /// Nil leaves AppKit's restored frame alone. The flag records the first assessment even
    /// when a manual frame wins, so later manual resizing to the old size is never migrated.
    static func initialFrame(savedFrameDescriptor: String?, visibleFrame: NSRect?,
                             defaults: UserDefaults, autosaveName: String?) -> NSRect? {
        let preferred = defaultFrame(in: visibleFrame)
        guard let autosaveName else { return preferred }
        let key = migrationKey(for: autosaveName)
        let assessed = defaults.bool(forKey: key)
        if !assessed { defaults.set(true, forKey: key) }
        guard let saved = savedFrame(from: savedFrameDescriptor) else { return preferred }
        guard !assessed else { return nil }
        return saved.width < preferred.width && saved.height < preferred.height ? preferred : nil
    }

    static func savedFrame(from descriptor: String?) -> NSRect? {
        guard let descriptor else { return nil }
        let fields = descriptor.split(whereSeparator: { $0.isWhitespace }).prefix(4)
        let values = fields.compactMap { Double($0) }
        guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
        return NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
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
    private let visibleFrame: @MainActor (NSWindow) -> NSRect?
    private let isAppActive: @MainActor () -> Bool
    private let waitForRemoval: @MainActor () async throws -> Void
    private var window: NSWindow?
    private let standardUndoManager = UndoManager()
    let lifecycle = MainWindowLifecycle()
    private var presentationGeneration: UInt64 = 0
    private var temporarilyHidden = false
    private var visibilityObservers: [NSObjectProtocol] = []
    private var minimumObservations: [NSKeyValueObservation] = []
    private weak var minimumWindow: NSWindow?
    private var correctingMinimum = false

    init(visibleFrame: @escaping @MainActor (NSWindow) -> NSRect? = { $0.screen?.visibleFrame ?? NSScreen.main?.visibleFrame },
         windowFactory: (@MainActor () -> NSWindow)? = nil,
         presentBackground: (@MainActor (NSWindow) -> Void)? = nil,
         isAppActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
         waitForRemoval: @escaping @MainActor () async throws -> Void = {
             try await Task.sleep(for: .milliseconds(160))
         },
         defaults: UserDefaults = .standard, dock: DockController, services: AppServices? = nil,
         frameAutosaveName: String? = MainWindowController.frameAutosaveName,
         present: (@MainActor (NSWindow) -> Void)? = nil) {
        self.windowFactory = windowFactory
        self.visibleFrame = visibleFrame
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
        for observer in minimumObservations { observer.invalidate() }
    }

    var isOpen: Bool { window?.isVisible == true }
    var presentationEpoch: UInt64 { presentationGeneration }
    var windowForTesting: NSWindow? { window }

    /// Opens the window, on `module` when one is given. `activate: false` (LiveCheck) neither
    /// takes the user's focus nor covers their work: the window goes behind their windows,
    /// where a window-ID capture still sees all of it.
    func show(module: ModuleID? = nil, activate: Bool = true) {
        presentationGeneration &+= 1
        temporarilyHidden = false
        // Establish the opening transaction before selection or frame migration writes
        // defaults; their notifications must already see the window's intended Dock policy.
        dock.windowDidOpen()
        if let module { model.select(module) }
        let window = window ?? makeWindow()
        self.window = window
        if window.contentViewController == nil { installContent(in: window) }
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
    /// controller's view, so the frame the user left is put back afterwards.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        model.selection == .edit ? services?.editor.editUndoManager ?? standardUndoManager : standardUndoManager
    }
    private func installContent(in window: NSWindow) {
        stopObservingMinimum()
        let frame = window.frame
        let host = EditorUndoHostingController(rootView: MainWindowView(model: model, services: services, lifecycle: lifecycle))
        // The controller owns native outer limits; SwiftUI content measurements must not
        // replace them as modules mount or toolbar items change.
        host.sizingOptions = []
        host.activeEditor = { [weak self] in self?.model.selection == .edit ? self?.services?.editor : nil }
        // SwiftUI's .toolbar and .navigationTitle become the NSWindow's own toolbar and title.
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = host
        window.setFrame(frame, display: false)
        observeMinimum(in: window)
        SidebarToggleSuppressor.watch(window)
    }

    private func observeMinimum(in window: NSWindow) {
        minimumWindow = window
        // Hosting updates contentMinSize after layout; it does not notify minSize when
        // clearing that constraint. Observe both public setters on this window alone.
        minimumObservations = [
            window.observe(\.minSize, options: [.new]) { [weak self] window, _ in
                MainActor.assumeIsolated { self?.enforceMinimum(in: window) }
            },
            window.observe(\.contentMinSize, options: [.new]) { [weak self] window, _ in
                MainActor.assumeIsolated { self?.enforceMinimum(in: window) }
            },
            // SwiftUI installs (and replaces) the toolbar after the content mounts.
            window.observe(\.toolbar, options: [.initial, .new]) { window, _ in
                MainActor.assumeIsolated { SidebarToggleSuppressor.watch(window) }
            }
        ]
        enforceMinimum(in: window)
    }

    private func enforceMinimum(in window: NSWindow) {
        guard minimumWindow === window, !correctingMinimum else { return }
        correctingMinimum = true
        defer { correctingMinimum = false }
        MainWindowGeometry.applyMinimum(MainWindowGeometry.minimumSize, to: window)
    }

    private func stopObservingMinimum() {
        minimumWindow = nil
        for observer in minimumObservations { observer.invalidate() }
        minimumObservations.removeAll()
    }

    private func makeWindow() -> NSWindow {
        let window = windowFactory?() ?? DiagnosticMainWindow(
            contentRect: NSRect(origin: .zero, size: MainWindowGeometry.minimumSize),
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
        let autosaveName = windowFactory == nil ? frameAutosaveKey : nil
        // Read before registering autosave, which itself restores the old frame.
        let descriptor = autosaveName.flatMap { defaults.string(forKey: "NSWindow Frame \($0)") }
        window.setFrame(MainWindowGeometry.defaultFrame(in: visibleFrame(window)), display: false)
        // After the first placement, so a saved frame wins over the centred default.
        if let autosaveName {
            window.setFrameAutosaveName(autosaveName)
            window.setFrameUsingName(autosaveName)
        }
        // Resolve the display after native restoration: a saved frame may belong to an
        // attached secondary screen, or AppKit may have relocated it after a hot unplug.
        let initialFrame = MainWindowGeometry.initialFrame(savedFrameDescriptor: descriptor,
            visibleFrame: visibleFrame(window),
            defaults: defaults, autosaveName: autosaveName)
        if let initialFrame { window.setFrame(initialFrame, display: false) }
        if windowFactory == nil { ActivationPerformanceDiagnostics.shared.register(window: window) }
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
        stopObservingMinimum()
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
