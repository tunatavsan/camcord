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
/// accented border and a pixel-dimension badge; otherwise, if a window is
/// snapped, highlights its frame instead.
@MainActor
final class SelectionView: NSView {
    weak var delegate: SelectionViewDelegate?
    var backingScale: CGFloat = 1

    /// The selection's intent color: blue for a screenshot, red for a recording. Drives
    /// BOTH the region border and the window-snap highlight so every pick reads the same.
    var accent: NSColor = Theme.Palette.ink.ns {
        didSet {
            highlightLayer.strokeColor = accent.cgColor
            highlightLayer.fillColor = accent.withAlphaComponent(0.14).cgColor
            chromeView.needsDisplay = true
        }
    }

    /// Local-coordinate rect to punch out of the dim and outline.
    /// Nil on screens the current cross-screen selection doesn't intersect.
    var selectionRect: CGRect? {
        didSet {
            updateMaskPath()
            chromeView.needsDisplay = true
        }
    }
    /// Local-coordinate rect of a window-snap highlight. Nil when not in snap mode
    /// or the snapped window doesn't intersect this screen. Rendered by an animated
    /// CAShapeLayer (rounded like a macOS window, morphs between windows), not draw().
    var highlightRect: CGRect? {
        didSet {
            guard highlightRect != oldValue else { return }
            updateHighlightLayer(from: oldValue)
        }
    }

    /// macOS windows' corner radius — the highlight matches it.
    private static let windowCornerRadius: CGFloat = 11
    private static let highlightDuration: CFTimeInterval = 0.22
    private let frozenDesktopLayer = CALayer()
    private let dimLayer = CALayer()
    private let maskLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()
    // NSView.draw paints its backing layer BELOW custom sublayers. Keep drag chrome
    // in a separate foreground view so an opaque frozen screenshot cannot cover it.
    private let chromeView = SelectionChromeView()
    /// Dimension badge (local anchor rect + "W x H" pixel text), shown only on the
    /// screen the cursor is currently over.
    var badge: (rect: CGRect, text: String)? {
        didSet { chromeView.needsDisplay = true; setAccessibilityValue(badge?.text) }
    }
    /// The current drag is an OCR (right-button) selection — draw it distinctly (teal
    /// outline + label) so it never looks like a plain screenshot selection.
    var selectionIsText: Bool = false {
        didSet { chromeView.needsDisplay = true }
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    private var trackingArea: NSTrackingArea?
    /// The badge text is laid out once per change, not on every drag frame.
    private var badgeLayout: (text: String, line: NSAttributedString, size: CGSize)?
    private static let badgeAttributes: [NSAttributedString.Key: Any] = [
        .font: Theme.Font.ns.dataStrong,
        .foregroundColor: Theme.Palette.ink.dark.nsColor,
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Select a capture region"))
        setAccessibilityHelp(String(localized: "Drag to select an area. Press Esc to cancel."))

        frozenDesktopLayer.frame = bounds
        frozenDesktopLayer.contentsGravity = .resize
        frozenDesktopLayer.magnificationFilter = .nearest
        frozenDesktopLayer.minificationFilter = .linear
        layer?.addSublayer(frozenDesktopLayer)

        dimLayer.frame = bounds
        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor

        maskLayer.frame = bounds
        maskLayer.fillRule = .evenOdd
        dimLayer.mask = maskLayer
        layer?.addSublayer(dimLayer)

        highlightLayer.frame = bounds
        highlightLayer.fillColor = accent.withAlphaComponent(0.14).cgColor
        highlightLayer.strokeColor = accent.cgColor
        highlightLayer.lineWidth = 2
        highlightLayer.opacity = 0
        // A soft glow so the highlight reads like it's lit — the same "floating" feel the
        // recording border and preview card have.
        highlightLayer.shadowColor = accent.cgColor
        highlightLayer.shadowRadius = 6
        highlightLayer.shadowOpacity = 0.5
        highlightLayer.shadowOffset = .zero
        layer?.addSublayer(highlightLayer)

        chromeView.frame = bounds
        chromeView.autoresizingMask = [.width, .height]
        chromeView.drawChrome = { [weak self] in self?.drawSelectionChrome() }
        addSubview(chromeView)

        updateMaskPath()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frozenDesktopLayer.frame = bounds
        dimLayer.frame = bounds
        highlightLayer.frame = bounds
        CATransaction.commit()
        updateMaskPath()
    }

    /// Installs the immutable trigger-time pixels beneath the selection chrome.
    func setFrozenDesktopImage(_ image: CGImage?, scale: CGFloat = 1) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frozenDesktopLayer.contents = image
        frozenDesktopLayer.contentsScale = max(scale, 1)
        CATransaction.commit()
    }

    private func updateMaskPath() {
        // Pointer-driven geometry follows the pointer exactly; implicit layer
        // animation would leave the dim cutout trailing behind the visible border.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.frame = bounds
        let path = CGMutablePath()
        path.addRect(bounds)
        if let selectionRect {
            let r = selectionCornerRadius(for: selectionRect)
            path.addRoundedRect(in: selectionRect, cornerWidth: r, cornerHeight: r)
        }
        maskLayer.path = path
        CATransaction.commit()
    }

    // MARK: - Window-snap highlight (rounded like a macOS window, morphs between windows)

    private func updateHighlightLayer(from oldValue: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        highlightLayer.frame = bounds
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            highlightLayer.removeAllAnimations()
            highlightLayer.path = highlightRect.map {
                CGPath(roundedRect: $0, cornerWidth: Self.windowCornerRadius,
                       cornerHeight: Self.windowCornerRadius, transform: nil)
            }
            highlightLayer.opacity = highlightRect == nil ? 0 : 1
            return
        }
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
            spring.mass = 1
            spring.stiffness = 210
            spring.damping = 19
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

    /// The selection's corners on screen, the app's soft corner, smaller on a small selection. The
    /// capture itself keeps its square corners: this only draws the area being taken.
    private func selectionCornerRadius(for rect: CGRect) -> CGFloat {
        selectionIsText ? 3 : min(8, min(rect.width, rect.height) / 4)
    }

    private func drawSelectionChrome() {
        if let selectionRect {
            if selectionIsText {
                // Not the app's corner on purpose: this traces the rect the user dragged,
                // and the non-text border next to it is square. A UI radius here would
                // round away the selection's real edges.
                let border = NSBezierPath(roundedRect: selectionRect, xRadius: 3, yRadius: 3)
                border.lineWidth = 2
                Theme.Palette.ink.ns.setStroke()
                border.stroke()
                drawModeLabel(String(localized: "Text · OCR", comment: "Label above a text-recognition selection"), near: selectionRect)
            } else {
                drawAccentBorder(around: selectionRect)
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
            .font: Theme.Font.ns.caption,
            .foregroundColor: Theme.Palette.ink.dark.nsColor,
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
        Theme.Palette.glassSolidHUD.ns.setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: Theme.Radius.well, yRadius: Theme.Radius.well).fill()
        attributed.draw(at: CGPoint(x: labelRect.minX + hp, y: labelRect.minY + vp))
    }

    /// The region border in the intent color (blue = screenshot, red = recording), lit by a
    /// soft accent glow so it reads on any background — the same visual language as the
    /// window-snap highlight, instead of the old colorless dashed marching ants.
    private func drawAccentBorder(around rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = accent.withAlphaComponent(0.7)
        glow.shadowBlurRadius = 7
        glow.shadowOffset = .zero
        glow.set()
        // A subtle dark hairline just outside keeps the accent line visible even where the
        // content behind it is the same hue.
        let r = selectionCornerRadius(for: rect)
        let outer = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: r + 1, yRadius: r + 1)
        outer.lineWidth = 1
        NSColor.black.withAlphaComponent(0.35).setStroke()
        outer.stroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        path.lineWidth = 2
        accent.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBadge(_ text: String, near rect: CGRect) {
        if badgeLayout?.text != text {
            let line = NSAttributedString(string: text, attributes: Self.badgeAttributes)
            badgeLayout = (text, line, line.size())
        }
        guard let (_, attributed, textSize) = badgeLayout else { return }
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

        let path = NSBezierPath(roundedRect: badgeRect, xRadius: Theme.Radius.well, yRadius: Theme.Radius.well)
        Theme.Palette.glassSolidHUD.ns.setFill()
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

/// A transparent foreground that never steals drag, hover, or keyboard routing
/// from SelectionView. AppKit handles Retina backing and redraws only the chrome.
@MainActor
private final class SelectionChromeView: NSView {
    var drawChrome: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        drawChrome?()
    }
}
