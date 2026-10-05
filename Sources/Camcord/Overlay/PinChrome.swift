import AppKit
import QuartzCore

/// The pin's own buttons, the camera's: over the top centre a glass × on a blur of the capture,
/// in each corner a glass resize chip on a blur of that corner. They come as the pointer comes
/// to them, and the chip under it swells and glows. A press on the × closes; a drag from a
/// corner resizes the pin at the capture's own ratio. Everywhere else the capture underneath
/// takes the pointer: zoom, pan, moving the pin.
@MainActor final class PinChrome: NSView {
    var onClose: (() -> Void)?
    var onResize: ((CameraCorner, FloatingCameraView.DragPhase) -> Void)?
    /// The well's own corner radius, so the blur never spills past it.
    var outlineRadius: CGFloat = Theme.Radius.well { didSet { needsLayout = true } }
    private let topVeil = ProgressiveBlurView()
    private let cornerVeil = ProgressiveBlurView()
    private let closeChip = CameraGlassChip(symbol: "xmark", pointSize: 10, weight: .bold)
    /// One per diagonal, so the arrows always point along the corner's own resize.
    private let resizeChipDown = CameraGlassChip(symbol: "arrow.up.left.and.arrow.down.right", pointSize: 10, weight: .semibold)
    private let resizeChipUp = CameraGlassChip(symbol: "arrow.up.right.and.arrow.down.left", pointSize: 10, weight: .semibold)
    private(set) var indicated: CameraHotspot?
    private var chromeCorner: CameraCorner = .bottomRight
    private var pointer: CGPoint?
    private var resizing: CameraCorner?
    private var closedOnDown = false
    private var tracking: NSTrackingArea?
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for view in [topVeil, cornerVeil, closeChip, resizeChipDown, resizeChipUp] { addSubview(view) }
        closeChip.setAccessibilityElement(true)
        closeChip.setAccessibilityRole(.button)
        closeChip.setAccessibilityLabel(String(localized: "Close"))
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Only the × and the resize corners belong to the chrome.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if CameraResizeGeometry.corner(at: local, in: bounds) != nil { return self }
        if CameraResizeGeometry.pressClosesPreview(at: local, in: bounds) { return self }
        return nil
    }

    /// The resize cursor over a corner; nil elsewhere, where the capture decides.
    func cursor(atWindowPoint point: CGPoint) -> NSCursor? {
        let local = convert(point, from: nil)
        if let corner = resizing ?? CameraResizeGeometry.corner(at: local, in: bounds) { return Self.cursor(for: corner) }
        return nil
    }

    static func cursor(for corner: CameraCorner) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch corner {
        case .topLeft: position = .topLeft
        case .topRight: position = .topRight
        case .bottomLeft: position = .bottomLeft
        case .bottomRight: position = .bottomRight
        }
        return .frameResize(position: position, directions: .all)
    }

    override func layout() {
        super.layout()
        layoutChrome()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func track(_ event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        guard resizing == nil, let pointer else { updateGlow(); return }
        indicate(CameraResizeGeometry.hotspot(at: pointer, in: bounds))
    }
    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) {
        pointer = nil
        if resizing == nil { indicate(nil) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The × closes on mouse-down, as the camera's does: no drag can start from under it.
        if CameraResizeGeometry.corner(at: point, in: bounds) == nil,
           CameraResizeGeometry.pressClosesPreview(at: point, in: bounds) {
            closedOnDown = true
            indicate(nil)
            onClose?()
            return
        }
        guard let corner = CameraResizeGeometry.corner(at: point, in: bounds) else { return }
        resizing = corner
        indicate(.resize(corner))
        Self.cursor(for: corner).set()
        onResize?(corner, .began)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let resizing else { return }
        onResize?(resizing, .changed)
    }
    override func mouseUp(with event: NSEvent) {
        if closedOnDown { closedOnDown = false; return }
        guard let corner = resizing else { return }
        onResize?(corner, .ended)
        resizing = nil
        track(event)
    }

    #if DEBUG
    /// Test seam: drives the hover state without synthesising an NSEvent.
    func indicateForTesting(_ hotspot: CameraHotspot?) { indicate(hotspot) }
    #endif

    /// Everything back to rest: the pointer left the pin.
    func rest() {
        guard resizing == nil else { return }
        pointer = nil
        indicate(nil)
    }

    private func indicate(_ hotspot: CameraHotspot?) {
        guard hotspot != indicated else { updateGlow(); return }
        indicated = hotspot
        if let corner = hotspot?.corner, corner != chromeCorner {
            chromeCorner = corner
            layoutChrome()
        }
        let corner = hotspot?.corner
        topVeil.setShown(hotspot == .close, reduceMotion: reduceMotion)
        cornerVeil.setShown(corner != nil, reduceMotion: reduceMotion)
        show(closeChip, hotspot == .close)
        show(resizeChipDown, corner == .topLeft || corner == .bottomRight)
        show(resizeChipUp, corner == .topRight || corner == .bottomLeft)
        updateGlow()
    }

    /// A chip arrives just after the blur it sits on, and leaves with it.
    private func show(_ chip: CameraGlassChip, _ shown: Bool) {
        guard chip.isShown != shown else { return }
        if !shown { chip.setGlowing(false, reduceMotion: reduceMotion) }
        chip.setShown(shown, delay: shown && !reduceMotion ? 0.04 : 0, reduceMotion: reduceMotion)
    }

    /// The chip under the pointer glows: the × over its press target, a resize chip over itself
    /// or while it resizes.
    private func updateGlow() {
        let overClose = indicated == .close && pointer.map { point in
            CameraResizeGeometry.closeButtonRect(in: bounds)?.contains(point) ?? false
        } == true
        closeChip.setGlowing(overClose, reduceMotion: reduceMotion)
        let chip = CameraResizeGeometry.resizeChipFrame(chromeCorner, in: bounds).insetBy(dx: -4, dy: -4)
        let active = indicated?.corner != nil && (resizing != nil || pointer.map { chip.contains($0) } == true)
        for resize in [resizeChipDown, resizeChipUp] { resize.setGlowing(active && resize.isShown, reduceMotion: reduceMotion) }
    }

    /// The chips and the blur behind them, placed for the pin's size.
    private func layoutChrome() {
        let outline = CGPath(roundedRect: bounds, cornerWidth: outlineRadius, cornerHeight: outlineRadius, transform: nil)
        func clipped(to frame: CGRect) -> CGPath? {
            var shift = CGAffineTransform(translationX: -frame.minX, y: -frame.minY)
            return outline.copy(using: &shift)
        }
        if let circle = CameraResizeGeometry.closeFrame(in: bounds) {
            closeChip.isHidden = false
            closeChip.frame = circle
            // The × sits on the top edge's own blur: heaviest along the edge, gone a little below the
            // ×, and kept to the middle, thinning out toward both sides.
            let width = min(bounds.width, max(circle.width * 7, bounds.width * 0.4))
            let height = min(bounds.height * 0.5, bounds.maxY - circle.minY + circle.height * 0.6)
            topVeil.frame = CGRect(x: circle.midX - width / 2, y: bounds.maxY - height, width: width, height: height)
            topVeil.edge = .band(sideFade: 0.38)
            topVeil.outline = clipped(to: topVeil.frame)
        } else {
            closeChip.isHidden = true
        }
        let corner = chromeCorner
        let chip = CameraResizeGeometry.resizeChipFrame(corner, in: bounds)
        resizeChipDown.frame = chip
        resizeChipUp.frame = chip
        // Only around the chip: a small round blur centred on it, gone before the veil's edges.
        let side = min(min(bounds.width, bounds.height) * 0.6, chip.width * 2.8)
        cornerVeil.frame = CGRect(x: chip.midX - side / 2, y: chip.midY - side / 2, width: side, height: side)
        cornerVeil.edge = .spot(CGPoint(x: 0.5, y: 0.5), reach: 0.48)
        cornerVeil.outline = clipped(to: cornerVeil.frame)
    }
}
