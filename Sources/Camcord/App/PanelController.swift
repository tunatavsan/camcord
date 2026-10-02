import AppKit
import Combine
import QuartzCore
import SwiftUI

/// A nonactivating palette can accept key focus for controls such as the finished
/// card's rename field without bringing Camcord's whole agent app to the front.
private final class DetachedControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the menu-bar popover and the optional detached native palette. Both use
/// one retained SwiftUI host, so their local control state and async work stay
/// singular while the presentation surface changes.
@MainActor
final class PanelController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    typealias DetachedPanelPresenter = @MainActor (_ panel: NSPanel, _ shouldFocus: Bool) -> Bool

    private struct DetachedPresentationRequest {
        var shouldFocus: Bool
        var bumpToken: Bool
    }

    private let popover = NSPopover()
    private let hostingController: NSHostingController<CapturePanelView>
    private let model: RecordingStateModel
    private let detachedPanelPresenter: DetachedPanelPresenter
    private var modelObservers = Set<AnyCancellable>()
    private var detachedPanel: DetachedControlPanel?
    private var detachedIsPresented = false
    private var hasPlacedDetachedPanel = false
    private var lastCloseAt: ContinuousClock.Instant?
    /// True while an EXPLICIT close() (e.g. a capture action closing the panel) is in
    /// flight, so its close doesn't arm the transient-auto-close reopen guard and
    /// swallow a legitimate status-button click that follows.
    private var isExplicitClose = false
    private var isClosing = false
    private weak var pendingCompletionAnchor: NSStatusBarButton?
    private var pendingDetachedPresentation: DetachedPresentationRequest?
    /// Global mouse-down monitor: `.transient` reliably closes on clicks INSIDE our
    /// process, but for a menu-bar agent app a click on the desktop or another app is
    /// not always caught — this closes the panel (animated) on any such outside click.
    private var outsideClickMonitor: Any?

    init(
        model: RecordingStateModel,
        actions: PanelActions,
        library: LibraryStore? = nil,
        defaults: UserDefaults? = nil,
        detachedPanelPresenter: DetachedPanelPresenter? = nil
    ) {
        self.model = model
        self.detachedPanelPresenter = detachedPanelPresenter ?? { panel, shouldFocus in
            if shouldFocus {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
            return panel.isVisible
        }
        hostingController = NSHostingController(rootView: CapturePanelView(model: model, actions: actions, library: library, defaults: defaults))
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        // Keep the controller's preferredContentSize synced to the SwiftUI content's
        // ideal size. Without a definite size the popover lays out in two passes and
        // anchors its beak against the wrong (pre-resize) frame — the panel then opens
        // a whole content-height below the status item instead of right under it.
        hostingController.sizingOptions = [.preferredContentSize]
        hostingController.view.wantsLayer = true
        popover.contentViewController = hostingController

        Publishers.CombineLatest3(model.$state, model.$isFinishing, model.$finishedURL)
            .sink { [weak self] state, isFinishing, finishedURL in
                MainActor.assumeIsolated {
                    self?.resizeDetachedPanelIfNeeded(
                        state: state,
                        isFinishing: isFinishing,
                        finishedURL: finishedURL
                    )
                }
            }
            .store(in: &modelObservers)
    }

    var isShown: Bool { popover.isShown || detachedIsPresented }

    /// Narrow test seam for native-window lifecycle and policy assertions.
    var detachedPanelForTesting: NSPanel? { detachedPanel }
    var popoverBehaviorForTesting: NSPopover.Behavior { popover.behavior }

    func toggle(relativeTo button: NSStatusBarButton) {
        if detachedIsPresented {
            close()
            return
        }
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
        if detachedIsPresented {
            showDetached(focusIfVisible: false, bumpToken: false)
            return
        }
        if isClosing {
            pendingCompletionAnchor = button
            return
        }
        guard !popover.isShown else { return }
        show(relativeTo: button, bumpToken: false)
    }

    /// Opens the same control view in a compact native palette. Unlike a fresh
    /// status-button toggle, this preserves a completed recording card.
    func presentDetached() {
        presentDetached(focusIfVisible: true, bumpToken: false)
    }

    private func presentDetached(focusIfVisible: Bool, bumpToken: Bool) {
        pendingCompletionAnchor = nil

        if detachedIsPresented {
            showDetached(focusIfVisible: focusIfVisible, bumpToken: bumpToken)
            return
        }

        // Reparent the single SwiftUI host only after AppKit has finished closing
        // the transient popover. This prevents two windows briefly owning it.
        if popover.isShown || isClosing {
            if var pending = pendingDetachedPresentation {
                pending.shouldFocus = pending.shouldFocus || focusIfVisible
                pending.bumpToken = pending.bumpToken || bumpToken
                pendingDetachedPresentation = pending
            } else {
                pendingDetachedPresentation = DetachedPresentationRequest(
                    shouldFocus: focusIfVisible,
                    bumpToken: bumpToken
                )
            }
            if popover.isShown {
                isExplicitClose = true
                isClosing = true
                popover.performClose(nil)
            }
            return
        }

        showDetached(focusIfVisible: focusIfVisible, bumpToken: bumpToken)
    }

    private func show(relativeTo button: NSStatusBarButton, bumpToken: Bool) {
        pendingCompletionAnchor = nil
        pendingDetachedPresentation = nil
        isClosing = false
        guard canPresentPopover(relativeTo: button) else {
            presentDetached(focusIfVisible: false, bumpToken: bumpToken)
            return
        }
        if bumpToken { model.panelOpenToken &+= 1 }
        attachHostToPopover()
        // The retained content layer owns the entrance; avoid a second system animation.
        popover.animates = false
        popover.behavior = model.state != .idle || model.isStarting || model.isArmed ? .applicationDefined : .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        model.isPanelVisible = popover.isShown
        if popover.isShown { animateEntrance() }

        // A rapid open → close → reopen can reach here before the previous close's
        // popoverDidClose has removed its monitor; drop any stale one first so it can't leak.
        installOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        guard popover.behavior == .transient else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // A click landed in another app / the desktop while the panel is open.
            // Global monitors never see our own process's events, so this can't fire
            // for a status-item click.
            self?.popover.performClose(nil)
        }
    }

    private func canPresentPopover(relativeTo button: NSStatusBarButton) -> Bool {
        guard !button.isHidden,
              !button.bounds.isEmpty,
              let window = button.window,
              window.isVisible
        else { return false }

        let buttonInWindow = button.convert(button.bounds, to: nil)
        let buttonOnScreen = window.convertToScreen(buttonInWindow)
        return NSScreen.screens.contains { $0.frame.intersects(buttonOnScreen) }
    }

    private func attachHostToPopover() {
        guard popover.contentViewController !== hostingController else { return }
        detachedPanel?.contentViewController = nil
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
    }

    private func showDetached(focusIfVisible: Bool, bumpToken: Bool) {
        if bumpToken { model.panelOpenToken &+= 1 }

        let panel = detachedPanel ?? makeDetachedPanel()
        attachHost(to: panel)
        resizeDetachedPanel(
            panel,
            state: model.state,
            isFinishing: model.isFinishing,
            finishedURL: model.finishedURL
        )
        panel.animationBehavior = .none
        let wasVisible = panel.isVisible

        // `.nonactivatingPanel` keeps the previous application active even when
        // an explicit presentation asks for keyboard focus. Passive completion and
        // status-anchor fallback presentations leave the current key window alone.
        detachedIsPresented = detachedPanelPresenter(panel, focusIfVisible)
        model.isPanelVisible = panel.isVisible
        if panel.isVisible && !wasVisible { animateEntrance() }
    }

    private func animateEntrance() {
        let view = hostingController.view
        // Finish graph/layout work before the render server moves the retained panel layer.
        view.layoutSubtreeIfNeeded()
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: PanelEntranceMotion.offsetKey)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        layer.add(PanelEntranceMotion.animation(), forKey: PanelEntranceMotion.offsetKey)
    }

    private func makeDetachedPanel() -> DetachedControlPanel {
        let contentSize = desiredContentSize(
            state: model.state,
            isFinishing: model.isFinishing,
            finishedURL: model.finishedURL
        )
        let panel = DetachedControlPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Camcord"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.tabbingMode = .disallowed
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        detachedPanel = panel
        return panel
    }

    private func attachHost(to panel: NSPanel) {
        guard panel.contentViewController !== hostingController else { return }
        popover.contentViewController = nil
        // A window does not consume preferredContentSize the way NSPopover does.
        // Disable the hosting controller's automatic window sizing and drive the
        // exact native content rect from the same state that sizes the SwiftUI view.
        hostingController.sizingOptions = []
        panel.contentViewController = hostingController
    }

    private func desiredContentSize(
        state: RecordingController.UIState,
        isFinishing: Bool,
        finishedURL: URL?
    ) -> NSSize {
        let height: CGFloat
        if finishedURL != nil {
            height = CapturePanelView.finishedHeight
        } else if isFinishing {
            height = CapturePanelView.finishingHeight
        } else if state != .idle {
            height = CapturePanelView.activeHeight
        } else {
            height = CapturePanelView.panelHeight
        }
        return NSSize(width: CapturePanelView.panelWidth, height: height)
    }

    private func resizeDetachedPanelIfNeeded(
        state: RecordingController.UIState,
        isFinishing: Bool,
        finishedURL: URL?
    ) {
        guard let detachedPanel else { return }
        resizeDetachedPanel(
            detachedPanel,
            state: state,
            isFinishing: isFinishing,
            finishedURL: finishedURL
        )
    }

    private func resizeDetachedPanel(
        _ panel: NSPanel,
        state: RecordingController.UIState,
        isFinishing: Bool,
        finishedURL: URL?
    ) {
        let contentSize = desiredContentSize(
            state: state,
            isFinishing: isFinishing,
            finishedURL: finishedURL
        )
        let frameSize = panel.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        let oldFrame = panel.frame
        var frame = NSRect(
            x: oldFrame.minX,
            y: oldFrame.maxY - frameSize.height,
            width: frameSize.width,
            height: frameSize.height
        )

        if !hasPlacedDetachedPanel {
            if let screen = screenAtMouseLocation() ?? NSScreen.main ?? NSScreen.screens.first {
                let safeFrame = safeVisibleFrame(of: screen)
                frame.origin = NSPoint(x: safeFrame.maxX - frame.width, y: safeFrame.maxY - frame.height)
                frame = clamped(frame, to: safeFrame)
            }
            hasPlacedDetachedPanel = true
        } else if let screen = bestScreen(for: oldFrame) {
            frame = clamped(frame, to: safeVisibleFrame(of: screen))
        }

        guard !NSEqualRects(panel.frame, frame) else { return }
        // State changes resize atomically; the entrance layer owns presentation motion.
        panel.setFrame(frame, display: panel.isVisible, animate: false)
    }

    private func screenAtMouseLocation() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func bestScreen(for frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        } ?? screenAtMouseLocation() ?? NSScreen.main
    }

    private func safeVisibleFrame(of screen: NSScreen) -> NSRect {
        let inset: CGFloat = 12
        let visible = screen.visibleFrame
        guard visible.width > inset * 2, visible.height > inset * 2 else { return visible }
        return visible.insetBy(dx: inset, dy: inset)
    }

    private func clamped(_ frame: NSRect, to bounds: NSRect) -> NSRect {
        var result = frame
        if frame.width > bounds.width {
            result.origin.x = bounds.minX
        } else {
            result.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
        }
        if frame.height > bounds.height {
            // Keep the title bar reachable even on an unusually short display.
            result.origin.y = bounds.maxY - frame.height
        } else {
            result.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        }
        return result
    }

    /// Keep this exact host in place through target selection and stream startup.
    func keepOpenForRecording() {
        popover.behavior = .applicationDefined
        removeOutsideClickMonitor()
    }

    func releaseRecordingHold() {
        popover.behavior = .transient
        installOutsideClickMonitor()
        close()
    }

    func close() {
        model.isPanelVisible = false
        pendingCompletionAnchor = nil
        pendingDetachedPresentation = nil
        if popover.isShown {
            // Reset happens in popoverDidClose (fires after the close animation), so the
            // flag still holds when that late callback would otherwise stamp the guard.
            isExplicitClose = true
            isClosing = true
            popover.performClose(nil)
        } else {
            removeOutsideClickMonitor()
        }
        detachedIsPresented = false
        detachedPanel?.close()
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
            isClosing = true
            model.isPanelVisible = false
            guard !isExplicitClose else { return }
            lastCloseAt = ContinuousClock.now
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            removeOutsideClickMonitor()
            isClosing = false
            if isExplicitClose {
                isExplicitClose = false
            } else {
                lastCloseAt = ContinuousClock.now
            }
            let detachedRequest = pendingDetachedPresentation
            let completionAnchor = pendingCompletionAnchor
            pendingDetachedPresentation = nil
            pendingCompletionAnchor = nil

            if let detachedRequest {
                showDetached(
                    focusIfVisible: detachedRequest.shouldFocus,
                    bumpToken: detachedRequest.bumpToken
                )
            // Finalization can finish while an outside-click close is animating.
            // Present the completed file only after AppKit releases that popover.
            } else if let button = completionAnchor, model.finishedURL != nil {
                show(relativeTo: button, bumpToken: false)
            }
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            detachedIsPresented = false
            model.isPanelVisible = false
        }
    }
}

private extension NSRect {
    var area: CGFloat { width * height }
}

private enum PanelEntranceMotion {
    static let offsetKey = "panelEntranceOffset"
    static func animation() -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = 4
        animation.toValue = 0
        animation.duration = 0.14
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        return animation
    }
}
