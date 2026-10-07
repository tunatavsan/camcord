import AppKit
import Observation
import SwiftUI

/// The Settings window's chosen tab, persisted so Settings reopens where the user left it.
@MainActor @Observable
final class SettingsWindowModel {
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let performanceDiagnostics = NavigationPerformanceDiagnostics()
    /// Retained shortcut fields must end editing before their page is hidden.
    @ObservationIgnored var selectionWillChange: (() -> Void)?

    var group: SettingsGroup {
        willSet {
            guard newValue != group else { return }
            performanceDiagnostics.request(.settings(newValue))
            selectionWillChange?()
        }
        didSet { defaults.set(group.rawValue, forKey: SettingsGroup.defaultsKey) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        group = SettingsGroup.load(from: defaults)
    }
}

/// Settings: one tab per group in the panel's tool look, and the chosen group's page below,
/// each in a glass cell on the window's tray.
struct SettingsWindowView: View {
    @Bindable var model: SettingsWindowModel
    let services: AppServices?
    let lifecycle: MainWindowLifecycle?
    @State private var store: SettingsStore?

    private var visible: Bool { lifecycle?.allowsLivePreview ?? true }

    var body: some View {
        VStack(spacing: Theme.Window.Layout.gap) {
            KitTabStrip(tabs: SettingsGroup.allCases.map { .init(id: $0, symbol: $0.symbol, title: Text($0.title)) },
                        selection: $model.group)
                .padding(.horizontal, Theme.Window.Layout.cellPadding)
                .padding(.top, Theme.Window.Layout.titlebarHeight - Theme.Window.Layout.ring)
                .padding(.bottom, Theme.Space.xs)
                .kitCell()
            Group {
                if let store {
                    SettingsPageView(group: model.group, store: store)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .kitCell()
        }
        .padding(Theme.Window.Layout.ring)
        .ignoresSafeArea()
        .kitTray()
        .tint(Theme.Palette.ink.color)
        .environment(\.appServices, services)
        .environment(\.mainWindowLifecycle, lifecycle)
        .environment(\.navigationDiagnostics, model.performanceDiagnostics)
        .environment(\.mainWindowModuleActive, visible)
        .onChange(of: visible, initial: true) { _, visible in
            guard visible, let services else { return }
            if let store { store.refresh() } else {
                store = SettingsStore(defaults: services.defaults, eventTapEngine: services.eventTapEngine)
            }
        }
    }
}

/// Owns the Settings window. Closing it drops its SwiftUI tree, so no page keeps polling a
/// permission or running a camera preview unseen; its frame is kept.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let frameAutosaveName = "CamcordSettingsWindow"
    static let dockName = "settings"
    static let defaultSize = NSSize(width: 760, height: 640)
    static let minimumSize = NSSize(width: 720, height: 520)

    let model: SettingsWindowModel
    let lifecycle = MainWindowLifecycle()
    private let dock: DockController
    private let services: AppServices?
    private let frameAutosaveName: String?
    private var window: NSWindow?

    init(defaults: UserDefaults = .standard, dock: DockController, services: AppServices? = nil,
         frameAutosaveName: String? = SettingsWindowController.frameAutosaveName) {
        model = SettingsWindowModel(defaults: defaults)
        self.dock = dock
        self.services = services
        self.frameAutosaveName = frameAutosaveName
        super.init()
        model.selectionWillChange = { [weak self] in _ = self?.window?.makeFirstResponder(nil) }
    }

    var isOpen: Bool { window?.isVisible == true }
    var windowForTesting: NSWindow? { window }

    /// Opens Settings, on `group` when one is given. `activate: false` (the live check) puts the
    /// window behind the user's windows without taking focus.
    func show(group: SettingsGroup? = nil, activate: Bool = true) {
        dock.windowDidOpen(Self.dockName)
        if let group { model.group = group }
        let window = window ?? makeWindow()
        self.window = window
        if window.contentViewController == nil { installContent(in: window) }
        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderBack(nil)
        }
        refreshVisibility()
    }

    func close() { window?.close() }

    func windowDidChangeOcclusionState(_ notification: Notification) { refreshVisibility() }

    func windowWillClose(_ notification: Notification) {
        lifecycle.update(window: nil, temporarilyHidden: false)
        window?.contentViewController = nil
        dock.windowDidClose(Self.dockName)
    }

    private func refreshVisibility() { lifecycle.update(window: window, temporarilyHidden: false) }

    private func installContent(in window: NSWindow) {
        let frame = window.frame
        let host = NSHostingController(rootView: SettingsWindowView(model: model, services: services, lifecycle: lifecycle))
        host.sizingOptions = []
        window.contentViewController = host
        window.setFrame(frame, display: false)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Settings", comment: "Settings window title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.minSize = Self.minimumSize
        window.delegate = self
        installContent(in: window)
        window.center()
        if let frameAutosaveName {
            window.setFrameAutosaveName(frameAutosaveName)
            window.setFrameUsingName(frameAutosaveName)
        }
        return window
    }
}

extension EnvironmentValues {
    /// Where a page reports that it has laid out (signposts for the navigation measurements).
    @Entry var navigationDiagnostics: NavigationPerformanceDiagnostics?
}
