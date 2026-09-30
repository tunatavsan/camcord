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

/// The main window (docs/design/native/SPEC.md S1, the owner's reference): a whole-height,
/// lighter frosted sidebar of modules beside a lightly frosted content area, both behind-window
/// system materials so the desktop is faintly there (KARAR-2, NOTE-2); Record in the toolbar.
struct MainWindowView: View {
    @Bindable var model: MainWindowModel
    let services: AppServices?
    let lifecycle: MainWindowLifecycle?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: MainWindowModel, services: AppServices? = nil, lifecycle: MainWindowLifecycle? = nil) {
        self.model = model
        self.services = services
        self.lifecycle = lifecycle
    }

    /// A window of its own for offscreen renders and tests.
    init(defaults: UserDefaults, services: AppServices? = nil) {
        self.init(model: MainWindowModel(defaults: defaults), services: services)
    }

    private var module: any CamcordModule { ModuleRegistry.module(model.selection) ?? ModuleRegistry.all[0] }

    var body: some View {
        HStack(spacing: 0) {
            if model.sidebarVisible {
                ZStack {
                    if model.selection == .settings {
                        SettingsSidebar(model: model)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        MainWindowSidebar(selection: $model.selection)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .animation(Theme.Motion.resolve(Theme.Motion.panel, reduceMotion: reduceMotion),
                           value: model.selection == .settings)
                .frame(width: MainWindowLayout.sidebarWidth)
                    .windowBackdrop(.sidebar)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ZStack {
                module.makeView()
                    .id(model.selection)
                    .transition(.opacity)
            }
            .animation(Theme.Motion.resolve(Theme.Motion.moduleSwitch, reduceMotion: reduceMotion), value: model.selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .windowBackdrop(.content)
        }
        .animation(Theme.Motion.resolve(Theme.Motion.panel, reduceMotion: reduceMotion), value: model.sidebarVisible)
        .navigationTitle(Text(module.title))
        .toolbar { MainWindowToolbar(model: model, services: services) }
        .frame(minWidth: 880, minHeight: 560)
        .tint(Theme.Palette.ink.color)
        .environment(\.appServices, services)
        .environment(\.screenshotEditorSession, services?.editor)
        .environment(\.studioSession, services?.studioSession)
        .environment(\.studioSelectRegionAction, StudioRuntimeCallbacks.regionAction(services))
        .environment(\.studioClipboardClaim, StudioRuntimeCallbacks.clipboardClaim(services))
        .modifier(EditorOpeningConfirmationModifier(session: services?.editor))
        .environment(\.mainWindowModel, model)
        .environment(\.mainWindowLifecycle, lifecycle)
    }
}

extension EnvironmentValues {
    /// The window's model, for modules that drive the window (Settings takes over the sidebar).
    @Entry var mainWindowModel: MainWindowModel?
    @Entry var mainWindowLifecycle: MainWindowLifecycle?
}

enum MainWindowLayout {
    static let sidebarWidth: CGFloat = 240
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
        .safeAreaInset(edge: .top, spacing: 0) { SidebarHeader() }
        .accessibilityLabel(Text("Modules", comment: "Accessibility: the main window's sidebar"))
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

/// The window's toolbar: the sidebar button by the window controls, Record trailing. The five
/// capture keys are not here (KARAR-2): capturing is one hotkey or one panel key away, and each
/// module adds its own actions.
private struct MainWindowToolbar: ToolbarContent {
    @Bindable var model: MainWindowModel
    let services: AppServices?

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.sidebarVisible.toggle()
            } label: {
                Label { Text("Toggle Sidebar", comment: "Shows or hides the main window's sidebar") } icon: {
                    Image(systemName: "sidebar.left")
                }
            }
            .help(Text("Toggle Sidebar", comment: "Shows or hides the main window's sidebar"))
        }
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .automatic) {
            ToolbarRecordButton(services: services)
                .labelStyle(.titleAndIcon)
        }
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
    private let presentBackground: @MainActor (NSWindow) -> Void
    private let windowFactory: (@MainActor () -> NSWindow)?
    private let isAppActive: @MainActor () -> Bool
    private let waitForRemoval: @MainActor () async throws -> Void
    private var window: NSWindow?
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
         present: (@MainActor (NSWindow) -> Void)? = nil) {
        self.windowFactory = windowFactory
        self.presentBackground = presentBackground ?? { $0.orderBack(nil) }
        self.isAppActive = isAppActive
        self.waitForRemoval = waitForRemoval
        self.defaults = defaults
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
    private func installContent(in window: NSWindow) {
        let frame = window.frame
        let host = NSHostingController(rootView: MainWindowView(model: model, services: services, lifecycle: lifecycle))
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
        // Behind-window transparency (K1): the window itself is clear, so the system sidebar's
        // Liquid Glass shows the desktop through; the content paints its own opaque ground.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.delegate = self
        installContent(in: window)
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.center()
        // After the first placement, so a saved frame wins over the centred default.
        if windowFactory == nil {
            window.setFrameAutosaveName(Self.frameAutosaveName)
            window.setFrameUsingName(Self.frameAutosaveName)
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
