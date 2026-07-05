import AppKit
import CoreGraphics
import QuartzCore

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
    private var borderPanel: NSPanel?
    private var stopPanel: NSPanel?
    private var borderView: AreaBorderView?

    /// Live window-follow state (window recording): a CADisplayLink repositions the border +
    /// stop pill as the recorded window moves/resizes, and fades them while the window is
    /// occluded so the border never floats over the app that covered it.
    private var followWindowID: CGWindowID?
    private var displayLink: CADisplayLink?
    private var lastFollowedBounds: CGRect?
    /// Leads the border ahead of the window by its smoothed velocity to cancel the inherent
    /// one-frame reactive lag of a separate overlay window (pure/tested — see FollowPredictor).
    private var predictor = FollowPredictor()
    private var followTick = 0
    /// Display-link frames between occlusion checks (position tracks EVERY frame; occlusion
    /// only changes when the user reshuffles windows, so ~10 Hz is plenty).
    private var occlusionCheckInterval = 10
    private var occluded = false

    private static let borderPad: CGFloat = 22

    /// The corner radius the border matches: macOS windows use a continuous ~10pt corner
    /// (Big Sur and later). Tunable in one place if a macOS release changes it.
    private static let macOSWindowCornerRadius: CGFloat = 10

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
            stopPanel = makeStopPanel(target: target, color: color, onStop: onStop)
        }
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
        followWindowID = nil
        lastFollowedBounds = nil
        predictor.reset()
        followTick = 0
        occluded = false
        borderView = nil
        borderPanel?.orderOut(nil)
        borderPanel = nil
        stopPanel?.orderOut(nil)
        stopPanel = nil
    }

    // MARK: - Live window follow (CADisplayLink, display-synced)

    private func startFollowing() {
        guard let borderView, let window = borderView.window else { return }
        let fps = max(60, window.screen?.maximumFramesPerSecond ?? 60)
        occlusionCheckInterval = max(4, fps / 10)
        followTick = 0
        predictor.reset()
        // A CADisplayLink fires on the main run loop right at the top of each display frame,
        // so reading the window's position and moving our panel happen in the same beat — no
        // fixed-interval poll wait to trail behind.
        let link = borderView.displayLink(target: self, selector: #selector(followStep(_:)))
        // Ask for the display's full refresh (120 Hz on ProMotion), not a throttled default.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: Float(fps), preferred: Float(fps))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func followStep(_ link: CADisplayLink) {
        guard let id = followWindowID else { return }
        followTick &+= 1
        if let bounds = Self.windowBounds(id) {
            let predicted = leadingBounds(for: bounds)
            if predicted != lastFollowedBounds {
                lastFollowedBounds = predicted
                reposition(to: predicted)
            }
        }
        if followTick % occlusionCheckInterval == 0 {
            let nowOccluded = !Self.isWindowVisible(id)
            if nowOccluded != occluded {
                occluded = nowOccluded
                applyOcclusion()
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
    private static func isWindowVisible(_ windowID: CGWindowID) -> Bool {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return true
        }
        var targetBounds: CGRect?
        for info in infoList {
            guard let number = info[kCGWindowNumber as String] as? Int, CGWindowID(number) == windowID,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            targetBounds = bounds
            break
        }
        guard let targetBounds else { return false }
        let center = CGPoint(x: targetBounds.midX, y: targetBounds.midY)
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
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
                borderPanel.setFrameOrigin(frame.origin)
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
            let screenFrame = (NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.main)?.frame ?? target
            var origin = CGPoint(x: target.midX - size.width / 2, y: target.maxY + 8)
            if origin.y + size.height > screenFrame.maxY - 4 {
                origin.y = target.maxY - size.height - 8
            }
            origin.x = min(max(origin.x, screenFrame.minX + 4), screenFrame.maxX - size.width - 4)
            stopPanel.setFrameOrigin(origin)
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
        panel.orderFrontRegardless()
        view.animateAppear()
        return panel
    }

    private func makeStopPanel(target: CGRect, color: NSColor, onStop: @escaping () -> Void) -> NSPanel {
        let size = CGSize(width: 148, height: 30)
        let bounds = (NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.main)?.frame ?? target
        var origin = CGPoint(x: target.midX - size.width / 2, y: target.maxY + 8)
        if origin.y + size.height > bounds.maxY - 4 {
            origin.y = target.maxY - size.height - 8
        }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 4)

        let panel = borderlessPanel(frame: CGRect(origin: origin, size: size))
        panel.ignoresMouseEvents = false
        let pill = StopPillView(frame: CGRect(origin: .zero, size: size), color: color)
        pill.onClick = onStop
        panel.contentView = pill
        panel.orderFrontRegardless()
        return panel
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

    private static func windowBounds(_ windowID: CGWindowID) -> CGRect? {
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
}

/// A GPU-composited glowing border that hugs the window's own rounded corners: a soft accent
/// bloom under a thin crisp line. Both are plain CALayers with `cornerCurve = .continuous`
/// (the squircle curve macOS uses for window corners) so the border traces the SAME corner
/// shape as the window, offset outward by a small uniform gap. Because it's a moved layer,
/// following a dragged window is a pure reposition with no repaint. Lives in a click-through
/// panel.
private final class AreaBorderView: NSView {
    private let glowLayer = CALayer()
    private let lineLayer = CALayer()
    private var color: NSColor = .systemRed

    /// Uniform margin between the window edge and the border. Expanding a rounded rect by this
    /// keeps the corner concentric: border radius = window radius + gap.
    static let gap: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        for sublayer in [glowLayer, lineLayer] {
            sublayer.backgroundColor = NSColor.clear.cgColor
            sublayer.cornerCurve = .continuous
            sublayer.masksToBounds = false
        }
        // Glow: a wider accent border with a strong accent shadow bloom.
        glowLayer.borderWidth = 3
        glowLayer.shadowRadius = 16
        glowLayer.shadowOpacity = 1
        glowLayer.shadowOffset = .zero
        // Crisp line: a thin bright accent edge on top.
        lineLayer.borderWidth = 1.5

        layer?.addSublayer(glowLayer)
        layer?.addSublayer(lineLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    var accentColor: NSColor {
        get { color }
        set {
            color = newValue
            glowLayer.borderColor = newValue.withAlphaComponent(0.85).cgColor
            glowLayer.shadowColor = newValue.cgColor
            lineLayer.borderColor = newValue.cgColor
        }
    }

    /// Positions the border around `windowRectInView` (the window's bounding box in view
    /// coords), expanded by `gap`, with a continuous corner of `windowCornerRadius + gap` so it
    /// sits exactly around the window's own corner. Called on show and on resize; implicit
    /// animations disabled so a resize snaps rather than lerps.
    func setTarget(_ windowRectInView: CGRect, windowCornerRadius: CGFloat) {
        let frame = windowRectInView.insetBy(dx: -Self.gap, dy: -Self.gap)
        let radius = windowCornerRadius + Self.gap
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [glowLayer, lineLayer] {
            sublayer.frame = frame
            sublayer.cornerRadius = radius
        }
        glowLayer.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: frame.size),
            cornerWidth: radius, cornerHeight: radius, transform: nil
        )
        CATransaction.commit()
    }

    /// A gentle settle onto the window when it first appears: fade in while the border eases
    /// down from a hair larger.
    func animateAppear() {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.24
        layer.opacity = 1
        layer.add(fade, forKey: "appearFade")
        for sublayer in [glowLayer, lineLayer] {
            let scale = CASpringAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.05
            scale.toValue = 1
            scale.mass = 0.9
            scale.stiffness = 240
            scale.damping = 20
            scale.duration = scale.settlingDuration
            sublayer.add(scale, forKey: "appearScale")
        }
    }

    /// Fades the whole border out (occluded) or back in (visible).
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

/// A small clickable "stop" pill (stop square + label) in its own interactive panel.
private final class StopPillView: NSView {
    var onClick: (() -> Void)?
    private let color: NSColor
    private let label = NSTextField(labelWithString: "Kaydı Durdur")

    init(frame: NSRect, color: NSColor) {
        self.color = color
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.backgroundColor = color.cgColor
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        label.frame = CGRect(x: 30, y: (bounds.height - 16) / 2, width: bounds.width - 36, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let square = CGRect(x: 12, y: bounds.midY - 5, width: 10, height: 10)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: square, xRadius: 2, yRadius: 2).fill()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
