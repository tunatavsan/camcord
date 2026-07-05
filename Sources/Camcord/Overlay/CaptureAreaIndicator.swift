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
    private var followTick = 0
    /// Display-link frames between occlusion checks (position tracks EVERY frame; occlusion
    /// only changes when the user reshuffles windows, so ~10 Hz is plenty).
    private var occlusionCheckInterval = 10
    private var occluded = false

    private static let borderPad: CGFloat = 22

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
        // A CADisplayLink fires on the main run loop right at the top of each display frame,
        // so reading the window's position and moving our panel happen in the same beat — no
        // fixed-interval poll wait to trail behind.
        let link = borderView.displayLink(target: self, selector: #selector(followStep(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func followStep(_ link: CADisplayLink) {
        guard let id = followWindowID else { return }
        followTick &+= 1
        if let bounds = Self.windowBounds(id), bounds != lastFollowedBounds {
            lastFollowedBounds = bounds
            reposition(to: bounds)
        }
        if followTick % occlusionCheckInterval == 0 {
            let nowOccluded = !Self.isWindowVisible(id)
            if nowOccluded != occluded {
                occluded = nowOccluded
                applyOcclusion()
            }
        }
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
                borderView.setTarget(CGRect(x: pad, y: pad, width: target.width, height: target.height))
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
        view.setTarget(CGRect(x: pad, y: pad, width: target.width, height: target.height))
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

/// A GPU-composited glowing rounded border: a soft accent bloom under a thin crisp line, both
/// CAShapeLayers so moving the panel never triggers a repaint. A thin line and tight corner
/// hug the window edge; the glow makes it read as "lit". Lives in a click-through panel.
private final class AreaBorderView: NSView {
    private let glowLayer = CAShapeLayer()
    private let lineLayer = CAShapeLayer()
    private var color: NSColor = .systemRed

    private let cornerRadius: CGFloat = 5
    private let lineWidth: CGFloat = 1.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        // Glow: a wider accent stroke with a strong accent shadow bloom.
        glowLayer.fillColor = nil
        glowLayer.lineWidth = 3
        glowLayer.shadowRadius = 16
        glowLayer.shadowOpacity = 1
        glowLayer.shadowOffset = .zero
        glowLayer.masksToBounds = false

        // Crisp line: a thin bright accent edge on top.
        lineLayer.fillColor = nil
        lineLayer.lineWidth = lineWidth

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
            glowLayer.strokeColor = newValue.withAlphaComponent(0.85).cgColor
            glowLayer.shadowColor = newValue.cgColor
            lineLayer.strokeColor = newValue.cgColor
        }
    }

    /// Rebuilds the rounded-rect path around `rect` (the target area, in view coords). Called
    /// on show and on resize; disabled implicit animations so a resize snaps, not lerps.
    func setTarget(_ rect: CGRect) {
        let strokeRect = rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        let path = CGPath(roundedRect: strokeRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.frame = bounds
        lineLayer.frame = bounds
        glowLayer.path = path
        lineLayer.path = path
        CATransaction.commit()
    }

    /// A gentle settle onto the window when it first appears: fade in while the frame eases
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
