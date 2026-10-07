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
