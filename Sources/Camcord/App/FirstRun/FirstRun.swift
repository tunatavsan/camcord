import AppKit
import SwiftUI

// The first run (the goal: "download → capture in 10 s"): one small
// frosted window. Screen Recording is the only gate, with a live tick; camera, microphone and
// Accessibility are asked for when their feature is first switched on. The primary action is a
// region capture.

/// When the first-run window shows: whenever Screen Recording is not granted (nothing works
/// without it), and once on the first launch of a version-1 install.
enum FirstRunPolicy {
    static let seenKey = "firstRun.seenVersion"
    /// The first-run generation this build belongs to (1.0).
    static let currentGeneration = 1

    static func shouldShow(screenRecordingGranted: Bool, seenGeneration: Int) -> Bool {
        !screenRecordingGranted || seenGeneration < currentGeneration
    }

    static func shouldShow(defaults: UserDefaults, screenRecordingGranted: Bool = CGPreflightScreenCaptureAccess()) -> Bool {
        shouldShow(screenRecordingGranted: screenRecordingGranted, seenGeneration: defaults.integer(forKey: seenKey))
    }

    static func markSeen(in defaults: UserDefaults) {
        defaults.set(currentGeneration, forKey: seenKey)
    }
}

/// Screen Recording's state, polled while the window is up: the grant happens in System
/// Settings, which sends no notification.
@MainActor @Observable
final class ScreenRecordingPermission {
    private(set) var granted: Bool
    private let check: @MainActor () -> Bool
    private var poll: Task<Void, Never>?
    private let pollInterval: Duration

    init(pollInterval: Duration = .seconds(1),
         check: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.pollInterval = pollInterval
        self.check = check
        granted = check()
    }

    func refresh() {
        if let simulated { granted = simulated } else { granted = check() }
    }

    /// The live check's stand-in for a state it cannot create on the user's Mac (revoking the
    /// grant): shows the window as if Screen Recording were (not) allowed.
    var simulated: Bool? {
        didSet { refresh() }
    }

    /// Asks once through the system prompt and opens the Screen Recording pane.
    func request() {
        _ = CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(PermissionRecovery.screenRecordingPaneURL)
    }

    var isPolling: Bool { poll != nil }

    func startPolling() {
        guard poll == nil else { return }
        let interval = pollInterval
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    isolated deinit { poll?.cancel() }

    func stopPolling() {
        poll?.cancel()
        poll = nil
    }
}

struct FirstRunView: View {
    let permission: ScreenRecordingPermission
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let captureRegion: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            VStack(spacing: Theme.Space.m) {
                CamcordBrandMark()
                    .frame(width: 52, height: 52)
                    .foregroundStyle(Theme.Palette.ink.color)
                Text("Camcord captures your screen", comment: "First-run title")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.Palette.ink.color)
                Text("One permission and you're ready. The rest are asked for when you first use them.",
                     comment: "First-run subtitle")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.ink2.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Theme.Space.l)

            VStack(spacing: 0) {
                PermissionRow(symbol: "rectangle.dashed.badge.record",
                              title: LocalizedStringResource("Screen Recording", comment: "Permission name"),
                              detail: LocalizedStringResource("Needed for every capture", comment: "Why Screen Recording is needed")) {
                    if permission.granted {
                        Label { Text("Allowed", comment: "A permission that is granted") } icon: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .foregroundStyle(Theme.Palette.ok.color)
                        .font(Theme.Font.bodyStrong)
                        .transition(CondenseTransition())
                    } else {
                        Button { permission.request() } label: { Text("Allow…", comment: "Button: grant a permission") }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.Palette.ink.color)
                    }
                }
                Divider()
                PermissionRow(symbol: "video",
                              title: LocalizedStringResource("Camera", comment: "Chip: the camera tile on or off"),
                              detail: LocalizedStringResource("For the camera tile", comment: "Why the camera is needed")) {
                    WhenYouTurnItOn()
                }
                Divider()
                PermissionRow(symbol: "mic",
                              title: LocalizedStringResource("Microphone", comment: "Permission name"),
                              detail: LocalizedStringResource("For your voice in recordings", comment: "Why the microphone is needed")) {
                    WhenYouTurnItOn()
                }
                Divider()
                PermissionRow(symbol: "hand.raised",
                              title: LocalizedStringResource("Accessibility", comment: "Permission name"),
                              detail: LocalizedStringResource("For mouse buttons and auto-scroll", comment: "Why Accessibility is needed")) {
                    WhenYouTurnItOn()
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.xs)
            .background(Theme.Palette.surface.color, in: RoundedRectangle(cornerRadius: Theme.Radius.box, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.box, style: .continuous).strokeBorder(Theme.Palette.hairline.color))

            HStack(spacing: Theme.Space.s) {
                Spacer()
                Button(action: later) { Text("Later", comment: "Button: close the first-run window for now") }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button(action: captureRegion) {
                    Label { Text(CaptureKind.region.actionTitle) } icon: { Image(systemName: CaptureKind.region.symbol) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.ink.color)
                .keyboardShortcut(.defaultAction)
                .disabled(!permission.granted)
            }
            .controlSize(.large)
        }
        .padding(Theme.Space.xl)
        .frame(width: 520)
        .animation(Self.permissionAnimation(reduceMotion: reduceMotion), value: permission.granted)
        .windowBackdrop(.content)
    }

    static func permissionAnimation(reduceMotion: Bool) -> Animation {
        Theme.Motion.resolve(Theme.Motion.panel, reduceMotion: reduceMotion)
    }
}

private struct PermissionRow<Trailing: View>: View {
    let symbol: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(Theme.Font.title.weight(.regular))
                .foregroundStyle(Theme.Palette.ink2.color)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.Font.body.weight(.medium)).foregroundStyle(Theme.Palette.ink.color)
                Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink2.color)
            }
            Spacer(minLength: Theme.Space.m)
            trailing
        }
        .frame(minHeight: 50)
        .accessibilityElement(children: .combine)
    }
}

private struct WhenYouTurnItOn: View {
    var body: some View {
        Text("When you turn it on", comment: "A permission asked for later, when its feature is first used")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.ink2.color)
    }
}

/// Owns the first-run window.
@MainActor
final class FirstRunWindowController: NSObject, NSWindowDelegate {
    private let defaults: UserDefaults
    private let captureRegion: @MainActor () -> Void
    private var window: NSWindow?
    private var hasVisibleLifecycle = false
    private let presenter: @MainActor (NSWindow, Bool) -> Void
    let permission: ScreenRecordingPermission

    init(presenter: (@MainActor (NSWindow, Bool) -> Void)? = nil,
         defaults: UserDefaults = .standard, permission: ScreenRecordingPermission = ScreenRecordingPermission(),
         captureRegion: @escaping @MainActor () -> Void) {
        self.presenter = presenter ?? { window, activate in
            if activate {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            } else { window.orderBack(nil) }
        }
        self.defaults = defaults
        self.permission = permission
        self.captureRegion = captureRegion
        super.init()
    }

    var isOpen: Bool { window?.isVisible == true }
    var windowForTesting: NSWindow? { window }

    /// Shows the window when the policy asks for it; returns whether it did.
    @discardableResult
    func showIfNeeded(activate: Bool = true) -> Bool {
        permission.refresh()
        guard FirstRunPolicy.shouldShow(defaults: defaults, screenRecordingGranted: permission.granted) else { return false }
        show(activate: activate)
        return true
    }

    func show(activate: Bool = true) {
        let window = window ?? makeWindow()
        self.window = window
        permission.refresh()
        hasVisibleLifecycle = true
        permission.startPolling()
        presenter(window, activate)
    }

    func close() {
        endVisibleLifecycle()
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let view = FirstRunView(permission: permission, captureRegion: { [weak self] in self?.startCapture() },
                                later: { [weak self] in self?.close() })
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = String(localized: "Welcome to Camcord", comment: "First-run window title")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func startCapture() {
        FirstRunPolicy.markSeen(in: defaults)
        close()
        captureRegion()
    }

    /// Closing counts as seen once Screen Recording is allowed; without it the window comes back
    /// at the next launch, because nothing can be captured.
    func windowWillClose(_ notification: Notification) { endVisibleLifecycle() }

    private func endVisibleLifecycle() {
        permission.stopPolling()
        guard hasVisibleLifecycle else { return }
        hasVisibleLifecycle = false
        if permission.granted, defaults.integer(forKey: FirstRunPolicy.seenKey) < FirstRunPolicy.currentGeneration {
            FirstRunPolicy.markSeen(in: defaults)
        }
    }
}
