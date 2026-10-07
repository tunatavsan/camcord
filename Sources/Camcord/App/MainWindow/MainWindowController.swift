import AppKit
import SwiftUI

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
