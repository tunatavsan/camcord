import AppKit

/// Mouse/keyboard events, forwarded as raw global (AppKit-space) points -- the
/// controller owns all coordinate-space conversions and cross-screen drag state.
@MainActor
protocol SelectionViewDelegate: AnyObject {
    func selectionViewMouseDown(at globalPoint: CGPoint)
    func selectionViewMouseDragged(to globalPoint: CGPoint)
    func selectionViewMouseUp(at globalPoint: CGPoint)
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
    /// or the snapped window doesn't intersect this screen.
    var highlightRect: CGRect? {
        didSet { needsDisplay = true }
    }
    /// Dimension badge (local anchor rect + "W x H" pixel text), shown only on the
    /// screen the cursor is currently over.
    var badge: (rect: CGRect, text: String)? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    private var trackingArea: NSTrackingArea?

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
            drawDashedBorder(around: selectionRect)
            if let badge {
                drawBadge(badge.text, near: badge.rect)
            }
        } else if let highlightRect {
            NSColor.systemBlue.withAlphaComponent(0.08).setFill()
            highlightRect.fill()
            let path = NSBezierPath(rect: highlightRect.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            NSColor.systemBlue.setStroke()
            path.stroke()
        }
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
        delegate?.selectionViewMouseDown(at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        delegate?.selectionViewMouseDragged(to: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        delegate?.selectionViewMouseUp(at: NSEvent.mouseLocation)
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
