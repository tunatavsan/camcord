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
        if PinChromeGeometry.corner(at: local, in: bounds) != nil { return self }
        if PinChromeGeometry.pressCloses(at: local, in: bounds) { return self }
        return nil
    }

    /// The resize cursor over a corner; nil elsewhere, where the capture decides.
    func cursor(atWindowPoint point: CGPoint) -> NSCursor? {
        let local = convert(point, from: nil)
        if let corner = resizing ?? PinChromeGeometry.corner(at: local, in: bounds) { return Self.cursor(for: corner) }
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
        indicate(PinChromeGeometry.hotspot(at: pointer, in: bounds))
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
        if PinChromeGeometry.corner(at: point, in: bounds) == nil,
           PinChromeGeometry.pressCloses(at: point, in: bounds) {
            closedOnDown = true
            indicate(nil)
            onClose?()
            return
        }
        guard let corner = PinChromeGeometry.corner(at: point, in: bounds) else { return }
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
            PinChromeGeometry.closePressRect(in: bounds)?.contains(point) ?? false
        } == true
        closeChip.setGlowing(overClose, reduceMotion: reduceMotion)
        let chip = PinChromeGeometry.chipFrame(chromeCorner, in: bounds).insetBy(dx: -4, dy: -4)
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
        if let circle = PinChromeGeometry.closeFrame(in: bounds) {
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
        let chip = PinChromeGeometry.chipFrame(corner, in: bounds)
        resizeChipDown.frame = chip
        resizeChipUp.frame = chip
        // The corner's own blur, as the × has the edge's: heaviest in the corner itself, still
        // soft under the chip, gone a little past it, so it never floats as a patch of its own.
        let side = PinChromeGeometry.cornerVeilSide(in: bounds)
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topLeft || corner == .topRight
        cornerVeil.frame = CGRect(x: right ? bounds.maxX - side : bounds.minX, y: top ? bounds.maxY - side : bounds.minY,
                                  width: side, height: side)
        cornerVeil.edge = .corner(corner)
        cornerVeil.outline = clipped(to: cornerVeil.frame)
    }
}

/// Where the pin's buttons stand. Unlike the camera's, whose corner grows with its size, a pin's
/// corner is the well's small fixed one, so its chips keep the same place in from each corner at
/// every size, and so does the blur behind them.
enum PinChromeGeometry {
    /// From the pin's edges to its buttons.
    static let inset: CGFloat = 10

    static func chipDiameter(in bounds: CGRect) -> CGFloat {
        min(26, max(20, min(bounds.width, bounds.height) * 0.12))
    }

    /// The square in a corner that reveals its chip and resizes from it.
    static func cornerZone(_ corner: CameraCorner, in bounds: CGRect) -> CGRect {
        let extent = min(52, bounds.width * 0.3, bounds.height * 0.4)
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topLeft || corner == .topRight
        return CGRect(x: right ? bounds.maxX - extent : bounds.minX, y: top ? bounds.maxY - extent : bounds.minY,
                      width: extent, height: extent)
    }

    static func corner(at point: CGPoint, in bounds: CGRect) -> CameraCorner? {
        CameraCorner.allCases.first { cornerZone($0, in: bounds).contains(point) }
    }

    static func chipFrame(_ corner: CameraCorner, in bounds: CGRect) -> CGRect {
        let d = chipDiameter(in: bounds)
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topLeft || corner == .topRight
        return CGRect(x: right ? bounds.maxX - inset - d : bounds.minX + inset,
                      y: top ? bounds.maxY - inset - d : bounds.minY + inset, width: d, height: d)
    }

    /// The side of the corner's blur: enough to lie soft under the chip and fade out past it.
    static func cornerVeilSide(in bounds: CGRect) -> CGFloat {
        min(min(bounds.width, bounds.height) * 0.45, (inset + chipDiameter(in: bounds)) * 2.6)
    }

    /// The ×, centred on the top edge; nil when the pin is too small to keep it clear of the corners.
    static func closeFrame(in bounds: CGRect) -> CGRect? {
        let d = chipDiameter(in: bounds)
        let corners = cornerZone(.topLeft, in: bounds).width
        guard bounds.width - 2 * corners >= d + 8, bounds.height >= d * 3 else { return nil }
        return CGRect(x: bounds.midX - d / 2, y: bounds.maxY - inset - d, width: d, height: d)
    }

    /// What a press on the × counts as: the circle and a little around it.
    static func closePressRect(in bounds: CGRect) -> CGRect? {
        closeFrame(in: bounds).map { $0.insetBy(dx: -max(4, $0.width * 0.18), dy: -max(4, $0.width * 0.18)) }
    }

    /// What reveals the ×: the top middle, up to the edge, clear of the corners.
    static func closeRevealRect(in bounds: CGRect) -> CGRect? {
        guard let circle = closeFrame(in: bounds) else { return nil }
        let pad = max(14, circle.width * 0.6)
        let zone = CGRect(x: circle.minX - pad, y: circle.minY - pad, width: circle.width + pad * 2,
                          height: bounds.maxY - circle.minY + pad)
        let corners = cornerZone(.topLeft, in: bounds).width
        let free = CGRect(x: bounds.minX + corners, y: bounds.minY, width: max(0, bounds.width - 2 * corners), height: bounds.height)
        let clipped = zone.intersection(free)
        return clipped.isNull ? nil : clipped
    }

    /// What the pointer is over: a corner first, then the ×.
    static func hotspot(at point: CGPoint, in bounds: CGRect) -> CameraHotspot? {
        if let corner = corner(at: point, in: bounds) { return .resize(corner) }
        if let reveal = closeRevealRect(in: bounds), reveal.contains(point) { return .close }
        return nil
    }

    /// Whether a press at `point` closes the pin: only on the × itself.
    static func pressCloses(at point: CGPoint, in bounds: CGRect) -> Bool {
        guard corner(at: point, in: bounds) == nil, let button = closePressRect(in: bounds) else { return false }
        return button.contains(point)
    }
}
