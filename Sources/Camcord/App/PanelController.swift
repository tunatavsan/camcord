import AppKit
import SwiftUI

/// Owns the menu-bar popover (left-click surface). Transient behavior: it closes
/// itself on any outside click; actions that open other UI (overlay, settings)
/// close it explicitly first so the surfaces never fight.
@MainActor
final class PanelController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let model: RecordingStateModel
    private var lastCloseAt: ContinuousClock.Instant?

    init(model: RecordingStateModel, actions: PanelActions) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: CapturePanelView(model: model, actions: actions)
        )
    }

    var isShown: Bool { popover.isShown }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            close()
            return
        }
        // A click on the status button while the panel is open can be split by the
        // transient auto-close: the popover dismisses on mouse-DOWN, then this action
        // fires on mouse-UP and would flicker the panel straight back open. If the
        // popover closed within the same click's window, treat this as "close".
        if let lastCloseAt, ContinuousClock.now - lastCloseAt < .milliseconds(300) {
            return
        }
        model.panelOpenToken &+= 1
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close() {
        popover.performClose(nil)
    }

    /// Stamped in BOTH close delegate callbacks: `popoverDidClose` only fires after
    /// the close animation completes, which can be later than the same click's
    /// mouse-UP — by then `toggle()` would have read a stale timestamp and reopened
    /// the popover it just dismissed. `popoverWillClose` arms the guard immediately.
    nonisolated func popoverWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            lastCloseAt = ContinuousClock.now
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            lastCloseAt = ContinuousClock.now
        }
    }
}
