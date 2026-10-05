import AppKit
import QuartzCore

/// Where the capture sits in a preview at a magnification. `zoom` 1 shows it whole; `focus` is
/// the capture's point at the view's centre, in the capture's unit square (y up).
struct PreviewZoomGeometry: Equatable {
    var zoom: CGFloat = 1
    var focus = CGPoint(x: 0.5, y: 0.5)

    /// The capture whole in `bounds`: aspect-fit, never magnified past its own size.
    static func fit(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(1, bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// The largest zoom: four times the capture's own size, and never less than twice whole.
    static func maximum(_ size: CGSize, in bounds: CGSize) -> CGFloat {
        let fitted = fit(size, in: bounds)
        guard fitted.width > 0 else { return 1 }
        return max(2, 4 * size.width / fitted.width)
    }

    /// Where a double click goes from whole: the capture's own size when the view shrinks it
    /// noticeably, else twice that.
    static func closer(_ size: CGSize, in bounds: CGSize) -> CGFloat {
        let fitted = fit(size, in: bounds)
        guard fitted.width > 0 else { return 1 }
        let actual = size.width / fitted.width
        return actual >= 1.5 ? actual : 2 * actual
    }

    /// The capture's rect in the view. Larger than the view, it never leaves a gap at an edge;
    /// smaller, it stays centred.
    func rect(_ size: CGSize, in bounds: CGSize) -> CGRect {
        let fitted = Self.fit(size, in: bounds)
        let shown = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
        func origin(_ length: CGFloat, _ room: CGFloat, _ focus: CGFloat) -> CGFloat {
            guard length > room else { return (room - length) / 2 }
            return min(0, max(room - length, room / 2 - focus * length))
        }
        return CGRect(x: origin(shown.width, bounds.width, focus.x), y: origin(shown.height, bounds.height, focus.y),
                      width: shown.width, height: shown.height)
    }

    /// The same view after the rect was clamped: the focus is what is really at the centre.
    mutating func settle(_ size: CGSize, in bounds: CGSize) {
        let shown = rect(size, in: bounds)
        guard shown.width > 0, shown.height > 0 else { return }
        focus = CGPoint(x: (bounds.width / 2 - shown.minX) / shown.width, y: (bounds.height / 2 - shown.minY) / shown.height)
    }

    /// A pinch past the zoom's limits gives way less and less, the way a trackpad does.
    static func resisted(_ zoom: CGFloat, maximum: CGFloat) -> CGFloat {
        if zoom < 1 { return pow(zoom, 0.3) }
        if zoom > maximum { return maximum * pow(zoom / maximum, 0.3) }
        return zoom
    }

    /// Zooms to `target`, keeping the capture's point under `anchor` (view coordinates) in place.
    /// Elastic, it may stretch a little past the limits while a pinch is under way.
    mutating func zoom(to target: CGFloat, keeping anchor: CGPoint, _ size: CGSize, in bounds: CGSize,
                       elastic: Bool = false) {
        let before = rect(size, in: bounds)
        guard before.width > 0, before.height > 0 else { return }
        let unit = CGPoint(x: (anchor.x - before.minX) / before.width, y: (anchor.y - before.minY) / before.height)
        let maximum = Self.maximum(size, in: bounds)
        zoom = elastic ? Self.resisted(target, maximum: maximum) : min(max(target, 1), maximum)
        let fitted = Self.fit(size, in: bounds)
        let shown = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
        let origin = CGPoint(x: anchor.x - unit.x * shown.width, y: anchor.y - unit.y * shown.height)
        focus = CGPoint(x: (bounds.width / 2 - origin.x) / shown.width, y: (bounds.height / 2 - origin.y) / shown.height)
        settle(size, in: bounds)
    }

    /// Moves the capture by `delta` view points.
    mutating func pan(by delta: CGPoint, _ size: CGSize, in bounds: CGSize) {
        let shown = rect(size, in: bounds)
        guard shown.width > 0, shown.height > 0 else { return }
        focus = CGPoint(x: focus.x - delta.x / shown.width, y: focus.y - delta.y / shown.height)
        settle(size, in: bounds)
    }
}

/// The capture in a preview, at any magnification: pinch, ⌘-scroll, ⌘+ and ⌘−, or a double
/// click to look closer where it was clicked and again to see it whole. Zoomed in, a drag or a
/// scroll moves around it; whole, a drag moves the window. The pixels come straight from the
/// capture in tiles the GPU can hold, so a tall scroll capture stays sharp at every size.
@MainActor final class ScreenshotPreviewZoom: NSView {
    private let image: CGImage
    private let size: CGSize
    private let lift = CALayer()
    private let picture = CALayer()
    private var tiles: [CALayer] = []
    private let readout = CATextLayer()
    private var readoutTask: Task<Void, Never>?
    private(set) var geometry = PreviewZoomGeometry()
    private var panFrom: CGPoint?
    /// The zoom a pinch asks for, before it gives way at the limits.
    private var pinch: CGFloat?
    var canInteract: @MainActor () -> Bool = { true }
    var isZoomed: Bool { geometry.zoom > 1.001 }
    static let tile = 4_096

    init(image: CGImage, pointSize: CGSize) {
        self.image = image
        size = pointSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        lift.shadowColor = NSColor.black.cgColor
        lift.shadowOpacity = 0.35
        lift.shadowRadius = 6
        lift.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(lift)
        picture.anchorPoint = .zero
        picture.bounds = CGRect(origin: .zero, size: pointSize)
        layer?.addSublayer(picture)
        buildTiles()
        readout.alignmentMode = .center
        readout.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        readout.fontSize = 12
        readout.foregroundColor = NSColor.white.cgColor
        readout.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        readout.cornerRadius = 11
        readout.cornerCurve = .continuous
        readout.opacity = 0
        layer?.addSublayer(readout)
        setAccessibilityLabel(String(localized: "Screenshot preview"))
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { nil }

    /// The capture in tiles no larger than the GPU takes, laid out in its point space; cropping
    /// shares the capture's pixels.
    private func buildTiles() {
        let columns = (image.width + Self.tile - 1) / Self.tile, rows = (image.height + Self.tile - 1) / Self.tile
        let toPoints = CGSize(width: size.width / CGFloat(image.width), height: size.height / CGFloat(image.height))
        for row in 0..<rows {
            for column in 0..<columns {
                let pixels = CGRect(x: column * Self.tile, y: row * Self.tile,
                                    width: min(Self.tile, image.width - column * Self.tile),
                                    height: min(Self.tile, image.height - row * Self.tile))
                guard let cut = image.cropping(to: pixels) else { continue }
                let tile = CALayer()
                tile.contents = cut
                tile.contentsGravity = .resize
                tile.minificationFilter = .trilinear
                // Image rows run top-down; the layer's y runs up.
                tile.frame = CGRect(x: pixels.minX * toPoints.width,
                                    y: size.height - pixels.maxY * toPoints.height,
                                    width: pixels.width * toPoints.width, height: pixels.height * toPoints.height)
                picture.addSublayer(tile)
                tiles.append(tile)
            }
        }
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        geometry.settle(size, in: bounds.size)
        place(animated: false)
    }

    private func place(animated: Bool) {
        let shown = geometry.rect(size, in: bounds.size)
        guard shown.width > 0, size.width > 0 else { return }
        CATransaction.begin()
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            CATransaction.setAnimationDuration(0.36)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 1.08, 0.4, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        let scale = shown.width / size.width
        picture.position = shown.origin
        picture.transform = CATransform3DMakeScale(scale, scale, 1)
        lift.frame = shown
        lift.shadowPath = CGPath(rect: CGRect(origin: .zero, size: shown.size), transform: nil)
        // Pixels at least twice the screen's stay square; below that they blend.
        let pixelsPerPixel = shown.width * (window?.backingScaleFactor ?? 2) / CGFloat(image.width)
        let filter: CALayerContentsFilter = pixelsPerPixel >= 2 ? .nearest : .linear
        for tile in tiles where tile.magnificationFilter != filter { tile.magnificationFilter = filter }
        CATransaction.commit()
    }

    /// Zooms to `target` around `anchor` (view coordinates; the centre when nil).
    func zoom(to target: CGFloat, around anchor: CGPoint? = nil, animated: Bool) {
        let before = geometry.zoom
        geometry.zoom(to: target, keeping: anchor ?? CGPoint(x: bounds.midX, y: bounds.midY), size, in: bounds.size)
        place(animated: animated)
        if abs(geometry.zoom - before) > 0.0001 { showReadout() }
        updateCursor()
    }

    func zoomIn() { zoom(to: geometry.zoom * 1.5, animated: true) }
    func zoomOut() { zoom(to: geometry.zoom / 1.5, animated: true) }
    func showWhole() { zoom(to: 1, animated: true) }

    /// The zoom as a percentage of the capture's own size, the way Preview shows it.
    private func showReadout() {
        let shown = geometry.rect(size, in: bounds.size)
        let percent = Int((shown.width / size.width * 100).rounded())
        CATransaction.begin(); CATransaction.setDisableActions(true)
        readout.string = "\(percent)%"
        readout.contentsScale = window?.backingScaleFactor ?? 2
        let width: CGFloat = 58, height: CGFloat = 22
        readout.frame = CGRect(x: bounds.midX - width / 2, y: bounds.maxY - 14 - height, width: width, height: height)
        CATransaction.commit()
        readout.removeAnimation(forKey: "fade")
        readout.opacity = 1
        readoutTask?.cancel()
        readoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self else { return }
            CATransaction.begin(); CATransaction.setAnimationDuration(0.25)
            self.readout.opacity = 0
            CATransaction.commit()
        }
    }

    private func updateCursor() {
        guard let window, window.isVisible else { return }
        let inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        guard inside else { return }
        (isZoomed ? (panFrom == nil ? NSCursor.openHand : NSCursor.closedHand) : NSCursor.arrow).set()
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        guard canInteract() else { return }
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            zoom(to: isZoomed ? 1 : PreviewZoomGeometry.closer(size, in: bounds.size), around: point, animated: true)
            return
        }
        guard isZoomed else { window?.performDrag(with: event); return }
        panFrom = point
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let from = panFrom else { return }
        let point = convert(event.locationInWindow, from: nil)
        geometry.pan(by: CGPoint(x: point.x - from.x, y: point.y - from.y), size, in: bounds.size)
        panFrom = point
        place(animated: false)
    }
    override func mouseUp(with event: NSEvent) {
        panFrom = nil
        updateCursor()
    }
    override func magnify(with event: NSEvent) {
        guard canInteract() else { return }
        let point = convert(event.locationInWindow, from: nil)
        if event.phase == .began || pinch == nil { pinch = geometry.zoom }
        let asked = (pinch ?? 1) * (1 + event.magnification)
        pinch = asked
        let before = geometry.zoom
        geometry.zoom(to: asked, keeping: point, size, in: bounds.size, elastic: true)
        place(animated: false)
        if abs(geometry.zoom - before) > 0.0001 { showReadout() }
        if event.phase == .ended || event.phase == .cancelled {
            // Let go past a limit, it springs back to it.
            pinch = nil
            zoom(to: geometry.zoom, around: point, animated: true)
        }
        updateCursor()
    }
    override func smartMagnify(with event: NSEvent) {
        guard canInteract() else { return }
        let point = convert(event.locationInWindow, from: nil)
        zoom(to: isZoomed ? 1 : PreviewZoomGeometry.closer(size, in: bounds.size), around: point, animated: true)
    }
    override func scrollWheel(with event: NSEvent) {
        guard canInteract() else { return }
        let lines: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        if event.modifierFlags.contains(.command) {
            let factor = exp(event.scrollingDeltaY * lines * 0.006)
            zoom(to: geometry.zoom * factor, around: convert(event.locationInWindow, from: nil), animated: false)
            return
        }
        guard isZoomed else { super.scrollWheel(with: event); return }
        // The capture follows the fingers, the way a page does.
        geometry.pan(by: CGPoint(x: event.scrollingDeltaX * lines, y: -event.scrollingDeltaY * lines), size, in: bounds.size)
        place(animated: false)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? 2
        for tile in tiles { tile.contentsScale = scale }
    }
}
