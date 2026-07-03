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

    // Global = AppKit screen space (bottom-left origin, Y up).
    private var dragAnchor: CGPoint?
    private var dragCurrent: CGPoint?
    private var isDragging = false
    private var highlightedWindow: SCWindow?

    private static let clickMovementThreshold: CGFloat = 4

    init(shareableContentCache: ShareableContentCache) {
        self.shareableContentCache = shareableContentCache
    }

    /// Shows the overlay and suspends until the user picks a region/window or cancels.
    func selectRegion() async -> SelectionResult? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentPanels()
        }
    }

    // MARK: - Presentation

    private func presentPanels() {
        NSCursor.crosshair.push()
        // Kick off a refresh so window-snap has something reasonably fresh; mouseMoved
        // itself only ever reads the last-known snapshot, never blocks on a fetch.
        Task { await shareableContentCache.refreshInBackground() }

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

            panels.append(panel)
            views.append(view)

            panel.orderFrontRegardless()
            if screen.frame.contains(mouseLocation) {
                keyPanel = panel
            }
        }

        // Make key WITHOUT activating the app (no NSApp.activate call).
        (keyPanel ?? panels.first)?.makeKey()
    }

    private func teardown() {
        NSCursor.pop()
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
        teardown()
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: result)
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
        finish(.region(Geometry.appKitToCG(globalRect, primaryScreenHeight: primaryHeight)))
    }

    func selectionViewMouseMoved(to globalPoint: CGPoint) {
        guard !isDragging else { return }
        Task { await updateWindowSnap(at: globalPoint) }
    }

    func selectionViewCancel() {
        finish(nil)
    }

    // MARK: - Window snap

    /// Reads only the cache's last-known snapshot -- never triggers a fresh
    /// `SCShareableContent` fetch from a mouseMoved callback.
    private func updateWindowSnap(at globalPoint: CGPoint) async {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        guard let content = await shareableContentCache.lastKnownContent() else {
            if highlightedWindow != nil {
                highlightedWindow = nil
                updateRendering()
            }
            return
        }
        let cgPoint = appKitPointToCG(globalPoint, primaryScreenHeight: primaryHeight)
        let window = WindowSnapper.window(atCGPoint: cgPoint, content: content)
        if window?.windowID != highlightedWindow?.windowID {
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
