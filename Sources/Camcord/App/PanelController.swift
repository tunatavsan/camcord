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
    /// True while an EXPLICIT close() (e.g. a capture action closing the panel) is in
    /// flight, so its close doesn't arm the transient-auto-close reopen guard and
    /// swallow a legitimate status-button click that follows.
    private var isExplicitClose = false
    /// Global mouse-down monitor: `.transient` reliably closes on clicks INSIDE our
    /// process, but for a menu-bar agent app a click on the desktop or another app is
    /// not always caught — this closes the panel (animated) on any such outside click.
    private var outsideClickMonitor: Any?

    init(model: RecordingStateModel, actions: PanelActions) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(rootView: CapturePanelView(model: model, actions: actions))
        // Keep the controller's preferredContentSize synced to the SwiftUI content's
        // ideal size. Without a definite size the popover lays out in two passes and
        // anchors its beak against the wrong (pre-resize) frame — the panel then opens
        // a whole content-height below the status item instead of right under it.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
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
        show(relativeTo: button, bumpToken: true)
    }

    /// Programmatically opens the panel (e.g. to surface the "recording finished" card
    /// when the recording was stopped via a shortcut with the panel closed). Deliberately
    /// does NOT bump `panelOpenToken`, so the fresh-open grid-reset (which clears
    /// `finishedURL`) doesn't wipe the very card we're opening to show.
    func present(relativeTo button: NSStatusBarButton) {
        guard !popover.isShown else { return }
        show(relativeTo: button, bumpToken: false)
    }

    private func show(relativeTo button: NSStatusBarButton, bumpToken: Bool) {
        if bumpToken { model.panelOpenToken &+= 1 }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // A rapid open → close → reopen can reach here before the previous close's
        // popoverDidClose has removed its monitor; drop any stale one first so it can't leak.
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // A click landed in another app / the desktop while the panel is open.
            // Global monitors never see our own process's events, so this can't fire
            // for a status-item click. Animated close (matches the system panels).
            self?.popover.performClose(nil)
        }
    }

    func close() {
        // Reset happens in popoverDidClose (fires after the close animation), so the
        // flag still holds when that late callback would otherwise stamp the guard.
        isExplicitClose = true
        popover.performClose(nil)
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    /// Stamped in BOTH close delegate callbacks: `popoverDidClose` only fires after
    /// the close animation completes, which can be later than the same click's
    /// mouse-UP — by then `toggle()` would have read a stale timestamp and reopened
    /// the popover it just dismissed. `popoverWillClose` arms the guard immediately.
    /// Only a transient auto-close (outside click) arms it — an explicit close() from
    /// our own actions should not swallow the user's next status-button click.
    nonisolated func popoverWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !isExplicitClose else { return }
            lastCloseAt = ContinuousClock.now
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            removeOutsideClickMonitor()
            if isExplicitClose {
                isExplicitClose = false
                return
            }
            lastCloseAt = ContinuousClock.now
        }
    }
}
