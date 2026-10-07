import AppKit
import Observation
import SwiftUI

/// The window's module selection, owned by the controller so the menu (⌘1…⌘3) and the live
/// check can move it from outside the view tree. Every change is persisted.
@MainActor @Observable
final class MainWindowModel {
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let performanceDiagnostics = NavigationPerformanceDiagnostics()
    @ObservationIgnored var selectionWillChange: (() -> Void)?
    var selection: ModuleID {
        willSet {
            if newValue != selection {
                performanceDiagnostics.request(.module(newValue))
                selectionWillChange?()
            }
        }
        didSet {
            guard selection != oldValue else { return }
            ModuleSelection.save(selection, to: defaults)
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        selection = ModuleSelection.load(from: defaults)
    }

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

/// The window is built like the menu-bar panel: a frosted tray with two glass cells on it, the
/// sidebar and the module. The sidebar lists the modules and never changes; the module fills
/// the other cell. The window buttons sit over the sidebar's top corner.
struct MainWindowView: View {
    @Bindable var model: MainWindowModel
    let services: AppServices?
    let lifecycle: MainWindowLifecycle?
    let studioPresentationProvider: (any StudioPresentationProvider)?
    private let studioCallbacks: StudioRuntimeCallbacks

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

    var body: some View {
        HStack(spacing: Theme.Window.Layout.gap) {
            MainWindowSidebar(selection: $model.selection, library: services?.library)
                .frame(width: Theme.Window.Layout.sidebarWidth)
                .frame(maxHeight: .infinity)
                .kitCell()
            RetainedModuleStack(selection: model.selection, model: model) { id in
                RegisteredModuleView(id: id, services: services, studioCallbacks: studioCallbacks)
                    .equatable()
            }
            // Content stays below the title-bar band, where a drag moves the window.
            .padding(.top, Theme.Window.Layout.titlebarSafe)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .kitCell()
        }
        .padding(Theme.Window.Layout.ring)
        .ignoresSafeArea()
        .kitTray()
        .frame(minWidth: MainWindowGeometry.minimumSize.width)
        .foregroundStyle(Theme.Palette.ink.color)
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
/// A switch hides the outgoing module at once and lets the incoming one arrive like the panel's
/// large content (a fade from 98.5 %). An unvisited module is mounted and laid out first, then
/// arrives on the next pass: no layout work runs inside the animation.
struct RetainedModuleStack<Content: View>: View {
    let selection: ModuleID
    let model: MainWindowModel?
    private let content: (ModuleID) -> Content
    private let reduceMotionOverride: Bool?
    @State private var visited: Set<ModuleID>
    @State private var shown: ModuleID
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.mainWindowLifecycle) private var lifecycle

    init(selection: ModuleID, model: MainWindowModel? = nil, reduceMotionOverride: Bool? = nil,
         @ViewBuilder content: @escaping (ModuleID) -> Content) {
        self.selection = selection
        self.model = model
        self.content = content
        self.reduceMotionOverride = reduceMotionOverride
        _visited = State(initialValue: [selection])
        _shown = State(initialValue: selection)
    }

    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    private var mountedModules: [ModuleID] {
        ModuleRegistry.all.map(\.id).filter { visited.contains($0) || $0 == selection }
    }

    var body: some View {
        ZStack {
            ForEach(mountedModules, id: \.self) { id in
                let active = id == selection
                let visible = active && id == shown
                content(id)
                    .background(PerformanceLayoutCompletionBridge(target: .module(id),
                        active: active, diagnostics: model?.performanceDiagnostics))
                    .environment(\.mainWindowModuleActive, active)
                    // The module's activity flips at once, never inside the arrival's animation.
                    .animation(nil, value: active)
                    .disabled(!active)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
                    .opacity(visible ? 1 : 0)
                    .scaleEffect(visible || reduceMotion ? 1 : Theme.Window.Lift.arriveScale)
                    .animation(visible ? Theme.Motion.resolve(Theme.Window.Motion.arrive, reduceMotion: reduceMotion) : nil,
                               value: visible)
            }
        }
        .onChange(of: selection) { _, id in
            visited.insert(id)
            // The next main-queue turn runs after this pass's layout has been committed.
            DispatchQueue.main.async { shown = id }
        }
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

    static func totalKnownBytes(_ sizes: some Sequence<Int64>) -> Int64 {
        sizes.reduce(Int64(0)) { total, size in
            let (sum, overflow) = total.addingReportingOverflow(max(size, 0))
            return overflow ? .max : sum
        }
    }
}

/// Pure keyboard movement through the sidebar: one step up or down among the modules,
/// stopping at the ends (as Finder's sidebar does).
enum SidebarNavigation {
    static func move<ID: Equatable>(from current: ID, by step: Int, in order: [ID]) -> ID {
        guard let index = order.firstIndex(of: current) else { return order.first ?? current }
        let next = min(max(index + step, 0), order.count - 1)
        return order.isEmpty ? current : order[next]
    }
}

/// The sidebar: the mark, then the modules by section, each with its ⌘ key, and the library's
/// facts at the foot. It lists the same modules whatever the window shows. Rows answer the
/// pointer like the panel's destinations; ↑/↓ move the selection while it has focus.
struct MainWindowSidebar: View {
    @Binding var selection: ModuleID
    let library: LibraryStore?
    @Namespace private var mark
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var order: [ModuleID] { ModuleRegistry.all.filter(\.isAvailable).map(\.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Window.Layout.rowSpacing) {
            SidebarBrand()
                .padding(.bottom, Theme.Space.m)
            ForEach(ModuleRegistry.sections, id: \.self) { section in
                if let title = section.title {
                    KitSectionHeader(title: Text(title))
                        .padding(.horizontal, Theme.Window.Layout.rowInset)
                        .padding(.top, Theme.Space.m)
                        .padding(.bottom, Theme.Space.xs)
                }
                ForEach(ModuleRegistry.modules(in: section), id: \.id) { module in
                    KitNavRow(symbol: module.symbol, title: Text(module.title), key: ModuleShortcut.label(for: module.id),
                              selected: selection == module.id, mark: mark) { select(module.id) }
                        .disabled(!module.isAvailable)
                }
            }
            Spacer(minLength: Theme.Space.l)
            if let library { LibrarySidebarFooter(store: library) }
        }
        .kitHoverGroup()
        .padding(Theme.Window.Layout.ring)
        .padding(.top, Theme.Window.Layout.titlebarHeight - Theme.Window.Layout.ring)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .up: select(SidebarNavigation.move(from: selection, by: -1, in: order))
            case .down: select(SidebarNavigation.move(from: selection, by: 1, in: order))
            default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Modules", comment: "Accessibility: the main window's sidebar"))
    }

    private func select(_ id: ModuleID) {
        withAnimation(Theme.Motion.resolve(Theme.Window.Motion.select, reduceMotion: reduceMotion)) { selection = id }
    }
}

/// The app's mark and name at the head of the sidebar.
private struct SidebarBrand: View {
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            CamcordBrandMark()
                .frame(width: Theme.Navigation.brandSize, height: Theme.Navigation.brandSize)
            Text(verbatim: "Camcord").font(Theme.Window.Font.headline)
        }
        .foregroundStyle(Theme.Palette.ink.color)
        .padding(.horizontal, Theme.Window.Layout.rowInset)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The library's size at the foot of the sidebar, read from the store without a watcher lease.
private struct LibrarySidebarFooter: View {
    @Bindable var store: LibraryStore

    private var version: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let version { Text(verbatim: "Camcord \(version)") }
            facts
        }
        .font(Theme.Window.Font.data)
        .foregroundStyle(Theme.Palette.ink3.color)
        .lineLimit(1)
        .padding(.horizontal, Theme.Window.Layout.rowInset)
        .padding(.bottom, Theme.Space.xs)
        .accessibilityElement(children: .combine)
    }

    private var facts: some View {
        HStack(spacing: Theme.Navigation.footerSpacing) {
            Text("\(store.items.count) captures")
            Text(verbatim: "·").accessibilityHidden(true)
            Text(verbatim: ByteCountFormatter.string(
                fromByteCount: MainWindowLayout.totalKnownBytes(store.items.map(\.byteSize)), countStyle: .file))
        }
    }
}

extension ModuleSection {
    /// The sidebar's section headers: the first section needs none.
    var title: LocalizedStringResource? {
        switch self {
        case .capture: nil
        case .create: LocalizedStringResource("Create", comment: "Sidebar section: making things from captures")
        }
    }
}

/// ⌘1…⌘3 pick the modules in registry order.
enum ModuleShortcut {
    @MainActor static func index(of id: ModuleID) -> Int? {
        ModuleRegistry.all.firstIndex { $0.id == id }.flatMap { $0 < 9 ? $0 + 1 : nil }
    }

    @MainActor static func label(for id: ModuleID) -> String? {
        index(of: id).map { "⌘\($0)" }
    }
}
