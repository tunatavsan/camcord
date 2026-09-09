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
final class EventTapEngine: NSObject {
    private let coordinator: CaptureCoordinator
    private let recordingController: RecordingController
    private let buttonIsDown: (Int64) -> Bool
    private let logger = Logger(subsystem: "dev.tavsan.camcord", category: "event-tap-engine")

    private var bindings = TapBindings()
    private var doubleTapDetector = DoubleTapDetector()
    private var holdGestureDetector = HoldGestureDetector()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdogTimer: Timer?

    /// Health of the tap for the menu/Settings status line: `false` whenever bindings
    /// are enabled but the tap could not be created or is not currently enabled.
    private(set) var isTapHealthy = false
    private var tapHolder: EventTapHolder?

    init(coordinator: CaptureCoordinator, recordingController: RecordingController,
         bindings: TapBindings = TapBindings(),
         buttonIsDown: @escaping (Int64) -> Bool = { button in
             guard let mouseButton = CGMouseButton(rawValue: UInt32(button)) else { return false }
             return CGEventSource.buttonState(.combinedSessionState, button: mouseButton)
         }) {
        self.coordinator = coordinator
        self.recordingController = recordingController
        self.bindings = bindings
        self.buttonIsDown = buttonIsDown
        super.init()
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
        holdGestureDetector = HoldGestureDetector()
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
        if bindings.mouseButton3 != nil || bindings.mouseButton4 != nil || bindings.mouseButton5 != nil {
            // The wheel (CG button 2) and the two side buttons (CG 3/4) all arrive as
            // otherMouseDown/Up, distinguished by their button number.
            mask |= 1 << CGEventType.otherMouseDown.rawValue
            mask |= 1 << CGEventType.otherMouseUp.rawValue
        }
        let holdCaptureBound = [bindings.mouseButton3, bindings.mouseButton4, bindings.mouseButton5].contains(.holdCaptureRegion)
        if holdCaptureBound {
            // Hold-to-capture drags the selection with the button held; the moves
            // arrive as otherMouseDragged (never mouseMoved) during the hold.
            mask |= 1 << CGEventType.otherMouseDragged.rawValue
        }
        // Both the capture modifier AND hold-to-capture must see left/right mouse events:
        // the modifier drives a chord with them, and a hold must SWALLOW them so a stray
        // click mid-capture can't leak through and act on the app underneath (e.g. closing
        // an open menu). Without this, a plain hold never sees the click at all.
        if captureModifierButton != nil || holdCaptureBound {
            for eventType: CGEventType in [
                .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                .rightMouseDown, .rightMouseDragged, .rightMouseUp,
            ] {
                mask |= 1 << eventType.rawValue
            }
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
        // No run-loop source = nothing pumps the tap's mach port. Enabling it anyway
        // would leave an active OS-level event filter with no delivery — treat a nil
        // source exactly like a failed tapCreate.
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            logger.error("CFMachPortCreateRunLoopSource returned nil; tearing down the unusable tap")
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)  // required to fully release a mach port; plain drop isn't enough
            eventTap = nil
            isTapHealthy = false
            return
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapHolder = EventTapHolder(tap: tap, source: source)
        isTapHealthy = true
    }

    private func teardownTap() {
        // A tap recreated mid-hold/chord would orphan the session (the up event that
        // ends it may never be seen) — end it explicitly.
        if activeHoldButton != nil {
            activeHoldButton = nil
            activeHoldDragged = false
            coordinator.cancelHoldRegionSelection()
        }
        resetModifierState(cancelChord: true)
        pendingHoldLocation = nil
        holdUpdateScheduled = false
        // The tapHolder.deinit handles all CGEvent.tapEnable, CFRunLoopRemoveSource, and CFMachPortInvalidate
        tapHolder = nil
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
        // mach_absolute_time pauses during sleep, so any gesture timing captured before
        // sleep is meaningless after wake — start the detectors fresh.
        doubleTapDetector = DoubleTapDetector()
        holdGestureDetector = HoldGestureDetector()
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

    func watchdogTick() {
        if let button = activeHoldButton, !buttonIsDown(button) {
            activeHoldButton = nil
            activeHoldDragged = false
            coordinator.cancelHoldRegionSelection()
        }
        // Backstop for the one "must be impossible" failure: if the modifier is armed but
        // its button is NOT physically down, a button-up was lost while the tap stayed
        // enabled — force-disarm so left/right clicks can't stay swallowed. Closes the
        // hole within one watchdog interval regardless of how the up was lost.
        if modifierArmed, let cgButton = captureModifierButton {
            if !buttonIsDown(cgButton) {
                logger.notice("Watchdog: capture-modifier armed but its button is up; force-disarming")
                resetModifierState(cancelChord: true)
            }
        }

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
        // A disable may have swallowed a button-up (the modifier's, a chord's, or a
        // hold's). Clear ALL gesture state so left/right clicks can NEVER get permanently
        // swallowed after the tap resumes — the single most dangerous failure here.
        if activeHoldButton != nil {
            activeHoldButton = nil
            activeHoldDragged = false
            coordinator.cancelHoldRegionSelection()
        }
        resetModifierState(cancelChord: true)
        let label = reason == .tapDisabledByTimeout ? "timeout" : "user-input"
        logger.notice("Event tap was disabled (\(label, privacy: .public)); re-enabled")
    }

    /// Classifies and dispatches one event given its already-extracted primitive
    /// fields. Returns `true` when the callback should swallow the event.
    func handle(
        type: CGEventType,
        button: Int64,
        keycode: Int64,
        isRightCommandDown: Bool,
        timestamp: TimeInterval,
        location: CGPoint
    ) -> Bool {
        switch type {
        case .otherMouseDown, .otherMouseUp:
            return handleMouseButton(type: type, button: button, location: location)
        case .otherMouseDragged:
            return handleMouseDragged(button: button, location: location)
        case .leftMouseDown, .rightMouseDown:
            return handleChordDown(isRight: type == .rightMouseDown, location: location)
        case .leftMouseDragged, .rightMouseDragged:
            return handleChordDragged(isRight: type == .rightMouseDragged, location: location)
        case .leftMouseUp, .rightMouseUp:
            return handleChordUp(isRight: type == .rightMouseUp, location: location)
        case .flagsChanged:
            handleFlagsChanged(keycode: keycode, isRightCommandDown: isRightCommandDown, timestamp: timestamp)
            return false
        case .keyDown:
            handleKeyDown(timestamp: timestamp)
            return false
        default:
            return false
        }
    }

    // MARK: - Mouse buttons (wheel + two side buttons)

    /// The button currently driving a hold-to-capture session, if any, and whether it
    /// has produced a drag yet (a no-drag release is a tap → arms the next hold for OCR).
    var activeHoldButton: Int64?
    private var activeHoldDragged = false
    private var pendingHoldLocation: CGPoint?
    private var holdUpdateScheduled = false

    /// Capture-modifier state: whether its button is held, and whether a left/right
    /// capture chord was used during this hold (so a plain tap can open the overlay).
    private var modifierArmed = false
    private var buttonsDownAtArm: UInt8 = 0
    private var chordActive = false
    private var chordUsedThisArm = false
    private var lastChordLocation: CGPoint = .zero
    /// After the modifier is released mid-chord, keep swallowing the still-held left/right
    /// button's tail (drag/up) until it's physically released, so the app underneath never
    /// sees an orphaned event whose matching down we already consumed.
    private var swallowChordTail = false
    /// Coalesces high-frequency drag updates to one overlay redraw per runloop tick, so
    /// the selection tracks smoothly instead of the tap callback blocking on every move.
    private var pendingChordLocation: CGPoint?
    private var chordUpdateScheduled = false

    /// The CG button number bound to `.captureModifier` (UI 3→CG2, 4→CG3, 5→CG4), or nil.
    private var captureModifierButton: Int64? {
        if bindings.mouseButton5 == .captureModifier { return 4 }
        if bindings.mouseButton4 == .captureModifier { return 3 }
        if bindings.mouseButton3 == .captureModifier { return 2 }
        return nil
    }

    private func handleMouseButton(type: CGEventType, button: Int64, location: CGPoint) -> Bool {
        // An active hold session ends on ITS button's release, wherever it lands.
        if type == .otherMouseUp, activeHoldButton == button {
            activeHoldButton = nil
            holdGestureDetector.registerRelease(button: button, dragged: activeHoldDragged, at: nowTimestamp())
            // finish shoots when a drag happened, cancels a no-drag tap.
            coordinator.finishHoldRegionSelection(atCGPoint: location)
            return true
        }
        // While a hold-to-capture is in progress, NO other mouse button may reach the app
        // underneath — swallow every other button press/release until the hold ends.
        if activeHoldButton != nil { return true }
        guard let action = tapAction(forMouseButton: button) else { return false }

        if action == .captureModifier {
            return handleModifierButton(type: type, location: location)
        }

        if type == .otherMouseDown {
            switch action {
            case .holdCaptureRegion:
                guard activeHoldButton == nil else { return true }
                // The mode is decided at press: a recent tap on THIS button means the
                // OCR variant (tap-then-hold), otherwise a plain screenshot hold.
                let mode = holdGestureDetector.modeForPress(button: button, at: nowTimestamp())
                // Only track the hold if the session actually started (screen-recording
                // permission present, no other capture in flight).
                if coordinator.beginHoldRegionSelection(atCGPoint: location, mode: mode) {
                    activeHoldButton = button
                    activeHoldDragged = false
                }
            case .paste:
                performPaste()
            case .captureRegion, .toggleRecording:
                perform(action)
            case .captureModifier:
                break  // handled above
            }
        }
        // Swallow both down and up for a bound button.
        return true
    }

    /// The capture-modifier button itself: arm on down; on release finish any in-progress
    /// chord (modifier released before the mouse button), or — if no chord happened and it
    /// was genuinely armed — treat the press as a plain tap that opens the region overlay.
    private func handleModifierButton(type: CGEventType, location: CGPoint) -> Bool {
        switch type {
        case .otherMouseDown:
            buttonsDownAtArm = (buttonIsDown(0) ? 1 : 0) | (buttonIsDown(1) ? 2 : 0)
            modifierArmed = true
            chordActive = false
            chordUsedThisArm = false
            swallowChordTail = false
        case .otherMouseUp:
            let wasArmed = modifierArmed
            modifierArmed = false
            if chordActive {
                // Modifier released mid-chord: finish the capture (anchor→here) and keep
                // swallowing the still-held button's tail so nothing leaks underneath.
                chordActive = false
                coordinator.finishHoldRegionSelection(atCGPoint: location)
                swallowChordTail = true
            } else if wasArmed, !chordUsedThisArm {
                perform(.captureRegion)  // plain tap → open the region overlay (only if armed)
            }
            chordUsedThisArm = false
        default:
            break
        }
        return true  // always swallow the modifier button
    }

    // MARK: - Capture-modifier chord (left/right mouse while the modifier is held)

    private func handleChordDown(isRight: Bool, location: CGPoint) -> Bool {
        buttonsDownAtArm &= ~(isRight ? 2 : 1)
        lastChordLocation = location
        // A hold-to-capture is in progress → this click must NOT act on the app underneath
        // (the reported bug: a left click mid-hold closing an open menu).
        if activeHoldButton != nil { return true }
        guard modifierArmed else { return swallowChordTail }   // not held → normal click
        if !chordActive {
            chordActive = true
            chordUsedThisArm = true
            let mode: HoldCaptureMode = isRight ? .text : .screenshot
            if !coordinator.beginHoldRegionSelection(atCGPoint: location, mode: mode) {
                chordActive = false   // couldn't start (e.g. no permission) — swallow anyway
            }
        }
        return true
    }

    private func handleChordDragged(isRight: Bool, location: CGPoint) -> Bool {
        if buttonsDownAtArm & (isRight ? 2 : 1) != 0 { return false }
        lastChordLocation = location
        if activeHoldButton != nil { return true }   // swallow left/right drags during a hold
        guard modifierArmed else { return swallowChordTail }
        // Swallow even when no chord is live: the matching down WAS swallowed
        // (handleChordDown returns true whenever the modifier is armed), and an
        // orphaned drag would confuse the app underneath.
        guard chordActive else { return true }
        // Coalesce: remember the latest position; one async redraw drains it per tick so
        // the tap callback never blocks on a synchronous overlay redraw mid-drag.
        pendingChordLocation = location
        if !chordUpdateScheduled {
            chordUpdateScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.chordUpdateScheduled = false
                if self.chordActive, let loc = self.pendingChordLocation {
                    self.coordinator.updateHoldRegionSelection(toCGPoint: loc)
                }
            }
        }
        return true
    }

    private func handleChordUp(isRight: Bool, location: CGPoint) -> Bool {
        let button: UInt8 = isRight ? 2 : 1
        if buttonsDownAtArm & button != 0 {
            buttonsDownAtArm &= ~button
            return false
        }
        lastChordLocation = location
        if activeHoldButton != nil { return true }   // swallow the click's release during a hold
        if swallowChordTail {
            swallowChordTail = false   // orphaned button finally released → resume normal
            return true
        }
        guard modifierArmed else { return false }
        if chordActive {
            chordActive = false
            // finishHoldRegionSelection uses anchor→location, so the final endpoint is
            // exact regardless of any still-queued coalesced update.
            coordinator.finishHoldRegionSelection(atCGPoint: location)
        }
        // Swallow the up unconditionally while armed — its down was swallowed too.
        return true
    }

    /// Resets ALL modifier/chord state and cancels any live chord session — the shared
    /// recovery used by teardown, tap re-enable, and the watchdog backstop.
    private func resetModifierState(cancelChord: Bool) {
        if cancelChord, chordActive {
            coordinator.cancelHoldRegionSelection()
        }
        modifierArmed = false
        buttonsDownAtArm = 0
        chordActive = false
        chordUsedThisArm = false
        swallowChordTail = false
        pendingChordLocation = nil
        chordUpdateScheduled = false
        pendingHoldLocation = nil
        holdUpdateScheduled = false
    }

    private func handleMouseDragged(button: Int64, location: CGPoint) -> Bool {
        // Route any other-button drag to the active hold session: the reported
        // button number on a drag event isn't reliable across all mice, and while a
        // hold is active the drag IS the hold's drag. No active hold -> pass through.
        guard activeHoldButton != nil else { return false }
        activeHoldDragged = true
        pendingHoldLocation = location
        if !holdUpdateScheduled {
            holdUpdateScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.holdUpdateScheduled = false
                if self.activeHoldButton != nil, let loc = self.pendingHoldLocation {
                    self.coordinator.updateHoldRegionSelection(toCGPoint: loc)
                }
            }
        }
        // The matching down was swallowed; a drag without its down would only
        // confuse the app underneath.
        return true
    }

    /// UI "button N" → CGEvent button (N-1): wheel = CG 2 (UI 3), side buttons = CG 3/4.
    private func tapAction(forMouseButton button: Int64) -> TapAction? {
        switch button {
        case 2: return bindings.mouseButton3
        case 3: return bindings.mouseButton4
        case 4: return bindings.mouseButton5
        default: return nil
        }
    }

    /// A monotonic seconds timestamp for the gesture detectors (same clock domain as
    /// the CGEvent timestamps used elsewhere).
    private func nowTimestamp() -> TimeInterval {
        MachTime.seconds(fromTicks: mach_absolute_time())
    }

    /// Terminal emulators (where Claude Code and other TUIs run) take Ctrl+V, not
    /// Cmd+V, as their paste — so a synthesized Cmd+V does nothing there. Detect a
    /// terminal frontmost app and use Ctrl+V for it.
    private static let controlPasteBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "org.alacritty",
        "io.alacritty",
        "org.tabby",
    ]

    /// Synthesizes a paste keystroke into the focused app so the clipboard (image or
    /// text) pastes without reaching for the keyboard. Cmd+V for normal apps, Ctrl+V
    /// for terminals. Posted on the next tick so it never re-enters this tap callback.
    private func performPaste() {
        FeedbackSound.paste.play()
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let useControl = bundleID.map(Self.controlPasteBundleIDs.contains) ?? false
        DispatchQueue.main.async {
            let source = CGEventSource(stateID: .combinedSessionState)
            let vKey: CGKeyCode = 9  // kVK_ANSI_V
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
            else { return }
            let flags: CGEventFlags = useControl ? .maskControl : .maskCommand
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Double-tap Right ⌘ (fact 6)

    private static let rightCommandKeycode: Int64 = 54

    private func handleFlagsChanged(keycode: Int64, isRightCommandDown: Bool, timestamp: TimeInterval) {
        // Do NOT swallow flagsChanged -- harmless as a modifier (fact 6).
        guard bindings.doubleTapRightCommand != nil else { return }
        guard keycode == Self.rightCommandKeycode else { return }

        let tapEvent: TapKeyEvent = isRightCommandDown ? .rightCmdDown : .rightCmdUp
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
        case .holdCaptureRegion, .captureModifier:
            // Hold / chord is driven inline from the button + left/right events; if this
            // is ever reached (e.g. assigned to the double-tap gesture, which has no held
            // phase) fall back to the plain interactive region flow.
            Task { await coordinator.captureRegionInteractive() }
        case .paste:
            performPaste()
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
/// `CGEvent.timestamp` is documented as "nanoseconds since startup" but on Apple
/// Silicon it is raw mach-absolute-time TICKS with a 125/3 timebase (~41.67 ns/tick)
/// -- dividing by 1e9 directly would stretch the 350 ms double-tap window to ~14.6 s.
/// Convert through `mach_timebase_info` (1/1 on Intel, so this is correct everywhere).
private enum MachTime {
    static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    static func seconds(fromTicks ticks: UInt64) -> TimeInterval {
        Double(ticks) * secondsPerTick
    }
}

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
    // Press/release of RIGHT ⌘ specifically: `.maskCommand` is set by EITHER command
    // key, so releasing Right ⌘ while Left ⌘ is held would read as still-pressed and
    // silently kill the double-tap gesture. The device-dependent right-command bit
    // (NX_DEVICERCMDKEYMASK, 0x10) tracks the right key alone.
    let isRightCommandDown = event.flags.rawValue & 0x10 != 0
    let timestamp = MachTime.seconds(fromTicks: event.timestamp)
    // Global CG display coordinates (top-left origin) — exactly what the overlay's
    // hold-selection methods expect. Read here on the callback's own stack; CGPoint
    // is a Sendable value so it crosses the actor hop safely.
    let location = event.location

    let shouldSwallow = MainActor.assumeIsolated {
        engine.handle(
            type: type,
            button: button,
            keycode: keycode,
            isRightCommandDown: isRightCommandDown,
            timestamp: timestamp,
            location: location
        )
    }
    return shouldSwallow ? nil : Unmanaged.passUnretained(event)
}

private final class EventTapHolder: @unchecked Sendable {
    let tap: CFMachPort
    let source: CFRunLoopSource
    init(tap: CFMachPort, source: CFRunLoopSource) {
        self.tap = tap
        self.source = source
    }
    deinit {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
    }
}
