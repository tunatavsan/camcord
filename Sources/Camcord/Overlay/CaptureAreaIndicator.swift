import AppKit
import CoreGraphics
import QuartzCore

/// When the recording frame is visible. A frame that is on all the time is a permanent red
/// rectangle on the user's screen — worst of all in a fullscreen game — so during a
/// recording it stays out of the way entirely and only the hub can summon it: hovering the
/// hub, or the first moment and a half after the start, when it is still saying "this is
/// what I am recording". While armed it shows quietly until Start. A display recording
/// never draws one, and the scrolling-capture border (no hub) is always visible.
struct RecordingFrameVisibility: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        /// A border with no hub: the scrolling-capture region.
        case plain
        case armed
        case recording
    }

    /// How long after a start the frame stays up on its own.
    static let startGrace: TimeInterval = 1.5

    var mode: Mode = .plain
    var hoveringHub = false
    var withinStartGrace = false
    var isDisplayTarget = false

    var alpha: CGFloat {
        if isDisplayTarget { return 0 }
        switch mode {
        case .plain: return 1
        case .armed: return hoveringHub ? 1 : 0.6
        case .recording: return hoveringHub || withinStartGrace ? 1 : 0
        }
    }
}

/// A minimal gradient hairline around a captured area (a recorded window, or a scrolling-
/// capture region). It lives in its OWN borderless panels — different windows than the one
/// being captured — and the stroke sits OUTSIDE the target rect, so it never appears in the
/// capture. Red for recording, blue for scrolling capture.
///
/// The border is drawn with **CALayers** (a masked gradient), not `draw()`, so it is
/// GPU-composited: moving the panel to follow a dragged window is a pure `setFrameOrigin`
/// with ZERO redraw, and the follow is driven by a **CADisplayLink** locked to the display's
/// refresh — the tightest tracking a separate overlay window can do natively (a true cross-
/// process child window, which would be zero-lag, isn't available on macOS). Only a resize
/// rebuilds the layer path.
///
/// The border panel is ALWAYS click-through so the window underneath stays usable. When a
/// stop action is provided, a SEPARATE round control hub (interactive, draggable) floats
/// above it: docked inside a recorded window and following it, or docked to the display for
/// display and region targets.
@MainActor
final class CaptureAreaIndicator {
    typealias PanelPresenter = @MainActor (NSPanel) -> Void

    var onTrackedBoundsChange: ((CGRect) -> Void)?

    private let panelPresenter: PanelPresenter
    private let defaults: UserDefaults
    private var borderPanel: NSPanel?
    private var hub: RecordingHubPanel?
    private var borderView: (any CaptureFrameView)?

    /// The frame's visibility rule, plus the timer that ends the post-start grace.
    private var frame = RecordingFrameVisibility()
    private var startGraceTask: Task<Void, Never>?

    /// Live window-follow state (window recording): a CADisplayLink repositions the border
    /// as the recorded window moves/resizes, and fades it while the window is occluded so
    /// the border never floats over the app that covered it. The hub docks inside the window
    /// and follows it the same frame, but never hides: it is the way to stop the recording.
    private var followWindowID: CGWindowID?
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?
    private var lastFollowedBounds: CGRect?
    /// Leads the border ahead of the window by its smoothed velocity to cancel the inherent
    /// one-frame reactive lag of a separate overlay window (pure/tested — see FollowPredictor).
    private var predictor = FollowPredictor()
    private var followTick = 0
    /// Display-link frames between occlusion checks (position tracks EVERY frame; occlusion
    /// only changes when the user reshuffles windows, so ~10 Hz is plenty).
    private var occlusionCheckInterval = 10
    private var occluded = false

    private static let borderPad: CGFloat = 12

    /// The corner radius the border matches: macOS windows use a continuous ~10pt corner
    /// (Big Sur and later). Tunable in one place if a macOS release changes it.
    private static let macOSWindowCornerRadius: CGFloat = 10

    init(panelPresenter: PanelPresenter? = nil, defaults: UserDefaults = .standard) {
        self.panelPresenter = panelPresenter ?? { $0.orderFrontRegardless() }
        self.defaults = defaults
    }

    /// The window's own corner radius to trace: the standard rounded corner for a normal
    /// window, or 0 for a window that fills a whole display (full-screen / borderless — e.g.
    /// a game — which has sharp corners).
    static func windowCornerRadius(forSize size: CGSize) -> CGFloat {
        let coversWholeScreen = NSScreen.screens.contains {
            abs(size.width - $0.frame.width) < 2 && abs(size.height - $0.frame.height) < 2
        }
        return coversWholeScreen ? 0 : macOSWindowCornerRadius
    }

    func show(
        cgRect: CGRect,
        color: NSColor,
        onStop: (() -> Void)?,
        onPauseResume: (() -> Void)? = nil,
        onTogglePreview: (() -> Void)? = nil
    ) {
        hide()
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let target = Geometry.cgToAppKit(cgRect, primaryScreenHeight: primaryHeight)

        borderPanel = makeBorderPanel(target: target, color: color, lit: onStop == nil)
        if let onStop {
            beginRecordingFrame()
            hub = makeHub(
                mode: .recording,
                target: target,
                onStop: onStop,
                onPauseResume: onPauseResume,
                onTogglePreview: onTogglePreview,
                onCancel: nil
            )
        }
        // The frame's own entrance: it starts at zero and fades up to whatever the rule
        // allows, so nothing on screen snaps into being.
        applyFrameVisibility(animated: true)
    }

    /// Shows ONLY the control hub (no glowing border). Useful for full-screen recording
    /// where a frame around the whole display would just be a red edge, and the menu bar
    /// might be hidden by a game.
    func showHubOnly(
        cgRect: CGRect,
        color: NSColor,
        onStop: @escaping () -> Void,
        onPauseResume: (() -> Void)? = nil,
        onTogglePreview: (() -> Void)? = nil
    ) {
        hide()
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let target = Geometry.cgToAppKit(cgRect, primaryScreenHeight: primaryHeight)
        // A display target draws no frame at all, so there is nothing for a grace timer to
        // reveal — starting one would just be a Task that expires into a no-op.
        frame.isDisplayTarget = true
        frame.mode = .recording
        hub = makeHub(
            mode: .recording,
            target: target,
            onStop: onStop,
            onPauseResume: onPauseResume,
            onTogglePreview: onTogglePreview,
            onCancel: nil
        )
    }

    /// Window-recording surface that never loses its stop affordance. The optional
    /// border follows target movement and occlusion; the hub docks inside the window,
    /// follows it, and stays visible and clickable.
    func showRecordingWindow(
        _ windowID: CGWindowID,
        initialCGRect: CGRect,
        showsBorder: Bool,
        mode: RecordingHubMode = .recording,
        color: NSColor = Theme.Palette.record.ns,
        onCancel: (() -> Void)? = nil,
        onPauseResume: (() -> Void)? = nil,
        onTogglePreview: (() -> Void)? = nil,
        onStop: @escaping () -> Void
    ) {
        // A hub handed over at Start stays on screen and simply takes the recording's controls.
        let kept = handingOff ? hub : nil
        if kept != nil { hub = nil }
        hide()
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let cgBounds = Self.windowBounds(windowID) ?? initialCGRect
        let target = Geometry.cgToAppKit(cgBounds, primaryScreenHeight: primaryHeight)

        if showsBorder {
            borderPanel = makeBorderPanel(target: target, color: color)
        }
        if mode.isArmed {
            frame.mode = .armed
        } else {
            beginRecordingFrame()
        }
        if let kept {
            kept.onStop = onStop
            kept.onPauseResume = onPauseResume
            kept.onTogglePreview = onTogglePreview
            kept.onCancel = onCancel
            kept.morph(to: mode)
            kept.updateWindow(target, on: relevantScreen(for: target))
            hub = kept
        } else {
            hub = makeHub(
                mode: mode,
                target: target,
                insideWindow: true,
                onStop: onStop,
                onPauseResume: onPauseResume,
                onTogglePreview: onTogglePreview,
                onCancel: onCancel
            )
        }
        applyFrameVisibility(animated: true)
        followWindowID = windowID
        lastFollowedBounds = cgBounds
        startFollowing()
    }

    /// 1 Hz elapsed text for the hub (nil while idle). An armed hub keeps its own mode.
    func updateHub(elapsed: String?, paused: Bool = false) {
        hub?.setElapsed(elapsed)
        hub?.setRecordingMode(paused: paused)
    }

    /// The hub's mic dot, in dBFS as measured on the recorded microphone track.
    func updateHubMicLevel(_ dbfs: Double?) {
        hub?.setMicLevel(dbfs)
    }

    /// Convenience for a window target: looks up the window's current bounds. When `follow`
    /// is true the indicator tracks the window live as it moves/resizes.
    func showWindow(_ windowID: CGWindowID, color: NSColor, follow: Bool = false, onStop: (() -> Void)?) {
        guard let bounds = Self.windowBounds(windowID) else { return }
        show(cgRect: bounds, color: color, onStop: onStop)
        if follow {
            followWindowID = windowID
            lastFollowedBounds = bounds
            startFollowing()
        }
    }

    /// The hub's camera control: whether the camera is in the recording, and whether it can
    /// change now. Every hub shown takes the latest state.
    var onToggleCamera: (() -> Void)?
    private var cameraState: (on: Bool, available: Bool) = (false, true)
    func updateHubCamera(on: Bool, available: Bool) {
        cameraState = (on, available)
        hub?.setCamera(on: on, available: available)
    }

    /// Start: the armed hub stays and turns into the recording one while the stream starts;
    /// its controls answer nothing until the recording is live.
    private var handingOff = false
    func beginHandoff(elapsed: String) {
        guard let hub else { return }
        handingOff = true
        hub.onStop = nil; hub.onCancel = nil; hub.onPauseResume = nil
        hub.morph(to: .recording)
        hub.setElapsed(elapsed)
    }
    /// The start failed or recorded something else: the handed-over hub leaves.
    func endHandoff() {
        guard handingOff else { return }
        hide()
    }

    func hide() {
        handingOff = false
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
        followWindowID = nil
        lastFollowedBounds = nil
        predictor.reset()
        followTick = 0
        occluded = false
        startGraceTask?.cancel()
        startGraceTask = nil
        frame = RecordingFrameVisibility()
        borderView = nil
        borderPanel?.orderOut(nil)
        borderPanel = nil
        hub?.hide()
        hub = nil
    }

    // MARK: - Recording frame visibility

    /// The frame is worth a look at the start — it is the only thing that says WHICH window
    /// is being recorded — then it gets out of the way until the hub is hovered.
    private func beginRecordingFrame() {
        frame.mode = .recording
        frame.withinStartGrace = true
        startGraceTask?.cancel()
        startGraceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(RecordingFrameVisibility.startGrace * 1000)))
            guard !Task.isCancelled, let self else { return }
            self.frame.withinStartGrace = false
            self.applyFrameVisibility(animated: true)
        }
    }

    private func applyFrameVisibility(animated: Bool = true) {
        borderView?.setAlpha(occluded ? 0 : frame.alpha, animated: animated)
    }

    // MARK: - Live window follow (CADisplayLink, display-synced)

    private func startFollowing() {
        guard let sourceView: NSView = (borderView as NSView?) ?? hub?.hostView, let window = sourceView.window else { return }
        let fps = max(60, window.screen?.maximumFramesPerSecond ?? 60)
        // Occlusion changes only on a human timescale (bringing another window forward), so
        // check it a few times a second — a full window-list query every frame would hitch
        // the drag. Position still tracks EVERY frame.
        occlusionCheckInterval = max(24, fps * 2 / 5)
        followTick = 0
        predictor.reset()
        // A CADisplayLink fires on the main run loop right at the top of each display frame,
        // so reading the window's position and moving our panel happen in the same beat — no
        // fixed-interval poll wait to trail behind.
        let proxy = DisplayLinkProxy(target: self)
        displayLinkProxy = proxy
        let link = sourceView.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.followStep(_:)))
        // Ask for the display's full refresh (120 Hz on ProMotion), not a throttled default.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: Float(fps), preferred: Float(fps))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc fileprivate func followStep(_ link: CADisplayLink) {
        guard let id = followWindowID else { return }
        followTick &+= 1
        if let bounds = Self.windowBounds(id) {
            let predicted = leadingBounds(for: bounds)
            if predicted != lastFollowedBounds {
                lastFollowedBounds = predicted
                reposition(to: predicted)
                onTrackedBoundsChange?(bounds)
                // After the tile has moved with the window, so the hub's collision check
                // sees where the tile is now.
                moveHub(to: predicted)
            }
        }
        if followTick % occlusionCheckInterval == 0 {
            Task.detached(priority: .userInitiated) {
                let nowOccluded = !Self.isWindowVisible(id)
                await MainActor.run { [weak self] in
                    guard let self = self, self.followWindowID == id else { return }
                    if nowOccluded != self.occluded {
                        self.occluded = nowOccluded
                        self.applyFrameVisibility(animated: true)
                    }
                }
            }
        }
    }

    /// Leads the border ahead of the window using its smoothed velocity (see FollowPredictor),
    /// cancelling the one-frame reactive lag of a follower overlay so it doesn't trail on a
    /// fast drag.
    private func leadingBounds(for current: CGRect) -> CGRect {
        CGRect(origin: predictor.predict(origin: current.origin), size: current.size)
    }

    /// True when the recorded window is currently on-screen AND the topmost normal window at
    /// its own center — i.e. not covered there by another app. A conservative "can't tell"
    /// (no window list) counts as visible so the indicator never blinks off wrongly.
    nonisolated private static func isWindowVisible(_ windowID: CGWindowID) -> Bool {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return true
        }
        var targetBounds: CGRect?
        var targetLayer: Int = 0
        for info in infoList {
            guard let number = info[kCGWindowNumber as String] as? Int, CGWindowID(number) == windowID,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            targetBounds = bounds
            targetLayer = info[kCGWindowLayer as String] as? Int ?? 0
            break
        }
        guard let targetBounds else { return false }
        let center = CGPoint(x: targetBounds.midX, y: targetBounds.midY)
        for info in infoList {
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.05 else { continue }
            // Same-layer windows only: `>=` would let transient elevated chrome (a
            // notification banner, Control Center) covering the center count as occlusion.
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == targetLayer,
                let number = info[kCGWindowNumber as String] as? Int,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                bounds.contains(center)
            else { continue }
            return CGWindowID(number) == windowID
        }
        return true
    }

    private func reposition(to cgBounds: CGRect) {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let target = Geometry.cgToAppKit(cgBounds, primaryScreenHeight: primaryHeight)
        let pad = Self.borderPad
        let frame = target.insetBy(dx: -pad, dy: -pad)

        guard let borderPanel, let borderView else { return }
        // A pure MOVE (unchanged size) is a bare origin set — no redraw, so the border
        // stays glued to the window. Only a RESIZE rebuilds the layer path.
        if abs(borderPanel.frame.width - frame.width) < 0.5, abs(borderPanel.frame.height - frame.height) < 0.5 {
            if borderPanel.frame.origin != frame.origin { borderPanel.setFrameOrigin(frame.origin) }
        } else {
            borderPanel.setFrame(frame, display: false)
            borderView.frame = CGRect(origin: .zero, size: frame.size)
            borderView.setTarget(
                CGRect(x: pad, y: pad, width: target.width, height: target.height),
                windowCornerRadius: Self.windowCornerRadius(forSize: target.size)
            )
        }
    }

    /// The hub follows the same led bounds as the border, so the two stay glued together.
    private func moveHub(to cgBounds: CGRect) {
        guard let hub, let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let target = Geometry.cgToAppKit(cgBounds, primaryScreenHeight: primaryHeight)
        hub.updateWindow(target, on: relevantScreen(for: target))
    }

    // MARK: - Panels

    /// `lit` draws the scroll capture's frame: a bright line that lights up the area it takes.
    private func makeBorderPanel(target: CGRect, color: NSColor, lit: Bool = false) -> NSPanel {
        let pad = Self.borderPad
        let frame = target.insetBy(dx: -pad, dy: -pad)
        let panel = borderlessPanel(frame: frame)
        panel.ignoresMouseEvents = true   // the window underneath must stay usable
        let view: any CaptureFrameView
        if lit {
            let glow = LitFrameView(frame: CGRect(origin: .zero, size: frame.size))
            // An edge that meets the screen's is drawn just inside it, or it would not show.
            glow.limit = relevantScreen(for: target).map { $0.frame.offsetBy(dx: -frame.minX, dy: -frame.minY) }
            view = glow
        } else {
            let hairline = AreaBorderView(frame: CGRect(origin: .zero, size: frame.size))
            hairline.accentColor = color
            view = hairline
        }
        view.setTarget(
            CGRect(x: pad, y: pad, width: target.width, height: target.height),
            windowCornerRadius: Self.windowCornerRadius(forSize: target.size)
        )
        panel.contentView = view
        borderView = view
        panelPresenter(panel)
        view.animateAppear()
        return panel
    }

    private func makeHub(
        mode: RecordingHubMode,
        target: CGRect,
        insideWindow: Bool = false,
        onStop: @escaping () -> Void,
        onPauseResume: (() -> Void)?,
        onTogglePreview: (() -> Void)?,
        onCancel: (() -> Void)?
    ) -> RecordingHubPanel {
        let hub = RecordingHubPanel(defaults: defaults, panelPresenter: panelPresenter)
        hub.onStop = onStop
        hub.onPauseResume = onPauseResume
        hub.onTogglePreview = onTogglePreview
        hub.onToggleCamera = { [weak self] in self?.onToggleCamera?() }
        hub.setCamera(on: cameraState.on, available: cameraState.available)
        hub.onCancel = onCancel
        hub.onHoverChange = { [weak self] hovering in
            guard let self else { return }
            self.frame.hoveringHub = hovering
            self.applyFrameVisibility(animated: true)
        }
        hub.show(mode: mode, on: relevantScreen(for: target), window: insideWindow ? target : nil)
        return hub
    }

    private func relevantScreen(for target: CGRect) -> NSScreen? {
        let intersecting = NSScreen.screens.filter { !$0.frame.intersection(target).isNull }
        if let best = intersecting.max(by: {
            let lhs = $0.frame.intersection(target)
            let rhs = $1.frame.intersection(target)
            return lhs.width * lhs.height < rhs.width * rhs.height
        }) {
            return best
        }
        // If the followed window is now wholly offscreen, keep the hub on the display
        // where it was last reachable.
        return hub?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func borderlessPanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        return panel
    }

    static func windowBounds(_ windowID: CGWindowID) -> CGRect? {
        guard
            let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
            let info = infoList.first,
            let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else {
            return nil
        }
        return bounds
    }

    // Narrow offscreen-test seams for native panel geometry, frame policy and occlusion.
    var borderPanelForTesting: NSPanel? { borderPanel }
    var hubPanelForTesting: NSPanel? { hub?.panelForTesting }
    var hubForTesting: RecordingHubPanel? { hub }
    var frameVisibilityForTesting: RecordingFrameVisibility { frame }
    var frameAlphaForTesting: Float? { borderPanel?.contentView?.layer?.opacity }

    func setOccludedForTesting(_ value: Bool) {
        occluded = value
        applyFrameVisibility(animated: false)
    }

    func setHubHoveredForTesting(_ hovering: Bool) {
        frame.hoveringHub = hovering
        applyFrameVisibility(animated: false)
    }

    func endStartGraceForTesting() {
        startGraceTask?.cancel()
        startGraceTask = nil
        frame.withinStartGrace = false
        applyFrameVisibility(animated: false)
    }
}

/// What the indicator draws around the captured area.
@MainActor protocol CaptureFrameView: NSView {
    func setTarget(_ windowRectInView: CGRect, windowCornerRadius: CGFloat)
    func animateAppear()
    func setAlpha(_ alpha: CGFloat, animated: Bool)
}

/// The scroll capture's frame: the glass light around the area it takes, lit when it appears.
/// The panel is left out of the capture, so none of it reaches the image.
private final class LitFrameView: NSView, CaptureFrameView {
    private let ring = LitRing()
    /// The screen in view coordinates: the frame stays inside it.
    var limit: CGRect?

    static let gap: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(ring.layer)
        layer?.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    func setTarget(_ windowRectInView: CGRect, windowCornerRadius: CGFloat) {
        var line = windowRectInView.insetBy(dx: -Self.gap, dy: -Self.gap)
        if let limit {
            // An edge that meets the screen's is drawn just inside it.
            let clamped = line.intersection(limit.insetBy(dx: LitRing.lineWidth, dy: LitRing.lineWidth))
            if !clamped.isNull { line = clamped }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.layer.frame = bounds
        CATransaction.commit()
        // A display-wide area has no window corner to follow; it takes the app's soft one.
        ring.set(ring: line, radius: windowCornerRadius > 0 ? windowCornerRadius + Self.gap : Theme.Radius.well)
    }

    func animateAppear() { ring.light() }

    func setAlpha(_ alpha: CGFloat, animated: Bool) {
        guard let layer else { return }
        let target = Float(min(max(alpha, 0), 1))
        guard layer.opacity != target else { return }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
            fade.toValue = target
            fade.duration = 0.12
            layer.add(fade, forKey: "frameAlpha")
        }
        layer.opacity = target
    }
}

/// A clean gradient hairline that hugs the window's own rounded corners — NO glow/shadow
/// (which bloomed inward over the window and was expensive to composite while dragging).
/// A `CAGradientLayer` masked by a plain `CALayer` border: the mask keeps `cornerCurve =
/// .continuous` (the squircle curve macOS uses for window corners), so the 1 pt line traces
/// the same corner shape offset outward while the colour falls off along the top-left →
/// bottom-right diagonal. Because it is a moved layer with no shadow, following a dragged
/// window is a cheap reposition with no repaint. Lives in a click-through panel.
private final class AreaBorderView: NSView, CaptureFrameView {
    private let gradientLayer = CAGradientLayer()
    private let strokeMask = CALayer()
    private var color: NSColor = Theme.Palette.record.ns

    /// Uniform margin between the window edge and the border. Expanding a rounded rect by this
    /// keeps the corner concentric: border radius = window radius + gap.
    static let gap: CGFloat = 2
    /// A hairline: the frame marks the recording, it does not fence it in.
    static let lineWidth: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        strokeMask.backgroundColor = NSColor.clear.cgColor
        strokeMask.cornerCurve = .continuous
        strokeMask.borderWidth = Self.lineWidth
        strokeMask.borderColor = NSColor.black.cgColor
        gradientLayer.startPoint = CGPoint(x: 0, y: 1)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0)
        gradientLayer.mask = strokeMask
        layer?.addSublayer(gradientLayer)
        layer?.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    var accentColor: NSColor {
        get { color }
        set {
            color = newValue
            gradientLayer.colors = [
                newValue.withAlphaComponent(0.85).cgColor,
                newValue.withAlphaComponent(0.25).cgColor
            ]
        }
    }

    /// Positions the border around `windowRectInView` (the window's bounding box in view
    /// coords), expanded by `gap`, with a continuous corner of `windowCornerRadius + gap` so it
    /// sits exactly around the window's own corner. Called on show and on resize; implicit
    /// animations disabled so a resize snaps rather than lerps.
    func setTarget(_ windowRectInView: CGRect, windowCornerRadius: CGFloat) {
        let frame = windowRectInView.insetBy(dx: -Self.gap, dy: -Self.gap)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = frame
        strokeMask.frame = CGRect(origin: .zero, size: frame.size)
        strokeMask.cornerRadius = windowCornerRadius + Self.gap
        CATransaction.commit()
    }

    /// A gentle settle onto the window when it appears: the border grows the last couple
    /// percent into place (grows UP so it never overflows the panel and clips). The opacity
    /// belongs to the visibility rule, not to the entrance.
    func animateAppear() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.97
        scale.toValue = 1
        scale.mass = 1
        scale.stiffness = 210
        scale.damping = 19
        scale.duration = scale.settlingDuration
        gradientLayer.add(scale, forKey: "appearScale")
    }

    /// The one place the frame's opacity is set: the visibility rule, occlusion included.
    func setAlpha(_ alpha: CGFloat, animated: Bool) {
        guard let layer else { return }
        let target = Float(min(max(alpha, 0), 1))
        guard layer.opacity != target else { return }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
            fade.toValue = target
            fade.duration = 0.18
            layer.add(fade, forKey: "frameAlpha")
        }
        layer.opacity = target
    }
}

/// Pure velocity-lead predictor for the window-follow border. A follower overlay window is
/// composited the frame AFTER it reads the target's position, so on a fast drag it trails by a
/// frame. Feeding each frame's window origin here returns a position led ~`leadFrames` frames
/// ahead (current + smoothed per-frame velocity), which cancels that lag for steady motion; at
/// a standstill the velocity decays to ~0, so there's no overshoot. The lead is clamped so a
/// stale or jumpy read can't fling the border far. Pure and clock-free → unit-testable.
struct FollowPredictor {
    private var velX: CGFloat = 0
    private var velY: CGFloat = 0
    private var last: CGPoint?

    let leadFrames: CGFloat
    let maxLead: CGFloat
    /// Weight of the newest sample in the velocity EMA (0…1); higher = snappier, noisier.
    let smoothing: CGFloat

    init(leadFrames: CGFloat = 1.35, maxLead: CGFloat = 300, smoothing: CGFloat = 0.65) {
        self.leadFrames = leadFrames
        self.maxLead = maxLead
        self.smoothing = smoothing
    }

    mutating func reset() {
        velX = 0
        velY = 0
        last = nil
    }

    mutating func predict(origin: CGPoint) -> CGPoint {
        defer { last = origin }
        guard let prev = last else { return origin }
        velX = velX * (1 - smoothing) + (origin.x - prev.x) * smoothing
        velY = velY * (1 - smoothing) + (origin.y - prev.y) * smoothing
        let lx = max(-maxLead, min(maxLead, velX * leadFrames))
        let ly = max(-maxLead, min(maxLead, velY * leadFrames))
        return CGPoint(x: origin.x + lx, y: origin.y + ly)
    }
}

private class DisplayLinkProxy: NSObject {
    weak var target: CaptureAreaIndicator?
    init(target: CaptureAreaIndicator) { self.target = target }
    @MainActor
    @objc func followStep(_ link: CADisplayLink) {
        target?.followStep(link)
    }
}
