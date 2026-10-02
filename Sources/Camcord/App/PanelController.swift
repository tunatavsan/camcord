import AppKit
import Combine
import QuartzCore
import SwiftUI

/// A nonactivating palette can accept key focus for controls such as the finished
/// card's rename field without bringing Camcord's whole agent app to the front.
private final class DetachedControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The menu-bar panel itself: a borderless palette under the status item. It becomes key
/// without activating Camcord, so its glass is drawn in its active state from the first frame
/// instead of the washed-out inactive one (owner, 2026-10-02).
private final class AnchoredControlPanel: NSPanel {
    var cancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { cancel?() }
}

/// Owns the menu-bar panel and the optional detached native palette. Both use one retained
/// SwiftUI host, so their local control state and async work stay singular while the
/// presentation surface changes.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    typealias DetachedPanelPresenter = @MainActor (_ panel: NSPanel, _ shouldFocus: Bool) -> Bool

    private let hostingController: NSHostingController<CapturePanelView>
    private let model: RecordingStateModel
    private let detachedPanelPresenter: DetachedPanelPresenter
    private var modelObservers = Set<AnyCancellable>()
    private var anchoredPanel: AnchoredControlPanel?
    private var anchoredIsPresented = false
    private var detachedPanel: DetachedControlPanel?
    private var detachedIsPresented = false
    private var hasPlacedDetachedPanel = false
    /// `.transient` closes on an outside click or when the panel loses key; a recording hold
    /// keeps it open (`.applicationDefined`).
    private var behavior: NSPopover.Behavior = .transient
    private var lastTransientCloseAt: ContinuousClock.Instant?
    /// Global monitors never see our own process's events, so this only fires for clicks
    /// on the desktop or in another app.
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
        // Windows are sized from the same state that sizes the SwiftUI view, never from
        // the host's measurements, so the panel always opens at its fixed dimension.
        hostingController.sizingOptions = []
        super.init()
        hostingController.view.wantsLayer = true

        Publishers.CombineLatest3(model.$state, model.$isFinishing, model.$finishedURL)
            .sink { [weak self] state, isFinishing, finishedURL in
                MainActor.assumeIsolated {
                    self?.resizePanelsIfNeeded(state: state, isFinishing: isFinishing, finishedURL: finishedURL)
                }
            }
            .store(in: &modelObservers)
    }

    var isShown: Bool { anchoredIsPresented || detachedIsPresented }

    /// Narrow test seam for native-window lifecycle and policy assertions.
    var detachedPanelForTesting: NSPanel? { detachedPanel }
    var anchoredPanelForTesting: NSPanel? { anchoredPanel }
    var popoverBehaviorForTesting: NSPopover.Behavior { behavior }

    func toggle(relativeTo button: NSStatusBarButton) {
        if detachedIsPresented || anchoredIsPresented {
            close()
            return
        }
        // The click that took key away from the panel (and so closed it) must not reopen it.
        if let lastTransientCloseAt, ContinuousClock.now - lastTransientCloseAt < .milliseconds(300) {
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
        guard !anchoredIsPresented else { return }
        show(relativeTo: button, bumpToken: false)
    }

    /// Opens the same control view in a compact native palette. Unlike a fresh
    /// status-button toggle, this preserves a completed recording card.
    func presentDetached() {
        presentDetached(focusIfVisible: true, bumpToken: false)
    }

    private func presentDetached(focusIfVisible: Bool, bumpToken: Bool) {
        hideAnchored(transient: false)
        showDetached(focusIfVisible: focusIfVisible, bumpToken: bumpToken)
    }

    private func show(relativeTo button: NSStatusBarButton, bumpToken: Bool) {
        guard let anchor = anchorRect(of: button) else {
            presentDetached(focusIfVisible: false, bumpToken: bumpToken)
            return
        }
        if bumpToken { model.panelOpenToken &+= 1 }
        let panel = anchoredPanel ?? makeAnchoredPanel()
        attachHost(to: panel)
        behavior = model.state != .idle || model.isStarting || model.isArmed ? .applicationDefined : .transient
        panel.setFrame(anchoredFrame(below: anchor, size: desiredContentSize()), display: false)
        // Key without activating the app: the glass draws active and Esc/⌘0 reach the panel.
        panel.makeKeyAndOrderFront(nil)
        anchoredIsPresented = panel.isVisible
        model.isPanelVisible = anchoredIsPresented
        if anchoredIsPresented { animateEntrance(of: panel) }
        installOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        guard behavior == .transient, anchoredIsPresented else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideAnchored(transient: true) }
        }
    }

    /// The status button's frame on screen, or nil when it is not on any display.
    private func anchorRect(of button: NSStatusBarButton) -> NSRect? {
        guard !button.isHidden,
              !button.bounds.isEmpty,
              let window = button.window,
              window.isVisible
        else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { return nil }
        return rect
    }

    /// Centred under the status item, kept inside the visible frame like the system's own
    /// menu-bar panels.
    private func anchoredFrame(below anchor: NSRect, size: NSSize) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor
        let margin: CGFloat = 8, gap: CGFloat = 6
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + margin), visible.maxX - margin - size.width)
        let top = min(anchor.minY, visible.maxY) - gap
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    private func attachHost(to panel: NSPanel) {
        // Borderless, the window takes its shape (and its shadow) from the content: clip it
        // to the glass's corners or AppKit outlines the whole rectangle.
        let anchored = panel === anchoredPanel
        if let layer = hostingController.view.layer {
            layer.cornerRadius = anchored ? Theme.Radius.floating : 0
            layer.cornerCurve = .continuous
            layer.masksToBounds = anchored
        }
        guard panel.contentViewController !== hostingController else { return }
        if panel !== anchoredPanel { anchoredPanel?.contentViewController = nil }
        if panel !== detachedPanel { detachedPanel?.contentViewController = nil }
        panel.contentViewController = hostingController
    }

    private func showDetached(focusIfVisible: Bool, bumpToken: Bool) {
        if bumpToken { model.panelOpenToken &+= 1 }

        let panel = detachedPanel ?? makeDetachedPanel()
        attachHost(to: panel)
        resizeDetachedPanel(panel)
        panel.animationBehavior = .none
        let wasVisible = panel.isVisible

        // `.nonactivatingPanel` keeps the previous application active even when
        // an explicit presentation asks for keyboard focus. Passive completion and
        // status-anchor fallback presentations leave the current key window alone.
        detachedIsPresented = detachedPanelPresenter(panel, focusIfVisible)
        model.isPanelVisible = panel.isVisible
        if panel.isVisible && !wasVisible { animateEntrance(of: panel) }
    }

    private func animateEntrance(of panel: NSPanel) {
        let view = hostingController.view
        // Finish graph/layout work before the render server moves the retained panel layer.
        view.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: PanelEntranceMotion.key)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        layer.add(PanelEntranceMotion.animation(), forKey: PanelEntranceMotion.key)
    }

    private func makeAnchoredPanel() -> AnchoredControlPanel {
        let panel = AnchoredControlPanel(
            contentRect: NSRect(origin: .zero, size: desiredContentSize()),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.delegate = self
        panel.cancel = { [weak self] in self?.close() }
        anchoredPanel = panel
        return panel
    }

    private func makeDetachedPanel() -> DetachedControlPanel {
        let panel = DetachedControlPanel(
            contentRect: NSRect(origin: .zero, size: desiredContentSize()),
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

    private func desiredContentSize() -> NSSize {
        NSSize(width: CapturePanelView.panelWidth,
               height: CapturePanelView.height(state: model.state, isFinishing: model.isFinishing,
                                               finished: model.finishedURL != nil))
    }

    private func resizePanelsIfNeeded(state: RecordingController.UIState, isFinishing: Bool, finishedURL: URL?) {
        let size = NSSize(width: CapturePanelView.panelWidth,
                          height: CapturePanelView.height(state: state, isFinishing: isFinishing,
                                                          finished: finishedURL != nil))
        if let detachedPanel { resizeDetachedPanel(detachedPanel, contentSize: size) }
        if let anchoredPanel, anchoredIsPresented {
            // The top edge stays under the status item; the panel grows downwards.
            let old = anchoredPanel.frame
            let frame = NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height)
            guard !NSEqualRects(old, frame) else { return }
            anchoredPanel.setFrame(frame, display: true, animate: false)
            anchoredPanel.invalidateShadow()
        }
    }

    private func resizeDetachedPanel(_ panel: NSPanel, contentSize: NSSize? = nil) {
        let contentSize = contentSize ?? desiredContentSize()
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
        behavior = .applicationDefined
        removeOutsideClickMonitor()
    }

    func releaseRecordingHold() {
        behavior = .transient
        installOutsideClickMonitor()
        close()
    }

    func close() {
        hideAnchored(transient: false)
        model.isPanelVisible = false
        detachedIsPresented = false
        detachedPanel?.close()
    }

    /// A transient close (outside click, lost key) arms the reopen guard for the same click.
    private func hideAnchored(transient: Bool) {
        removeOutsideClickMonitor()
        guard anchoredIsPresented || anchoredPanel?.isVisible == true else { return }
        anchoredIsPresented = false
        anchoredPanel?.orderOut(nil)
        if transient { lastTransientCloseAt = ContinuousClock.now }
        model.isPanelVisible = detachedIsPresented
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        let window = (notification.object as AnyObject?).map(ObjectIdentifier.init)
        MainActor.assumeIsolated {
            guard let anchoredPanel, window == ObjectIdentifier(anchoredPanel),
                  anchoredIsPresented, behavior == .transient else { return }
            hideAnchored(transient: true)
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        let window = (notification.object as AnyObject?).map(ObjectIdentifier.init)
        MainActor.assumeIsolated {
            guard let detachedPanel, window == ObjectIdentifier(detachedPanel) else { return }
            detachedIsPresented = false
            model.isPanelVisible = anchoredIsPresented
        }
    }
}

private extension NSRect {
    var area: CGFloat { width * height }
}

/// A short drop and fade, at the display's own refresh rate.
private enum PanelEntranceMotion {
    static let key = "panelEntrance"
    static func animation() -> CAAnimationGroup {
        let offset = CABasicAnimation(keyPath: "transform.translation.y")
        offset.fromValue = 6
        offset.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [offset, fade]
        group.duration = 0.16
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        group.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        return group
    }
}
