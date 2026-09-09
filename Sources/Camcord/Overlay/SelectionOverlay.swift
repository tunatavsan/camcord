import AppKit
@preconcurrency import ScreenCaptureKit

/// What the user picked -- a dragged region (already in CG/SCK screen space) or a
/// window snapped to and clicked on.
enum SelectionResult {
    case region(CGRect)
    case window(SCWindow)
}

/// The selection's intent, which drives its accent color: a screenshot pick is blue, a
/// recording target is red. Everything the overlay draws (region border + window highlight)
/// uses this one color so the whole gesture reads as "shot" vs "record" at a glance.
enum SelectionAccent {
    case screenshot
    case recording

    var color: NSColor {
        switch self {
        case .screenshot: return .systemBlue
        case .recording: return .systemRed
        }
    }
}

/// A borderless, nonactivating panel covering one screen. `canBecomeKey` must return
/// true for a `.nonactivatingPanel` to receive key events (Esc) at all.
final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// A frozen desktop must replace the live desktop in one compositor commit. AppKit's
    /// default behavior may animate a panel as it is ordered in, which makes opaque frozen
    /// pixels visibly move even though the screenshot layer itself has implicit actions off.
    func configureForPresentation(displaysFrozenDesktop: Bool) {
        animationBehavior = displaysFrozenDesktop ? .none : .default
    }
}

/// Presents one `SelectionPanel` per `NSScreen`, lets the user drag out a region
/// (which may span screens) or click a window highlighted by window-snap, and
/// resolves to a `SelectionResult` (or nil on cancel).
///
/// A fresh set of panels/views is created per invocation and torn down on every exit
/// path (cancel, region picked, window picked) -- the controller itself is reusable
/// for the next call to `selectRegion()`.
@MainActor
final class SelectionOverlayController: NSObject, SelectionViewDelegate {
    private let shareableContentCache: ShareableContentCache

    private var panels: [SelectionPanel] = []
    private var views: [SelectionView] = []
    private var presentedScreens: [NSScreen] = []
    private var continuation: CheckedContinuation<(SelectionResult, HoldCaptureMode)?, Never>?
    private var frozenContinuation: CheckedContinuation<(SelectionResult, HoldCaptureMode)?, Never>?
    /// Non-nil while a HOLD session (mouse side button held; events driven by the
    /// CGEventTap, not by the panels) is active. Every exit path funnels through
    /// `finish(_:)`, which fires this exactly once.
    private var holdEndHandler: ((SelectionResult?) -> Void)?
    private var frozenSnapshot: FrozenDesktopSnapshot?
    /// Frozen screenshot and hold sessions are bound to the display selected at trigger time.
    /// This exists before a hold snapshot arrives, so dragging can be clamped immediately.
    private var constrainedCGFrame: CGRect?
    private var isPresenting = false
    /// Phase R (G.3 adaptive): set when the 50 ms visibility probe found the ordered
    /// panels covered — a fullscreen game sits above `.screenSaver`, so the gesture can
    /// never be drawn. The caller reads it once with `consumeBlindPresentation()` to tell
    /// this apart from a user cancel and capture without UI instead.
    private var presentationWasBlind = false

    // Global = AppKit screen space (bottom-left origin, Y up).
    private var dragAnchor: CGPoint?
    private var dragCurrent: CGPoint?
    private var isDragging = false
    /// The button that started the current interactive selection: right = OCR mode.
    private var activeIsRight = false
    /// When set (recording target picking), the RIGHT button means "the whole screen
    /// under the pointer" instead of an OCR region — a one-gesture full-screen record.
    private var rightClickWholeScreen = false
    /// The accent color for this session's overlay (blue = screenshot, red = recording).
    private var accent: SelectionAccent = .screenshot
    /// True while a HOLD/chord session is in OCR (.text) mode, so the overlay shows the
    /// teal "Metin · OCR" treatment even though no right button drove the selection.
    private var holdIsText = false
    private var highlightedWindow: SCWindow?
    private var highlightedFrozenWindow: FrozenDesktopSnapshot.Window?
    /// Session token for the async window-snap lookups: they hop through the cache
    /// actor, so one can resolve after teardown (or after a newer lookup) and would
    /// otherwise write a stale `highlightedWindow` into the wrong session — a click
    /// could then silently pick a window that was never visibly highlighted.
    private var snapGeneration = 0
    private var clickGeneration = 0
    private var screenChangeObserver: NSObjectProtocol?
    /// Balances NSCursor push/pop: the zero-screens early-out finishes without ever
    /// pushing, and an unmatched pop would corrupt the cursor stack.
    private var cursorPushed = false

    private static let clickMovementThreshold: CGFloat = 4

    init(shareableContentCache: ShareableContentCache) {
        self.shareableContentCache = shareableContentCache
    }

    /// Shows the overlay and suspends until the user picks a region/window or cancels.
    /// If a selection session is already active (e.g. a second hotkey/menu trigger fires
    /// while the overlay is up), this immediately returns nil WITHOUT disturbing the
    /// in-flight session -- it does not overwrite `continuation` or touch its panels.
    /// Returns the picked region/window plus the mode (left button = screenshot,
    /// right button = OCR text). Callers that always mean one mode ignore it.
    func selectRegion(rightClickWholeScreen: Bool = false, accent: SelectionAccent = .screenshot) async -> (SelectionResult, HoldCaptureMode)? {
        guard !isPresenting else { return nil }
        isPresenting = true
        self.rightClickWholeScreen = rightClickWholeScreen
        self.accent = accent
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentPanels()
        }
    }

    /// Screenshot/OCR selector backed by pixels and window geometry captured before this panel
    /// exists. A click retains the corresponding SCWindow; a drag resolves to a frozen crop rect.
    func selectFrozen(snapshot: FrozenDesktopSnapshot) async -> (SelectionResult, HoldCaptureMode)? {
        guard !isPresenting else { return nil }
        isPresenting = true
        frozenSnapshot = snapshot
        constrainedCGFrame = snapshot.displays.first?.cgFrame
        rightClickWholeScreen = false
        accent = .screenshot
        return await withCheckedContinuation { continuation in
            frozenContinuation = continuation
            presentPanels()
        }
    }

    // MARK: - Hold session (side button held down; driven by the event tap)

    /// Starts a hold-to-capture session anchored at the button-down location.
    /// `onEnd` fires exactly once, on whichever exit path ends the session (release,
    /// Esc, display change, zero screens).
    ///
    /// The dim/selection panels are NOT shown yet — they appear only once the drag
    /// crosses the movement threshold. So a plain tap (down + quick release, no drag)
    /// shows nothing at all, which is exactly what the tap-then-hold OCR gesture needs
    /// on its first tap, and the plain hold's overlay appears the instant you start
    /// dragging (no down-time latency).
    /// Returns whether the session actually started (false = an overlay was already up,
    /// so the caller must NOT track/swallow the gesture). On rejection `onEnd` is NOT
    /// called — the caller owns its own cleanup.
    @discardableResult
    func beginHoldSelection(
        atCGPoint cgPoint: CGPoint,
        mode: HoldCaptureMode,
        frozenSnapshot: FrozenDesktopSnapshot? = nil,
        constrainedToCGFrame constrainedCGFrame: CGRect? = nil,
        onEnd: @escaping (SelectionResult?) -> Void
    ) -> Bool {
        guard !isPresenting else { return false }
        isPresenting = true
        holdEndHandler = onEnd
        self.frozenSnapshot = frozenSnapshot
        self.constrainedCGFrame = constrainedCGFrame ?? frozenSnapshot?.displays.first?.cgFrame
        holdIsText = mode == .text
        accent = .screenshot   // hold-to-capture is always a screenshot → blue
        activeIsRight = false   // chord mode comes from `mode` alone, not a stale right-drag
        let point = cgToAppKitPoint(cgPoint)
        dragAnchor = point
        dragCurrent = point
        isDragging = false
        return true
    }

    /// Supplies trigger-time pixels to a hold overlay that was already presented at the drag
    /// threshold. Geometry remains bound to the display chosen when the hold began.
    func setFrozenDesktopSnapshot(_ snapshot: FrozenDesktopSnapshot) {
        guard isPresenting else { return }
        guard snapshotMatchesCurrentDisplays(snapshot) else {
            finish(nil)
            return
        }
        frozenSnapshot = snapshot
        for ((screen, panel), view) in zip(zip(presentedScreens, panels), views) {
            panel.configureForPresentation(displaysFrozenDesktop: true)
            guard let id = screen.cgDirectDisplayID,
                let frozenDisplay = snapshot.display(id: id)
            else { continue }
            view.setFrozenDesktopImage(frozenDisplay.image, scale: frozenDisplay.scaleX)
        }
    }

    func updateHoldSelection(toCGPoint cgPoint: CGPoint) {
        guard isPresenting, holdEndHandler != nil, let anchor = dragAnchor else { return }
        let point = clampedAppKitPoint(cgToAppKitPoint(cgPoint))
        dragCurrent = point
        if !isDragging {
            let movement = hypot(point.x - anchor.x, point.y - anchor.y)
            guard movement >= Self.clickMovementThreshold else { return }
            isDragging = true
            // First real drag: bring the panels up now (no window-snap in hold mode —
            // it is region-only).
            if panels.isEmpty {
                presentPanels(seedWindowSnap: false)
                guard isPresenting else { return }  // zero-screens path ended the session
            }
        }
        updateRendering()
    }

    /// Button released: shoot the dragged region, or cancel on a no-drag click.
    func finishHoldSelection(atCGPoint cgPoint: CGPoint) {
        guard isPresenting, holdEndHandler != nil else { return }
        guard isDragging, let anchor = dragAnchor,
            let primaryHeight = NSScreen.screens.first?.frame.height
        else {
            finish(nil)
            return
        }
        let point = clampedAppKitPoint(cgToAppKitPoint(cgPoint))
        let globalRect = Geometry.normalizedRect(from: anchor, to: point)
        guard globalRect.width >= 1, globalRect.height >= 1 else {
            finish(nil)
            return
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        finish(.region(Geometry.appKitToCG(globalRect, primaryScreenHeight: primaryHeight)))
    }

    /// Safety hatch for the event tap's teardown paths (tap recreated mid-hold).
    func cancelHoldSelection() {
        guard holdEndHandler != nil else { return }
        finish(nil)
    }

    private func cgToAppKitPoint(_ point: CGPoint) -> CGPoint {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return point }
        return Geometry.cgToAppKit(CGRect(origin: point, size: .zero), primaryScreenHeight: primaryHeight).origin
    }

    // MARK: - Presentation

    private func presentPanels(seedWindowSnap: Bool = true) {
        presentationWasBlind = false
        // No screens (all displays asleep/detached): without this guard no panel is
        // ever created, so no event could resume the continuation -- selectRegion()
        // would hang forever with isPresenting stuck.
        guard !NSScreen.screens.isEmpty else {
            finish(nil)
            return
        }
        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            finish(nil)
            return
        }
        if let frozenSnapshot {
            guard snapshotMatchesCurrentDisplays(frozenSnapshot) else {
                finish(nil)
                return
            }
        }

        let sessionScreens = screensForCurrentSession(primaryScreenHeight: primaryHeight)
        guard !sessionScreens.isEmpty else {
            finish(nil)
            return
        }
        presentedScreens = sessionScreens

        NSCursor.crosshair.push()
        cursorPushed = true
        // Kick off a refresh so window-snap has something reasonably fresh; mouseMoved
        // itself only ever reads the last-known snapshot, never blocks on a fetch.
        Task { await shareableContentCache.refreshInBackground() }

        // The panel/view arrays are built from this instant's NSScreen.screens and
        // are index-paired with it in updateRendering -- if the display set changes
        // mid-session that pairing silently goes stale (selection drawn on the wrong
        // display). Cancel instead; the next invocation rebuilds against fresh screens.
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finish(nil)
            }
        }

        let mouseLocation = NSEvent.mouseLocation
        var keyPanel: SelectionPanel?

        for screen in sessionScreens {
            let panel = SelectionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
            panel.isReleasedWhenClosed = false
            panel.configureForPresentation(displaysFrozenDesktop: frozenSnapshot != nil)

            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.delegate = self
            view.backingScale = screen.backingScaleFactor
            view.accent = accent.color
            if let frozenDisplay = screen.cgDirectDisplayID.flatMap({ frozenSnapshot?.display(id: $0) }) {
                view.setFrozenDesktopImage(frozenDisplay.image, scale: frozenDisplay.scaleX)
            }
            panel.contentView = view
            // A programmatic panel's first responder defaults to the panel ITSELF,
            // which swallows keyDown/cancelOperation — Esc only reaches
            // SelectionView if the view is explicitly made first responder.
            panel.makeFirstResponder(view)

            panels.append(panel)
            views.append(view)

            panel.orderFrontRegardless()
            if screen.frame.contains(mouseLocation) {
                keyPanel = panel
            }
        }

        // Make key WITHOUT activating the app (no NSApp.activate call).
        (keyPanel ?? panels.first)?.makeKey()
        // The gesture happens on the cursor's display, so that panel — not the set — is
        // what "the overlay is on screen" means. On a second monitor an unaffected desktop
        // panel stays visible while the game display draws nothing.
        let probed = keyPanel ?? panels.first

        // Phase G.1: a trigger can arrive and still draw nothing — a fullscreen game sits
        // above .screenSaver. Report whether the panels actually made it on screen.
        TriggerLog.overlay("ordered=\(panels.count)")
        let ordered = panels
        let isHoldSession = holdEndHandler != nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            let visible = ordered.filter { $0.occlusionState.contains(.visible) }.count
            let targetVisible = probed?.occlusionState.contains(.visible) ?? false
            TriggerLog.overlay("visible=\(visible)/\(ordered.count) cursorDisplay=\(targetVisible)")
            // The probe outlives its session (a pick or Esc can land inside the 50 ms), so
            // only the presentation it was started for may be abandoned.
            guard self.isPresenting, self.panels.first === ordered.first,
                Self.presentationIsBlind(orderedPanels: ordered.count, targetVisible: targetVisible, isHoldSession: isHoldSession)
            else { return }
            TriggerLog.overlay("blind=1 falling back to a UI-less capture")
            self.presentationWasBlind = true
            self.finish(nil)
        }

        // Seed window-snap for the cursor's RESTING position: tracking areas emit no
        // mouseMoved for a cursor already inside the view, so the natural
        // "hover the target, then press the hotkey, then click" flow would otherwise
        // read highlightedWindow == nil and cancel instead of picking the window.
        if seedWindowSnap {
            snapGeneration &+= 1
            let generation = snapGeneration
            Task {
                // Prime the cache first so the very first highlight uses windows for
                // the CURRENT space and z-order — native full-screen enters a new
                // Space, so the last-known snapshot can momentarily lack the front
                // window and the snap would fall through to a window behind it.
                if frozenSnapshot == nil {
                    _ = try? await shareableContentCache.content()
                }
                await updateWindowSnap(at: mouseLocation, generation: generation)
            }
        }
    }

    private func teardown() {
        // Orphan any in-flight window-snap lookup so it can't write into the next session.
        snapGeneration &+= 1
        clickGeneration &+= 1
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
        views.removeAll()
        presentedScreens.removeAll()
        dragAnchor = nil
        dragCurrent = nil
        isDragging = false
        highlightedWindow = nil
        highlightedFrozenWindow = nil
        frozenSnapshot = nil
        constrainedCGFrame = nil
        rightClickWholeScreen = false
        accent = .screenshot   // next session defaults to the screenshot (blue) accent
        holdIsText = false
        activeIsRight = false   // never let a prior right-drag leak into the next session's mode/visual
    }

    /// Pure decision behind the G.3 adaptive fallback: panels were ordered front, the one on
    /// the cursor's display is not on screen 50 ms later, and this is not a hold session
    /// (whose panels appear only once the drag crosses the movement threshold, so "not
    /// visible" is normal there).
    static func presentationIsBlind(orderedPanels: Int, targetVisible: Bool, isHoldSession: Bool) -> Bool {
        orderedPanels > 0 && !targetVisible && !isHoldSession
    }

    /// True once per blind presentation: the caller falls back to a UI-less capture.
    func consumeBlindPresentation() -> Bool {
        defer { presentationWasBlind = false }
        return presentationWasBlind
    }

    private func finish(_ result: SelectionResult?, mode: HoldCaptureMode = .screenshot) {
        // Idempotent: a second finish (e.g. a stray cancel after teardown) must not
        // pop the cursor stack again or resume a dead continuation.
        guard isPresenting else { return }
        teardown()
        isPresenting = false
        let continuation = self.continuation
        self.continuation = nil
        let frozenContinuation = self.frozenContinuation
        self.frozenContinuation = nil
        let holdHandler = holdEndHandler
        holdEndHandler = nil
        continuation?.resume(returning: result.map { ($0, mode) })
        frozenContinuation?.resume(returning: result.map { ($0, mode) })
        holdHandler?(result)
    }

    // MARK: - SelectionViewDelegate

    func selectionViewMouseDown(at globalPoint: CGPoint, isRight: Bool) {
        if let constrainedCGFrame, let primaryHeight = NSScreen.screens.first?.frame.height,
            !Geometry.cgToAppKit(constrainedCGFrame, primaryScreenHeight: primaryHeight).contains(globalPoint)
        { return }
        let globalPoint = clampedAppKitPoint(globalPoint)
        // A new gesture orphans any still-pending click resolution from a previous
        // click (see selectionViewMouseUp) — without this, a slow lookup could commit
        // its window mid-way through THIS gesture.
        snapGeneration &+= 1
        clickGeneration &+= 1
        // Don't switch to selection-drag rendering yet -- stay in window-snap
        // highlight mode until mouseDragged confirms an actual drag past the
        // click-movement threshold. Avoids the highlight flickering off on a
        // plain click before mouseUp gets a chance to read `highlightedWindow`.
        activeIsRight = isRight
        dragAnchor = globalPoint
        dragCurrent = globalPoint
        isDragging = false
    }

    func selectionViewMouseDragged(to globalPoint: CGPoint, isRight: Bool) {
        guard let anchor = dragAnchor else { return }
        let globalPoint = clampedAppKitPoint(globalPoint)
        dragCurrent = globalPoint

        if !isDragging {
            let movement = hypot(globalPoint.x - anchor.x, globalPoint.y - anchor.y)
            guard movement >= Self.clickMovementThreshold else { return }
            isDragging = true
        }
        updateRendering()
    }

    func selectionViewMouseUp(at globalPoint: CGPoint, isRight: Bool) {
        guard let anchor = dragAnchor else { return }
        let globalPoint = clampedAppKitPoint(globalPoint)
        let wasDragging = isDragging
        let mode: HoldCaptureMode = activeIsRight ? .text : .screenshot
        dragAnchor = nil
        dragCurrent = nil
        isDragging = false

        // Recording target: the right button records the WHOLE screen under the pointer,
        // whether it was a click or a drag — a one-gesture full-screen record.
        if rightClickWholeScreen, activeIsRight {
            if let primaryHeight = NSScreen.screens.first?.frame.height,
                let screen = NSScreen.screens.first(where: { $0.frame.contains(globalPoint) }) ?? NSScreen.main {
                finish(.region(Geometry.appKitToCG(screen.frame, primaryScreenHeight: primaryHeight)))
            } else {
                finish(nil)
            }
            return
        }

        guard wasDragging else {
            if let frozenSnapshot {
                let cgPoint = appKitPointToCG(
                    globalPoint,
                    primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0
                )
                guard let frozenWindow = frozenSnapshot.window(atCGPoint: cgPoint) ?? highlightedFrozenWindow else {
                    finish(nil)
                    return
                }
                let generation = clickGeneration
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let resolved = await self.resolveFrozenWindow(id: frozenWindow.id)
                    guard generation == self.clickGeneration, self.isPresenting else {
                        self.finish(nil)
                        return
                    }
                    guard let resolved else {
                        self.finish(nil)
                        return
                    }
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                    self.finish(.window(resolved), mode: mode)
                }
                return
            }
            // Click-without-drag: pick the window UNDER THE CLICK POINT. The hover
            // highlight resolves asynchronously off a possibly-stale snapshot, so on a
            // fast move-and-click it can still be the PREVIOUS window (or nil) —
            // committing it captured a window the user never pointed at. The highlight
            // only serves as fallback if the fresh lookup fails.
            let fallback = highlightedWindow
            // Session/gesture token: teardown and every new mouseDown bump this, so a
            // slow lookup can never commit into a later session or a newer gesture
            // (isPresenting alone is not session-scoped — it is true again for the next
            // session).
            let generation = clickGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                let resolved = await self.resolveClickedWindow(atAppKitPoint: globalPoint) ?? fallback
                guard generation == self.clickGeneration, self.isPresenting else {
                    self.finish(nil)
                    return
                }
                if let resolved {
                    // Tactile commit tick — a no-op on non-Force-Touch input devices.
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                    self.finish(.window(resolved), mode: mode)
                } else {
                    self.finish(nil)
                }
            }
            return
        }

        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            finish(nil)
            return
        }
        let globalRect = Geometry.normalizedRect(from: anchor, to: globalPoint)
        guard globalRect.width >= 1, globalRect.height >= 1 else {
            finish(nil)
            return
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        finish(.region(Geometry.appKitToCG(globalRect, primaryScreenHeight: primaryHeight)), mode: mode)
    }

    func selectionViewMouseMoved(to globalPoint: CGPoint) {
        guard !isDragging else { return }
        if let constrainedCGFrame, let primaryHeight = NSScreen.screens.first?.frame.height,
            !Geometry.cgToAppKit(constrainedCGFrame, primaryScreenHeight: primaryHeight).contains(globalPoint)
        { return }
        let globalPoint = clampedAppKitPoint(globalPoint)
        // Newest-wins: bumping per spawn also drops a slower, older lookup that
        // would otherwise overwrite a fresher highlight out of order.
        snapGeneration &+= 1
        let generation = snapGeneration
        Task { await updateWindowSnap(at: globalPoint, generation: generation) }
    }

    func selectionViewCancel() {
        finish(nil)
    }

    // MARK: - Window snap

    /// Reads only the cache's last-known snapshot -- never triggers a fresh
    /// `SCShareableContent` fetch from a mouseMoved callback. Drops its result when
    /// the session it was spawned for is no longer the current one (see `snapGeneration`).
    private func updateWindowSnap(at globalPoint: CGPoint, generation: Int) async {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        if let frozenSnapshot {
            guard generation == snapGeneration, isPresenting else { return }
            let cgPoint = appKitPointToCG(globalPoint, primaryScreenHeight: primaryHeight)
            let window = frozenSnapshot.window(atCGPoint: cgPoint)
            if window != highlightedFrozenWindow {
                if window != nil {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
                highlightedFrozenWindow = window
                updateRendering()
            }
            return
        }
        guard let content = await shareableContentCache.lastKnownContent() else {
            guard generation == snapGeneration, isPresenting else { return }
            if highlightedWindow != nil {
                highlightedWindow = nil
                updateRendering()
            }
            return
        }
        guard generation == snapGeneration, isPresenting else { return }
        let cgPoint = appKitPointToCG(globalPoint, primaryScreenHeight: primaryHeight)

        let capturableIDs = Set(content.windows.filter { $0.isOnScreen }.map { $0.windowID })
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownWindowIDs = Set(
            content.windows
                .filter { $0.owningApplication?.bundleIdentifier == ownBundleID }
                .map { $0.windowID }
        )

        let topmostID = await WindowSnapper.topmostWindowID(
            atCGPoint: cgPoint,
            capturableIDs: capturableIDs,
            ownWindowIDs: ownWindowIDs
        )

        guard generation == snapGeneration, isPresenting else { return }

        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let window = topmostID.flatMap { byID[$0] }

        if window?.windowID != highlightedWindow?.windowID {
            // Subtle level-change tick as the snap target switches (Finder-style).
            if window != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
            highlightedWindow = window
            updateRendering()
        }
    }

    /// The SCWindow under a clicked point: geometry from a FRESH window-server list
    /// (own windows excluded by pid), mapped into shareable content — with one bounded
    /// refresh when the window is newer than the cached snapshot. Without the refresh a
    /// just-opened window could not be picked at all and the click fell through to the
    /// window behind it.
    private func resolveClickedWindow(atAppKitPoint point: CGPoint) async -> SCWindow? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let cgPoint = appKitPointToCG(point, primaryScreenHeight: primaryHeight)
        guard let id = await WindowSnapper.clickTopmostWindowID(atCGPoint: cgPoint) else { return nil }
        if let known = await shareableContentCache.lastKnownContent()?.windows.first(where: { $0.windowID == id }) {
            return known
        }
        let fresh = try? await shareableContentCache.content(forceRefresh: true)
        return fresh?.windows.first { $0.windowID == id }
    }

    private func resolveFrozenWindow(id: CGWindowID) async -> SCWindow? {
        if let known = await shareableContentCache.lastKnownContent()?.windows.first(where: { $0.windowID == id }) {
            return known
        }
        if let current = try? await shareableContentCache.content(),
            let window = current.windows.first(where: { $0.windowID == id })
        {
            return window
        }
        let fresh = try? await shareableContentCache.content(forceRefresh: true)
        return fresh?.windows.first { $0.windowID == id }
    }

    /// Converts a single AppKit-space point via `Geometry.appKitToCG` (a zero-size
    /// rect's origin) rather than hand-flipping Y here.
    private func appKitPointToCG(_ point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        Geometry.appKitToCG(CGRect(origin: point, size: .zero), primaryScreenHeight: primaryScreenHeight).origin
    }

    // MARK: - Rendering

    private func updateRendering() {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let globalSelection: CGRect? = {
            guard isDragging, let dragAnchor, let dragCurrent else { return nil }
            return Geometry.normalizedRect(from: dragAnchor, to: dragCurrent)
        }()

        for (screen, view) in zip(presentedScreens, views) {
            if let constrainedCGFrame,
                !Self.framesMatch(
                    Geometry.appKitToCG(screen.frame, primaryScreenHeight: primaryHeight),
                    constrainedCGFrame
                )
            {
                view.selectionRect = nil
                view.highlightRect = nil
                view.badge = nil
                continue
            }
            // OCR mode from either a right-button drag (activeIsRight) or a .text hold/chord —
            // but NOT while recording, where the right button means "whole screen", not OCR.
            view.selectionIsText = (activeIsRight || holdIsText) && !rightClickWholeScreen
            guard globalSelection != nil || highlightedWindow != nil || highlightedFrozenWindow != nil else {
                view.selectionRect = nil
                view.highlightRect = nil
                view.badge = nil
                continue
            }

            if let globalSelection {
                let intersection = globalSelection.intersection(screen.frame)
                let localSelection = intersection.isNull ? nil : localRect(intersection, in: screen)
                view.selectionRect = localSelection
                view.highlightRect = nil

                if let dragCurrent, let localSelection, screen.frame.contains(dragCurrent) {
                    let pixelSize = Geometry.pixelSize(of: globalSelection, scale: screen.backingScaleFactor)
                    view.badge = (localSelection, "\(pixelSize.w) \u{00d7} \(pixelSize.h)")
                } else {
                    view.badge = nil
                }
            } else if let highlightedWindow {
                let appKitFrame = Geometry.cgToAppKit(highlightedWindow.frame, primaryScreenHeight: primaryHeight)
                let intersection = appKitFrame.intersection(screen.frame)
                view.highlightRect = intersection.isNull ? nil : localRect(intersection, in: screen)
                view.selectionRect = nil
                view.badge = nil
            } else if let highlightedFrozenWindow {
                let appKitFrame = Geometry.cgToAppKit(highlightedFrozenWindow.frame, primaryScreenHeight: primaryHeight)
                let intersection = appKitFrame.intersection(screen.frame)
                view.highlightRect = intersection.isNull ? nil : localRect(intersection, in: screen)
                view.selectionRect = nil
                view.badge = nil
            }
        }
    }

    private func localRect(_ globalRect: CGRect, in screen: NSScreen) -> CGRect {
        CGRect(
            x: globalRect.minX - screen.frame.minX,
            y: globalRect.minY - screen.frame.minY,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    private func screensForCurrentSession(primaryScreenHeight: CGFloat) -> [NSScreen] {
        guard let constrainedCGFrame else { return NSScreen.screens }
        guard NSScreen.screens.contains(where: { screen in
            let frame = Geometry.appKitToCG(screen.frame, primaryScreenHeight: primaryScreenHeight)
            return Self.framesMatch(frame, constrainedCGFrame)
        }) else { return [] }
        return NSScreen.screens
    }

    private func snapshotMatchesCurrentDisplays(_ snapshot: FrozenDesktopSnapshot) -> Bool {
        guard !snapshot.displays.isEmpty else { return false }
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return false }
        let currentFrames = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            screen.cgDirectDisplayID.map {
                ($0, Geometry.appKitToCG(screen.frame, primaryScreenHeight: primaryHeight))
            }
        })
        return snapshot.displays.allSatisfy { display in
            guard let current = currentFrames[display.id] else { return false }
            return Self.framesMatch(current, display.cgFrame)
                && constrainedCGFrame.map { Self.framesMatch($0, display.cgFrame) } != false
        }
    }

    private func clampedAppKitPoint(_ point: CGPoint) -> CGPoint {
        guard let constrainedCGFrame,
            let primaryHeight = NSScreen.screens.first?.frame.height
        else { return point }
        let frame = Geometry.cgToAppKit(constrainedCGFrame, primaryScreenHeight: primaryHeight)
        return CGPoint(
            x: min(max(point.x, frame.minX), frame.maxX),
            y: min(max(point.y, frame.minY), frame.maxY)
        )
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.01
            && abs(lhs.minY - rhs.minY) < 0.01
            && abs(lhs.width - rhs.width) < 0.01
            && abs(lhs.height - rhs.height) < 0.01
    }
}
