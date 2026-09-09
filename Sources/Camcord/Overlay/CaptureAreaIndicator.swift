import AppKit
import CoreGraphics
import QuartzCore

enum StopPillGlyph {
    case stop
    case play
}

/// A minimal, glowing border around a captured area (a recorded window, or a scrolling-
/// capture region). It lives in its OWN borderless panels — different windows than the one
/// being captured — and the stroke sits OUTSIDE the target rect, so it never appears in the
/// capture. Red for recording, blue for scrolling capture.
///
/// The border is drawn with **CALayers** (a crisp line + a glow shadow), not `draw()`, so it
/// is GPU-composited: moving the panel to follow a dragged window is a pure `setFrameOrigin`
/// with ZERO redraw, and the follow is driven by a **CADisplayLink** locked to the display's
/// refresh — the tightest tracking a separate overlay window can do natively (a true cross-
/// process child window, which would be zero-lag, isn't available on macOS). Only a resize
/// rebuilds the layer path.
///
/// The border panel is ALWAYS click-through so the window underneath stays usable. When a
/// stop action is provided, a SEPARATE small pill panel (interactive) floats near the top.
@MainActor
final class CaptureAreaIndicator {
    typealias PanelPresenter = @MainActor (NSPanel) -> Void

    var onTrackedBoundsChange: ((CGRect) -> Void)?

    private let panelPresenter: PanelPresenter
    private var borderPanel: NSPanel?
    private var stopPanel: NSPanel?
    private weak var stopPillView: StopPillView?
    private var borderView: AreaBorderView?

    /// Live window-follow state (window recording): a CADisplayLink repositions the border +
    /// stop pill as the recorded window moves/resizes, and fades them while the window is
    /// occluded so the border never floats over the app that covered it.
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
    /// Window recordings must retain an independent stop affordance even when the
    /// optional border follows the target's visibility.
    private var keepsStopPillVisibleWhenOccluded = false

    private static let borderPad: CGFloat = 12

    /// The corner radius the border matches: macOS windows use a continuous ~10pt corner
    /// (Big Sur and later). Tunable in one place if a macOS release changes it.
    private static let macOSWindowCornerRadius: CGFloat = 10

    init(panelPresenter: PanelPresenter? = nil) {
        self.panelPresenter = panelPresenter ?? { $0.orderFrontRegardless() }
    }

    /// The window's own corner radius to trace: the standard rounded corner for a normal
    /// window, or 0 for a window that fills a whole display (full-screen / borderless — e.g.
    /// a game — which has sharp corners).
    private static func windowCornerRadius(forSize size: CGSize) -> CGFloat {
        let coversWholeScreen = NSScreen.screens.contains {
            abs(size.width - $0.frame.width) < 2 && abs(size.height - $0.frame.height) < 2
        }
        return coversWholeScreen ? 0 : macOSWindowCornerRadius
    }

    func show(cgRect: CGRect, color: NSColor, label: String?, onStop: (() -> Void)?) {
        hide()
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let target = Geometry.cgToAppKit(cgRect, primaryScreenHeight: primaryHeight)

        borderPanel = makeBorderPanel(target: target, color: color)
        if let onStop {
            stopPanel = makeStopPanel(
                target: target,
                title: label ?? "Kaydı Durdur",
                glyph: .stop,
                color: color,
                onCancel: nil,
                onStop: onStop
            )
        }
    }

    /// Shows ONLY the floating interactive stop pill (no glowing border). Useful for full-screen
    /// recording where a border isn't needed but the menu bar might be hidden by a game.
    func showStopPillOnly(cgRect: CGRect, color: NSColor, onStop: @escaping () -> Void) {
        hide()
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let target = Geometry.cgToAppKit(cgRect, primaryScreenHeight: primaryHeight)
        // Anchor to the display's VISIBLE frame so the pill sits just below the menu
        // bar on a desktop (not over it); in fullscreen the bar is hidden and the
        // visible frame reaches the top edge — the pill lands where the bar was.
        let screen = NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.main
        stopPanel = makeStopPanel(
            target: screen?.visibleFrame ?? target,
            title: "Kaydı Durdur",
            glyph: .stop,
            color: color,
            onCancel: nil,
            onStop: onStop
        )
    }

    /// Window-recording surface that never loses its stop affordance. The optional
    /// border follows target movement and occlusion, while the elapsed/stop pill stays
    /// visible and clickable inside the relevant display's visible frame.
    func showRecordingWindow(
        _ windowID: CGWindowID,
        initialCGRect: CGRect,
        showsBorder: Bool,
        title: String = "Kaydı Durdur",
        glyph: StopPillGlyph = .stop,
        color: NSColor = .systemRed,
        onCancel: (() -> Void)? = nil,
        onStop: @escaping () -> Void
    ) {
        hide()
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let cgBounds = Self.windowBounds(windowID) ?? initialCGRect
        let target = Geometry.cgToAppKit(cgBounds, primaryScreenHeight: primaryHeight)

        keepsStopPillVisibleWhenOccluded = true
        if showsBorder {
            borderPanel = makeBorderPanel(target: target, color: color)
        }
        stopPanel = makeStopPanel(
            target: target,
            title: title,
            glyph: glyph,
            color: color,
            onCancel: onCancel,
            onStop: onStop
        )
        followWindowID = windowID
        lastFollowedBounds = cgBounds
        startFollowing()
    }

    /// 1 Hz elapsed text for the stop pill (nil hides the time, showing the label).
    func updateStopPillElapsed(_ text: String?) {
        stopPillView?.setElapsed(text)
    }

    /// Convenience for a window target: looks up the window's current bounds. When `follow`
    /// is true the indicator tracks the window live as it moves/resizes.
    func showWindow(_ windowID: CGWindowID, color: NSColor, label: String?, follow: Bool = false, onStop: (() -> Void)?) {
        guard let bounds = Self.windowBounds(windowID) else { return }
        show(cgRect: bounds, color: color, label: label, onStop: onStop)
        if follow {
            followWindowID = windowID
            lastFollowedBounds = bounds
            startFollowing()
        }
    }

    func hide() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
        followWindowID = nil
        lastFollowedBounds = nil
        predictor.reset()
        followTick = 0
        occluded = false
        keepsStopPillVisibleWhenOccluded = false
        borderView = nil
        borderPanel?.orderOut(nil)
        borderPanel = nil
        stopPanel?.orderOut(nil)
        stopPanel = nil
        stopPillView = nil
    }

    // MARK: - Live window follow (CADisplayLink, display-synced)

    private func startFollowing() {
        let sourceView: NSView?
        if let borderView {
            sourceView = borderView
        } else {
            sourceView = stopPillView
        }
        guard let sourceView, let window = sourceView.window else { return }
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
            }
        }
        if followTick % occlusionCheckInterval == 0 {
            Task.detached(priority: .userInitiated) {
                let nowOccluded = !Self.isWindowVisible(id)
                await MainActor.run { [weak self] in
                    guard let self = self, self.followWindowID == id else { return }
                    if nowOccluded != self.occluded {
                        self.occluded = nowOccluded
                        self.applyOcclusion()
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

    /// Fades the border + stop pill out while the recorded window is covered/off-screen, and
    /// back in when it's visible again — so the indicator behaves like it's attached to the
    /// window rather than always floating on top.
    private func applyOcclusion() {
        borderView?.setContentHidden(occluded)
        if let stopPanel {
            if keepsStopPillVisibleWhenOccluded {
                stopPanel.ignoresMouseEvents = false
                stopPanel.contentView?.layer?.removeAnimation(forKey: "occlusion")
                stopPanel.contentView?.layer?.opacity = 1
                return
            }
            stopPanel.ignoresMouseEvents = occluded
            let contentLayer = stopPanel.contentView?.layer
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = contentLayer?.presentation()?.opacity ?? contentLayer?.opacity ?? 1
            fade.toValue = occluded ? 0 : 1
            fade.duration = 0.18
            contentLayer?.add(fade, forKey: "occlusion")
            contentLayer?.opacity = occluded ? 0 : 1
        }
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

        if let borderPanel, let borderView {
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

        if let stopPanel {
            let size = stopPanel.frame.size
            // Clamp inside the VISIBLE frame so a window parked at the top of the
            // screen can't push the pill onto the live menu bar (it eats clicks).
            let screenFrame = relevantScreen(for: target)?.visibleFrame ?? target
            let origin = Self.stopPillOrigin(target: target, size: size, bounds: screenFrame)
            if stopPanel.frame.origin != origin { stopPanel.setFrameOrigin(origin) }
        }
    }

    // MARK: - Panels

    private func makeBorderPanel(target: CGRect, color: NSColor) -> NSPanel {
        let pad = Self.borderPad
        let frame = target.insetBy(dx: -pad, dy: -pad)
        let panel = borderlessPanel(frame: frame)
        panel.ignoresMouseEvents = true   // the window underneath must stay usable
        let view = AreaBorderView(frame: CGRect(origin: .zero, size: frame.size))
        view.accentColor = color
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

    private func makeStopPanel(
        target: CGRect,
        title: String,
        glyph: StopPillGlyph,
        color: NSColor,
        onCancel: (() -> Void)?,
        onStop: @escaping () -> Void
    ) -> NSPanel {
        let size = CGSize(width: onCancel == nil ? 148 : 178, height: 30)
        // Bounds = the VISIBLE frame: the pill must never rest on the live menu bar,
        // where its interactive panel would eat clicks meant for status items.
        let bounds = relevantScreen(for: target)?.visibleFrame ?? target
        let origin = Self.stopPillOrigin(target: target, size: size, bounds: bounds)

        let panel = borderlessPanel(frame: CGRect(origin: origin, size: size))
        panel.ignoresMouseEvents = false
        let pill = StopPillView(
            frame: CGRect(origin: .zero, size: size),
            title: title,
            glyph: glyph,
            color: color,
            onCancel: onCancel
        )
        pill.onClick = onStop
        panel.contentView = pill
        stopPillView = pill
        panelPresenter(panel)
        pill.animateAppear()
        return panel
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
        // If the followed window is now wholly offscreen, keep the stop control on
        // the display where it was last reachable.
        return stopPanel?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func stopPillOrigin(target: CGRect, size: CGSize, bounds: CGRect) -> CGPoint {
        var origin = CGPoint(x: target.midX - size.width / 2, y: target.maxY + 8)
        if origin.y + size.height > bounds.maxY - 4 {
            origin.y = min(target.maxY, bounds.maxY) - size.height - 8
        }

        let minX = bounds.minX + 4
        let maxX = bounds.maxX - size.width - 4
        origin.x = maxX < minX ? minX : min(max(origin.x, minX), maxX)

        let minY = bounds.minY + 4
        let maxY = bounds.maxY - size.height - 4
        origin.y = maxY < minY ? minY : min(max(origin.y, minY), maxY)
        return origin
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

    // Narrow offscreen-test seams for native panel geometry and occlusion policy.
    var borderPanelForTesting: NSPanel? { borderPanel }
    var stopPanelForTesting: NSPanel? { stopPanel }

    func setOccludedForTesting(_ value: Bool) {
        occluded = value
        applyOcclusion()
    }

    func activateStopPillForTesting(at point: CGPoint) {
        stopPillView?.performClick(at: point)
    }

    func applyStopPillIdleFadeForTesting() {
        stopPillView?.applyIdleFade()
    }
}

/// A clean, thin border that hugs the window's own rounded corners — NO glow/shadow (which
/// bloomed inward over the window and was expensive to composite while dragging). It's a plain
/// CALayer with `cornerCurve = .continuous` (the squircle curve macOS uses for window corners)
/// sized to the window box expanded by a small uniform gap, so it traces the same corner shape
/// offset outward. Because it's a moved layer with no shadow, following a dragged window is a
/// cheap reposition with no repaint. Lives in a click-through panel.
private final class AreaBorderView: NSView {
    private let lineLayer = CALayer()
    private var color: NSColor = .systemRed

    /// Uniform margin between the window edge and the border. Expanding a rounded rect by this
    /// keeps the corner concentric: border radius = window radius + gap.
    static let gap: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        lineLayer.backgroundColor = NSColor.clear.cgColor
        lineLayer.cornerCurve = .continuous
        lineLayer.borderWidth = 2
        layer?.addSublayer(lineLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    var accentColor: NSColor {
        get { color }
        set {
            color = newValue
            lineLayer.borderColor = newValue.cgColor
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
        lineLayer.frame = frame
        lineLayer.cornerRadius = windowCornerRadius + Self.gap
        CATransaction.commit()
    }

    /// A gentle settle onto the window when it appears: fade in while the border grows the last
    /// couple percent into place (grows UP so it never overflows the panel and clips).
    func animateAppear() {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        layer.opacity = 1
        layer.add(fade, forKey: "appearFade")
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.97
        scale.toValue = 1
        scale.mass = 1
        scale.stiffness = 210
        scale.damping = 19
        scale.duration = scale.settlingDuration
        lineLayer.add(scale, forKey: "appearScale")
    }

    /// Fades the border out (occluded) or back in (visible).
    func setContentHidden(_ hidden: Bool) {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = hidden ? 0 : 1
        fade.duration = 0.18
        layer.opacity = hidden ? 0 : 1
        layer.add(fade, forKey: "occlusion")
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

/// A small interactive "stop" pill: stop square + live elapsed time (hover swaps to the
/// action label). Click stops; drag repositions (game HUDs live everywhere — no fixed
/// spot suits every game). Fades to 60% after a few idle seconds so it never demands
/// attention; full opacity returns on hover.
private final class StopPillView: NSView {
    var onClick: (() -> Void)?
    private let title: String
    private let glyph: StopPillGlyph
    private let color: NSColor
    private let onCancel: (() -> Void)?
    private let label: NSTextField
    private var elapsedText: String?
    private var hovered = false
    private var fadeWorkItem: DispatchWorkItem?
    // Click-vs-drag: remember where the press started and move the panel with the drag.
    private var downMouse: NSPoint?
    private var downOrigin: NSPoint?
    private var draggedBeyondSlop = false
    private var downInCancel = false

    init(
        frame: NSRect,
        title: String,
        glyph: StopPillGlyph,
        color: NSColor,
        onCancel: (() -> Void)?
    ) {
        self.title = title
        self.glyph = glyph
        self.color = color
        self.onCancel = onCancel
        self.label = NSTextField(labelWithString: title)
        super.init(frame: frame)
        wantsLayer = true
        // Half the pill's 30 pt height: a capsule, not a surface corner — keep it off the
        // app's radius token.
        layer?.cornerRadius = 15
        layer?.backgroundColor = color.cgColor
        label.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    func setElapsed(_ text: String?) {
        elapsedText = text
        refreshLabel()
    }

    /// Same fade + spring-scale entrance as the border indicator — the pill shouldn't
    /// be the one element that just snaps in.
    func animateAppear() {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.16
        layer.add(fade, forKey: "appearFade")
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.9
        scale.toValue = 1
        scale.mass = 1
        scale.stiffness = 210
        scale.damping = 19
        scale.duration = scale.settlingDuration
        layer.add(scale, forKey: "appearScale")
    }

    private func refreshLabel() {
        if hovered || elapsedText == nil {
            label.stringValue = title
            label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        } else {
            label.stringValue = elapsedText ?? ""
            label.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.alphaValue = 1
            scheduleIdleFade()
        }
    }

    private func scheduleIdleFade() {
        fadeWorkItem?.cancel()
        guard onCancel == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.applyIdleFade(animated: true)
        }
        fadeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    override func layout() {
        super.layout()
        let trailingInset: CGFloat = onCancel == nil ? 6 : 36
        label.frame = CGRect(
            x: 30,
            y: (bounds.height - 16) / 2,
            width: bounds.width - 30 - trailingInset,
            height: 16
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.white.setFill()
        switch glyph {
        case .stop:
            let square = CGRect(x: 12, y: bounds.midY - 5, width: 10, height: 10)
            NSBezierPath(roundedRect: square, xRadius: 2, yRadius: 2).fill()
        case .play:
            let triangle = NSBezierPath()
            triangle.move(to: CGPoint(x: 12, y: bounds.midY - 6))
            triangle.line(to: CGPoint(x: 23, y: bounds.midY))
            triangle.line(to: CGPoint(x: 12, y: bounds.midY + 6))
            triangle.close()
            triangle.fill()
        }

        if onCancel != nil {
            NSColor.white.withAlphaComponent(0.28).setStroke()
            let divider = NSBezierPath()
            divider.move(to: CGPoint(x: cancelHitRect.minX, y: 6))
            divider.line(to: CGPoint(x: cancelHitRect.minX, y: bounds.height - 6))
            divider.lineWidth = 1
            divider.stroke()

            NSColor.white.setStroke()
            let cross = NSBezierPath()
            let center = CGPoint(x: cancelHitRect.midX, y: cancelHitRect.midY)
            cross.move(to: CGPoint(x: center.x - 4, y: center.y - 4))
            cross.line(to: CGPoint(x: center.x + 4, y: center.y + 4))
            cross.move(to: CGPoint(x: center.x - 4, y: center.y + 4))
            cross.line(to: CGPoint(x: center.x + 4, y: center.y - 4))
            cross.lineWidth = 1.5
            cross.stroke()
        }
    }

    private var cancelHitRect: CGRect {
        guard onCancel != nil else { return .null }
        return CGRect(x: bounds.maxX - 30, y: bounds.minY, width: 30, height: bounds.height)
    }

    fileprivate func applyIdleFade() {
        applyIdleFade(animated: false)
    }

    private func applyIdleFade(animated: Bool) {
        guard onCancel == nil, !hovered else { return }
        if animated {
            window?.animator().alphaValue = 0.6
        } else {
            window?.alphaValue = 0.6
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        refreshLabel()
        fadeWorkItem?.cancel()
        window?.animator().alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        refreshLabel()
        scheduleIdleFade()
    }

    // MARK: Click vs drag

    override func mouseDown(with event: NSEvent) {
        downMouse = NSEvent.mouseLocation
        downOrigin = window?.frame.origin
        draggedBeyondSlop = false
        downInCancel = cancelHitRect.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard !downInCancel else { return }
        guard let downMouse, let downOrigin, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - downMouse.x
        let dy = now.y - downMouse.y
        if abs(dx) > 3 || abs(dy) > 3 { draggedBeyondSlop = true }
        guard draggedBeyondSlop else { return }
        window.setFrameOrigin(NSPoint(x: downOrigin.x + dx, y: downOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if !draggedBeyondSlop {
            let point = convert(event.locationInWindow, from: nil)
            if downInCancel {
                if cancelHitRect.contains(point) { onCancel?() }
            } else {
                performClick(at: point)
            }
        }
        downMouse = nil
        downOrigin = nil
        downInCancel = false
    }

    fileprivate func performClick(at point: CGPoint) {
        if cancelHitRect.contains(point) {
            onCancel?()
        } else {
            onClick?()
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

private class DisplayLinkProxy: NSObject {
    weak var target: CaptureAreaIndicator?
    init(target: CaptureAreaIndicator) { self.target = target }
    @MainActor
    @objc func followStep(_ link: CADisplayLink) {
        target?.followStep(link)
    }
}
