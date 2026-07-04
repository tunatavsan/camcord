import AppKit

/// Mouse/keyboard events, forwarded as raw global (AppKit-space) points -- the
/// controller owns all coordinate-space conversions and cross-screen drag state.
@MainActor
protocol SelectionViewDelegate: AnyObject {
    /// `isRight` = the right mouse button (OCR); left is the plain screenshot.
    func selectionViewMouseDown(at globalPoint: CGPoint, isRight: Bool)
    func selectionViewMouseDragged(to globalPoint: CGPoint, isRight: Bool)
    func selectionViewMouseUp(at globalPoint: CGPoint, isRight: Bool)
    func selectionViewMouseMoved(to globalPoint: CGPoint)
    func selectionViewCancel()
}

/// One per screen. Dims its screen 12% black; while the controller reports an active
/// drag, punches a clear hole at the (screen-local) selection intersection with a
/// dashed white+black border and a pixel-dimension badge; otherwise, if a window is
/// snapped, highlights its frame instead.
@MainActor
final class SelectionView: NSView {
    weak var delegate: SelectionViewDelegate?
    var backingScale: CGFloat = 1

    /// Local-coordinate rect to punch out of the dim + draw the dashed border around.
    /// Nil on screens the current cross-screen selection doesn't intersect.
    var selectionRect: CGRect? {
        didSet { needsDisplay = true }
    }
    /// Local-coordinate rect of a window-snap highlight. Nil when not in snap mode
    /// or the snapped window doesn't intersect this screen. Rendered by an animated
    /// CAShapeLayer (rounded like a macOS window, morphs between windows), not draw().
    var highlightRect: CGRect? {
        didSet { updateHighlightLayer(from: oldValue) }
    }

    /// macOS windows' corner radius — the highlight matches it.
    private static let windowCornerRadius: CGFloat = 11
    private static let highlightDuration: CFTimeInterval = 0.22
    private let highlightLayer = CAShapeLayer()
    /// Dimension badge (local anchor rect + "W x H" pixel text), shown only on the
    /// screen the cursor is currently over.
    var badge: (rect: CGRect, text: String)? {
        didSet { needsDisplay = true }
    }
    /// The current drag is an OCR (right-button) selection — draw it distinctly (teal
    /// outline + label) so it never looks like a plain screenshot selection.
    var selectionIsText: Bool = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        highlightLayer.frame = bounds
        highlightLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        highlightLayer.strokeColor = NSColor.systemBlue.cgColor
        highlightLayer.lineWidth = 2
        highlightLayer.opacity = 0
        layer?.addSublayer(highlightLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        highlightLayer.frame = bounds
    }

    // MARK: - Window-snap highlight (rounded like a macOS window, morphs between windows)

    private func updateHighlightLayer(from oldValue: CGRect?) {
        highlightLayer.frame = bounds
        guard let rect = highlightRect else {
            animate(keyPath: "opacity", to: 0, duration: 0.16)
            highlightLayer.opacity = 0
            return
        }
        let r = Self.windowCornerRadius
        let newPath = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        if oldValue == nil {
            // Fresh appearance: set the shape instantly, fade it in (nothing to morph).
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlightLayer.path = newPath
            CATransaction.commit()
            animate(keyPath: "opacity", to: 1, duration: 0.16)
            highlightLayer.opacity = 1
        } else {
            // Moving between windows: springy morph of the rounded rect — a snappy,
            // slightly bouncy settle rather than a flat linear slide.
            let spring = CASpringAnimation(keyPath: "path")
            spring.fromValue = highlightLayer.presentation()?.path ?? highlightLayer.path
            spring.toValue = newPath
            spring.mass = 0.9
            spring.stiffness = 220
            spring.damping = 17
            spring.initialVelocity = 6
            spring.duration = spring.settlingDuration
            spring.timingFunction = CAMediaTimingFunction(name: .easeOut)
            highlightLayer.add(spring, forKey: "path")
            highlightLayer.path = newPath
            if highlightLayer.opacity < 1 {
                animate(keyPath: "opacity", to: 1, duration: 0.16)
                highlightLayer.opacity = 1
            }
        }
    }

    private func animate(keyPath: String, to value: Any?, duration: CFTimeInterval, from: Any? = nil) {
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = from ?? highlightLayer.presentation()?.value(forKeyPath: keyPath) ?? highlightLayer.value(forKeyPath: keyPath)
        anim.toValue = value
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        highlightLayer.add(anim, forKey: keyPath)
    }

    /// `mouseMoved` events are only delivered to the KEY window's view by default, so
    /// without an explicit tracking area, window-snap hover would silently stop working
    /// on every screen except the one whose panel happens to be key. `.activeAlways`
    /// makes this view receive mouseMoved regardless of key/main status;
    /// `.inVisibleRect` keeps the tracked rect in sync with the view's bounds automatically.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.12).setFill()
        bounds.fill()

        if let selectionRect {
            selectionRect.fill(using: .clear)
            if selectionIsText {
                let border = NSBezierPath(roundedRect: selectionRect, xRadius: 3, yRadius: 3)
                border.lineWidth = 2
                NSColor.systemTeal.setStroke()
                border.stroke()
                drawModeLabel("Metin · OCR", near: selectionRect)
            } else {
                drawDashedBorder(around: selectionRect)
            }
            if let badge {
                drawBadge(badge.text, near: badge.rect)
            }
        }
        // The window-snap highlight is drawn by `highlightLayer` (animated), not here.
    }

    /// A small pill above the selection naming the OCR mode.
    private func drawModeLabel(_ text: String, near rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let hp: CGFloat = 7, vp: CGFloat = 3
        let size = CGSize(width: textSize.width + hp * 2, height: textSize.height + vp * 2)
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 6)
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - size.width))
        if origin.y + size.height > bounds.maxY {
            origin.y = rect.maxY - size.height - 6
        }
        let labelRect = CGRect(origin: origin, size: size)
        NSColor.systemTeal.setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
        attributed.draw(at: CGPoint(x: labelRect.minX + hp, y: labelRect.minY + vp))
    }

    private func drawDashedBorder(around rect: CGRect) {
        let dashPattern: [CGFloat] = [4, 4]

        let whitePath = NSBezierPath(rect: rect)
        whitePath.lineWidth = 1
        dashPattern.withUnsafeBufferPointer { buffer in
            whitePath.setLineDash(buffer.baseAddress, count: buffer.count, phase: 0)
        }
        NSColor.white.setStroke()
        whitePath.stroke()

        let blackPath = NSBezierPath(rect: rect)
        blackPath.lineWidth = 1
        dashPattern.withUnsafeBufferPointer { buffer in
            blackPath.setLineDash(buffer.baseAddress, count: buffer.count, phase: 4)
        }
        NSColor.black.setStroke()
        blackPath.stroke()
    }

    private func drawBadge(_ text: String, near rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let horizontalPadding: CGFloat = 6
        let verticalPadding: CGFloat = 3

        let badgeSize = CGSize(width: textSize.width + horizontalPadding * 2, height: textSize.height + verticalPadding * 2)
        var badgeOrigin = CGPoint(x: rect.maxX - badgeSize.width, y: rect.maxY + 6)
        badgeOrigin.x = max(bounds.minX, min(badgeOrigin.x, bounds.maxX - badgeSize.width))
        // Clamp Y too: a selection reaching the top of the screen would otherwise
        // push the badge offscreen. Fall below the selection edge when clamped.
        if badgeOrigin.y + badgeSize.height > bounds.maxY {
            badgeOrigin.y = rect.maxY - badgeSize.height - 6
        }
        let badgeRect = CGRect(origin: badgeOrigin, size: badgeSize)

        let path = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        path.fill()
        attributed.draw(at: CGPoint(x: badgeRect.minX + horizontalPadding, y: badgeRect.minY + verticalPadding))
    }

    // MARK: - Mouse / keyboard events -- forwarded verbatim, no conversion here.

    override func mouseDown(with event: NSEvent) {
        delegate?.selectionViewMouseDown(at: NSEvent.mouseLocation, isRight: false)
    }

    override func mouseDragged(with event: NSEvent) {
        delegate?.selectionViewMouseDragged(to: NSEvent.mouseLocation, isRight: false)
    }

    override func mouseUp(with event: NSEvent) {
        delegate?.selectionViewMouseUp(at: NSEvent.mouseLocation, isRight: false)
    }

    // Right button drives the same region/window selection but in OCR mode.
    override func rightMouseDown(with event: NSEvent) {
        delegate?.selectionViewMouseDown(at: NSEvent.mouseLocation, isRight: true)
    }

    override func rightMouseDragged(with event: NSEvent) {
        delegate?.selectionViewMouseDragged(to: NSEvent.mouseLocation, isRight: true)
    }

    override func rightMouseUp(with event: NSEvent) {
        delegate?.selectionViewMouseUp(at: NSEvent.mouseLocation, isRight: true)
    }

    override func mouseMoved(with event: NSEvent) {
        delegate?.selectionViewMouseMoved(to: NSEvent.mouseLocation)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            delegate?.selectionViewCancel()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        delegate?.selectionViewCancel()
    }
}
