import AppKit

/// When Camcord has a Dock icon (docs/RUN-UI-1.md K10). The bundle stays `LSUIElement`;
/// the policy is switched at runtime. Pure, so every transition is testable.
enum DockPolicy {
    static func activationPolicy(mode: DockIconMode, windowOpen: Bool) -> NSApplication.ActivationPolicy {
        switch mode {
        case .always: .regular
        case .never: .accessory
        case .whileWindowOpen: windowOpen ? .regular : .accessory
        }
    }
}

/// Applies `DockPolicy` as the main window opens and closes and the setting changes. Only a
/// CHANGE is applied: switching the policy is visible (the Dock animates, the menu bar swaps).
@MainActor
final class DockController {
    typealias PolicySetter = @MainActor (NSApplication.ActivationPolicy) -> Void

    private let defaults: UserDefaults
    private let setPolicy: PolicySetter
    private(set) var windowOpen = false
    private(set) var applied: NSApplication.ActivationPolicy?
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, setPolicy: PolicySetter? = nil) {
        self.defaults = defaults
        // Never activates: `.always` applies at launch, where coming forward would steal
        // focus from whatever the owner is doing. The window activates when it is shown.
        self.setPolicy = setPolicy ?? { NSApp.setActivationPolicy($0) }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var mode: DockIconMode { DockIconMode.load(from: defaults) }

    func windowDidOpen() {
        windowOpen = true
        apply()
    }

    func windowDidClose() {
        windowOpen = false
        apply()
    }

    /// Re-reads the setting and applies the policy it asks for, if it differs.
    func apply() {
        let policy = DockPolicy.activationPolicy(mode: mode, windowOpen: windowOpen)
        guard policy != applied else { return }
        applied = policy
        setPolicy(policy)
    }
}
