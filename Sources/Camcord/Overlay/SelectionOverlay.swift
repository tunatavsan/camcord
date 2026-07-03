import AppKit
@preconcurrency import ScreenCaptureKit

/// What the user picked -- a dragged region (already in CG/SCK screen space) or a
/// window snapped to and clicked on.
enum SelectionResult {
    case region(CGRect)
    case window(SCWindow)
}

/// A borderless, nonactivating panel covering one screen. `canBecomeKey` must return
/// true for a `.nonactivatingPanel` to receive key events (Esc) at all.
final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
    private var continuation: CheckedContinuation<SelectionResult?, Never>?
    /// Non-nil while a HOLD session (mouse side button held; events driven by the
    /// CGEventTap, not by the panels) is active. Every exit path funnels through
    /// `finish(_:)`, which fires this exactly once.
    private var holdEndHandler: ((SelectionResult?) -> Void)?
    private var isPresenting = false

    // Global = AppKit screen space (bottom-left origin, Y up).
    private var dragAnchor: CGPoint?
    private var dragCurrent: CGPoint?
    private var isDragging = false
    private var highlightedWindow: SCWindow?
    /// Session token for the async window-snap lookups: they hop through the cache
    /// actor, so one can resolve after teardown (or after a newer lookup) and would
    /// otherwise write a stale `highlightedWindow` into the wrong session — a click
    /// could then silently pick a window that was never visibly highlighted.
    private var snapGeneration = 0
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
    func selectRegion() async -> SelectionResult? {
        guard !isPresenting else { return nil }
        isPresenting = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentPanels()
        }
    }

    // MARK: - Hold session (side button held down; driven by the event tap)

    /// Starts a hold-to-capture session anchored at the button-down location.
    /// `onEnd` fires exactly once, on whichever exit path ends the session (release,
    /// Esc, display change, zero screens).
    func beginHoldSelection(atCGPoint cgPoint: CGPoint, onEnd: @escaping (SelectionResult?) -> Void) {
        guard !isPresenting else {
            onEnd(nil)
            return
        }
        isPresenting = true
        holdEndHandler = onEnd
        // No window-snap in hold mode: it is region-only, and the seeded highlight
        // would just flicker under the anchor before the drag passes the threshold.
        presentPanels(seedWindowSnap: false)
        guard isPresenting else { return }  // zero-screens path already ended the session
        let point = cgToAppKitPoint(cgPoint)
        dragAnchor = point
        dragCurrent = point
        isDragging = false
    }

    func updateHoldSelection(toCGPoint cgPoint: CGPoint) {
        guard isPresenting, holdEndHandler != nil, let anchor = dragAnchor else { return }
        let point = cgToAppKitPoint(cgPoint)
        dragCurrent = point
        if !isDragging {
            let movement = hypot(point.x - anchor.x, point.y - anchor.y)
            guard movement >= Self.clickMovementThreshold else { return }
            isDragging = true
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
        let point = cgToAppKitPoint(cgPoint)
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
        // No screens (all displays asleep/detached): without this guard no panel is
        // ever created, so no event could resume the continuation -- selectRegion()
        // would hang forever with isPresenting stuck.
        guard !NSScreen.screens.isEmpty else {
            finish(nil)
            return
        }

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

        for screen in NSScreen.screens {
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

            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.delegate = self
            view.backingScale = screen.backingScaleFactor
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

        // Seed window-snap for the cursor's RESTING position: tracking areas emit no
        // mouseMoved for a cursor already inside the view, so the natural
        // "hover the target, then press the hotkey, then click" flow would otherwise
        // read highlightedWindow == nil and cancel instead of picking the window.
        if seedWindowSnap {
            snapGeneration &+= 1
            let generation = snapGeneration
            Task { await updateWindowSnap(at: mouseLocation, generation: generation) }
        }
    }

    private func teardown() {
        // Orphan any in-flight window-snap lookup so it can't write into the next session.
        snapGeneration &+= 1
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
        dragAnchor = nil
        dragCurrent = nil
        isDragging = false
        highlightedWindow = nil
    }

    private func finish(_ result: SelectionResult?) {
        // Idempotent: a second finish (e.g. a stray cancel after teardown) must not
        // pop the cursor stack again or resume a dead continuation.
        guard isPresenting else { return }
        teardown()
        isPresenting = false
        let continuation = self.continuation
        self.continuation = nil
        let holdHandler = holdEndHandler
        holdEndHandler = nil
        continuation?.resume(returning: result)
        holdHandler?(result)
    }

    // MARK: - SelectionViewDelegate

    func selectionViewMouseDown(at globalPoint: CGPoint) {
        // Don't switch to selection-drag rendering yet -- stay in window-snap
        // highlight mode until mouseDragged confirms an actual drag past the
        // click-movement threshold. Avoids the highlight flickering off on a
        // plain click before mouseUp gets a chance to read `highlightedWindow`.
        dragAnchor = globalPoint
        dragCurrent = globalPoint
        isDragging = false
    }

    func selectionViewMouseDragged(to globalPoint: CGPoint) {
        guard let anchor = dragAnchor else { return }
        dragCurrent = globalPoint

        if !isDragging {
            let movement = hypot(globalPoint.x - anchor.x, globalPoint.y - anchor.y)
            guard movement >= Self.clickMovementThreshold else { return }
            isDragging = true
        }
        updateRendering()
    }

    func selectionViewMouseUp(at globalPoint: CGPoint) {
        guard let anchor = dragAnchor else { return }
        let wasDragging = isDragging
        dragAnchor = nil
        dragCurrent = nil
        isDragging = false

        guard wasDragging else {
            // Click-without-drag: over a highlighted window -> pick it; over empty space -> cancel.
            if let highlightedWindow {
                // Tactile commit tick — a no-op on non-Force-Touch input devices.
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                finish(.window(highlightedWindow))
            } else {
                finish(nil)
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
        finish(.region(Geometry.appKitToCG(globalRect, primaryScreenHeight: primaryHeight)))
    }

    func selectionViewMouseMoved(to globalPoint: CGPoint) {
        guard !isDragging else { return }
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
        let window = WindowSnapper.window(atCGPoint: cgPoint, content: content)
        if window?.windowID != highlightedWindow?.windowID {
            // Subtle level-change tick as the snap target switches (Finder-style).
            if window != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
            highlightedWindow = window
            updateRendering()
        }
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

        for (screen, view) in zip(NSScreen.screens, views) {
            guard globalSelection != nil || highlightedWindow != nil else {
                view.selectionRect = nil
                view.highlightRect = nil
                view.badge = nil
                view.needsDisplay = true
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
            }
            view.needsDisplay = true
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
}
