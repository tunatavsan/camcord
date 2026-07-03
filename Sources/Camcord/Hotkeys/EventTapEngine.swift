import AppKit
// `kAXTrustedCheckOptionPrompt` is an `extern CFStringRef` global imported as a mutable
// `var`, which Swift 6 strict concurrency always flags as unsafe to read regardless of
// caller isolation. `@preconcurrency` is the correct, narrow way to accept that this
// specific pre-Swift-6 C constant is safe (it's never mutated).
@preconcurrency import ApplicationServices
import CoreGraphics
import os

/// Fact 7: the Accessibility (AX) permission flow. A tiny, stateless helper shared by
/// `EventTapEngine`, `SettingsView`, and `StatusItemController` so the trust-check /
/// prompt / deep-link logic lives in exactly one place.
enum AccessibilityPermission {
    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system's own "add to Accessibility list" prompt (if the app isn't
    /// already listed) and opens the Accessibility privacy pane directly.
    static func requestAccess() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(systemSettingsURL)
    }
}

/// Tier 2 of the hotkey engine: a hand-rolled `CGEventTap` for mouse side buttons and
/// the double-tap Right ⌘ gesture -- the only mechanism for those, and the only piece
/// of M2 that requires the Accessibility TCC permission.
///
/// The tap is created only when at least one Tier-2 binding is enabled AND the process
/// is Accessibility-trusted. Reliability trio (fact 3): in-callback re-enable on
/// timeout/user-input disables, tap re-creation on wake/session-active, and a 5s
/// watchdog polling `tapIsEnabled`.
@MainActor
final class EventTapEngine {
    private let coordinator: CaptureCoordinator
    private let recordingController: RecordingController
    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "event-tap-engine")

    private var bindings = TapBindings()
    private var doubleTapDetector = DoubleTapDetector()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdogTimer: Timer?

    /// Health of the tap for the menu/Settings status line: `false` whenever bindings
    /// are enabled but the tap could not be created or is not currently enabled.
    private(set) var isTapHealthy = false

    init(coordinator: CaptureCoordinator, recordingController: RecordingController) {
        self.coordinator = coordinator
        self.recordingController = recordingController
        registerWorkspaceNotifications()
        startWatchdog()
    }

    /// Tears down/(re)creates the tap as needed for the given bindings. Safe to call
    /// repeatedly (e.g. every time Settings writes a change). Unchanged bindings with
    /// a live tap short-circuit -- no pointless destroy/recreate churn per Settings
    /// write. (Unchanged bindings with a MISSING tap still recreate: that's the
    /// "Accessibility was just granted" path.)
    func apply(_ newBindings: TapBindings) {
        let unchanged = newBindings == bindings
        bindings = newBindings
        if unchanged, !newBindings.anyEnabled || eventTap != nil {
            return
        }
        doubleTapDetector = DoubleTapDetector()
        recreateTap()
    }

    // MARK: - Tap lifecycle

    private func recreateTap() {
        teardownTap()

        guard bindings.anyEnabled else { return }
        guard AccessibilityPermission.isTrusted() else {
            logger.notice("Tier-2 bindings enabled but Accessibility permission is not granted")
            return
        }

        var mask: CGEventMask = 0
        if bindings.mouseButton4 != nil || bindings.mouseButton5 != nil {
            mask |= 1 << CGEventType.otherMouseDown.rawValue
            mask |= 1 << CGEventType.otherMouseUp.rawValue
        }
        if bindings.doubleTapRightCommand != nil {
            mask |= 1 << CGEventType.flagsChanged.rawValue
            mask |= 1 << CGEventType.keyDown.rawValue
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: eventTapCallback,
                userInfo: userInfo
            )
        else {
            logger.error("CGEvent.tapCreate failed even though Accessibility is trusted")
            isTapHealthy = false
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isTapHealthy = true
    }

    private func teardownTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            // Documented teardown order: invalidate the mach port explicitly rather
            // than relying on ARC release timing during frequent recreation.
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        isTapHealthy = false
    }

    // MARK: - Reliability trio (b): wake / session-active re-creation

    private func registerWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(handleWorkspaceReactivation), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(
            self,
            selector: #selector(handleWorkspaceReactivation),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func handleWorkspaceReactivation() {
        recreateTap()
    }

    // MARK: - Reliability trio (c): watchdog

    private func startWatchdog() {
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.watchdogTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func watchdogTick() {
        guard bindings.anyEnabled else { return }

        guard let tap = eventTap else {
            // The tap never came up (transient create failure, or Accessibility was
            // granted while Settings was closed). Resurrect once trust appears.
            if AccessibilityPermission.isTrusted() {
                logger.notice("Watchdog resurrecting missing event tap")
                recreateTap()
            }
            return
        }
        guard !CGEvent.tapIsEnabled(tap: tap) else { return }

        logger.notice("Watchdog found the event tap disabled; re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
        if !CGEvent.tapIsEnabled(tap: tap) {
            logger.error("Re-enable did not take; recreating the event tap")
            recreateTap()
        }
    }

    // MARK: - Callback (fact 4: minimal, classify -> dispatch -> return)

    /// Re-enables the tap in-callback on a disable event (reliability trio, fact 3a).
    /// `CGEvent` is not `Sendable`, so the free-function callback below extracts only
    /// primitive, `Sendable` fields from the event before hopping onto this actor --
    /// this method and the ones below never see the `CGEvent` itself.
    fileprivate func reEnableAfterDisable(reason: CGEventType) {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        let label = reason == .tapDisabledByTimeout ? "timeout" : "user-input"
        logger.notice("Event tap was disabled (\(label, privacy: .public)); re-enabled")
    }

    /// Classifies and dispatches one event given its already-extracted primitive
    /// fields. Returns `true` when the callback should swallow the event.
    fileprivate func handle(type: CGEventType, button: Int64, keycode: Int64, isCommandDown: Bool, timestamp: TimeInterval) -> Bool {
        switch type {
        case .otherMouseDown, .otherMouseUp:
            return handleMouseButton(type: type, button: button)
        case .flagsChanged:
            handleFlagsChanged(keycode: keycode, isCommandDown: isCommandDown, timestamp: timestamp)
            return false
        case .keyDown:
            handleKeyDown(timestamp: timestamp)
            return false
        default:
            return false
        }
    }

    // MARK: - Mouse side buttons (fact 5)

    private func handleMouseButton(type: CGEventType, button: Int64) -> Bool {
        guard let action = tapAction(forMouseButton: button) else { return false }
        if type == .otherMouseDown {
            perform(action)
        }
        // Swallow both down and up for a bound button.
        return true
    }

    private func tapAction(forMouseButton button: Int64) -> TapAction? {
        switch button {
        case 3: return bindings.mouseButton4
        case 4: return bindings.mouseButton5
        default: return nil
        }
    }

    // MARK: - Double-tap Right ⌘ (fact 6)

    private static let rightCommandKeycode: Int64 = 54

    private func handleFlagsChanged(keycode: Int64, isCommandDown: Bool, timestamp: TimeInterval) {
        // Do NOT swallow flagsChanged -- harmless as a modifier (fact 6).
        guard bindings.doubleTapRightCommand != nil else { return }
        guard keycode == Self.rightCommandKeycode else { return }

        let tapEvent: TapKeyEvent = isCommandDown ? .rightCmdDown : .rightCmdUp
        if doubleTapDetector.handle(event: tapEvent, at: timestamp), let action = bindings.doubleTapRightCommand {
            perform(action)
        }
    }

    private func handleKeyDown(timestamp: TimeInterval) {
        // Always passed through untouched (fact 6/deliverable) -- only feeds the
        // detector's reset when the double-tap binding is active.
        guard bindings.doubleTapRightCommand != nil else { return }
        _ = doubleTapDetector.handle(event: .otherKeyDown, at: timestamp)
    }

    // MARK: - Action dispatch (same flows as HotkeyCenter)

    private func perform(_ action: TapAction) {
        switch action {
        case .captureRegion:
            Task { await coordinator.captureRegionInteractive() }
        case .toggleRecording:
            Task { await recordingController.toggleRecording() }
        }
    }
}

/// The tap callback must be a non-capturing C function pointer (fact 4); state travels
/// through `userInfo` as an `Unmanaged<EventTapEngine>`. `CGEvent` is a non-`Sendable`
/// class, so every field `EventTapEngine` needs is read here -- on the callback's own
/// (nonisolated) stack -- before hopping onto `EventTapEngine`'s `@MainActor` isolation
/// via `assumeIsolated`; only primitive `Sendable` values cross that boundary. The hop
/// is safe because the tap's run loop source is added to the main run loop, so this
/// callback only ever fires on the main thread.
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<EventTapEngine>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated {
            engine.reEnableAfterDisable(reason: type)
        }
        return Unmanaged.passUnretained(event)
    }

    let button = event.getIntegerValueField(.mouseEventButtonNumber)
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    let isCommandDown = event.flags.contains(.maskCommand)
    let timestamp = TimeInterval(event.timestamp) / 1_000_000_000

    let shouldSwallow = MainActor.assumeIsolated {
        engine.handle(type: type, button: button, keycode: keycode, isCommandDown: isCommandDown, timestamp: timestamp)
    }
    return shouldSwallow ? nil : Unmanaged.passUnretained(event)
}
