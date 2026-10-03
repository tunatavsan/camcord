import AppKit
import CoreImage
import QuartzCore
import SwiftUI

/// Recent captures as a strip of tiles of one ratio, each whole over a muted blur of itself,
/// like the screenshot card. Drag sideways or scroll to move through them; a click opens
/// one; a drag up or down takes its file.
struct PanelRecentCarousel: NSViewRepresentable {
    let items: [CaptureItem]
    let images: [String: CGImage]
    let open: (CaptureItem) -> Void

    func makeNSView(context: Context) -> PanelCarouselView { PanelCarouselView(frame: .zero) }
    func updateNSView(_ view: PanelCarouselView, context: Context) {
        view.open = open
        view.update(items: items, images: images)
    }
}

@MainActor final class PanelCarouselView: NSView, NSDraggingSource {
    static let tile = CGSize(width: 136, height: 85)
    static let gap: CGFloat = 8
    var open: ((CaptureItem) -> Void)?
    private var items: [CaptureItem] = []
    private var tiles: [String: PanelCarouselTile] = [:]
    private let strip = CALayer()
    private let fade = CAGradientLayer()
    private var offset: CGFloat = 0
    private var tracking: NSTrackingArea?
    private var hovered: String?
    private enum Gesture { case none, undecided, scroll, file }
    private var gesture = Gesture.none
    private var press: (point: CGPoint, offset: CGFloat, item: CaptureItem?)?
    private var velocity: CGFloat = 0
    private var lastSample: (x: CGFloat, time: TimeInterval)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(strip)
        fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.mask = fade
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Recent captures"))
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func update(items: [CaptureItem], images: [String: CGImage]) {
        if items.map(\.id) != self.items.map(\.id) {
            self.items = items
            let ids = Set(items.map(\.id))
            for (id, tile) in tiles where !ids.contains(id) { tile.removeFromSuperlayer(); tiles[id] = nil }
            for item in items where tiles[item.id] == nil {
                let tile = PanelCarouselTile(item: item)
                tiles[item.id] = tile
                strip.addSublayer(tile)
            }
            offset = min(offset, maxOffset)
            needsLayout = true
        }
        for item in items { tiles[item.id]?.setImage(images[item.id]) }
        updateAccessibility()
    }

    private var contentWidth: CGFloat {
        guard !items.isEmpty else { return 0 }
        return CGFloat(items.count) * Self.tile.width + CGFloat(items.count - 1) * Self.gap
    }
    private var maxOffset: CGFloat { max(0, contentWidth - bounds.width) }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        strip.frame = CGRect(x: 0, y: 0, width: max(contentWidth, bounds.width), height: bounds.height)
        for (index, item) in items.enumerated() {
            tiles[item.id]?.frame = CGRect(x: CGFloat(index) * (Self.tile.width + Self.gap), y: (bounds.height - Self.tile.height) / 2,
                                           width: Self.tile.width, height: Self.tile.height)
        }
        fade.frame = bounds
        CATransaction.commit()
        apply(offset, animated: false)
    }

    // MARK: Motion

    private func apply(_ value: CGFloat, animated: Bool) {
        let from = (strip.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? -offset
        offset = value
        CATransaction.begin(); CATransaction.setDisableActions(true)
        strip.setValue(-value, forKeyPath: "transform.translation.x")
        if animated {
            let spring = CASpringAnimation.card(keyPath: "transform.translation.x", from: from, to: -value, response: 0.42, dampingRatio: 0.86)
            spring.preferFullRefreshRate(on: window?.screen)
            strip.add(spring, forKey: "carousel-settle")
        } else {
            strip.removeAnimation(forKey: "carousel-settle")
        }
        updateFade(for: value)
        CATransaction.commit()
    }

    /// Soft edges only where there is more to see.
    private func updateFade(for value: CGFloat) {
        let width = max(bounds.width, 1)
        let left = min(18, max(0, value)) / width, right = min(18, max(0, maxOffset - value)) / width
        fade.colors = [NSColor.black.withAlphaComponent(left > 0 ? 0 : 1).cgColor, NSColor.black.cgColor,
                       NSColor.black.cgColor, NSColor.black.withAlphaComponent(right > 0 ? 0 : 1).cgColor]
        fade.locations = [0, NSNumber(value: Double(max(left, 0.0001))), NSNumber(value: Double(1 - max(right, 0.0001))), 1]
    }

    /// Past either end the strip follows at a third of the distance, then springs back.
    private func rubberBanded(_ value: CGFloat) -> CGFloat {
        if value < 0 { return value / 3 }
        if value > maxOffset { return maxOffset + (value - maxOffset) / 3 }
        return value
    }

    /// Lands on a tile edge, carried a little by the release speed.
    private func settle(velocity: CGFloat) {
        let step = Self.tile.width + Self.gap
        let projected = offset - velocity * 0.16
        let target = min(maxOffset, max(0, (projected / step).rounded() * step))
        apply(target, animated: true)
    }

    override func scrollWheel(with event: NSEvent) {
        guard maxOffset > 0 else { super.scrollWheel(with: event); return }
        let precise = event.hasPreciseScrollingDeltas
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let distance = precise ? delta : delta * 12
        strip.removeAnimation(forKey: "carousel-settle")
        apply(rubberBanded(offset - distance), animated: false)
        let ended = event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended
        if ended || (!precise && event.phase == []) { if offset < 0 || offset > maxOffset { settle(velocity: 0) } }
        if event.momentumPhase == .ended { settle(velocity: 0) }
    }

    // MARK: Pointer

    private func item(at point: CGPoint) -> CaptureItem? {
        let x = point.x + offset
        let step = Self.tile.width + Self.gap
        let index = Int(floor(x / step))
        guard index >= 0, index < items.count, x - CGFloat(index) * step <= Self.tile.width,
              abs(point.y - bounds.midY) <= Self.tile.height / 2 else { return nil }
        return items[index]
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        strip.removeAnimation(forKey: "carousel-settle")
        let current = -((strip.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? -offset)
        apply(current, animated: false)
        press = (point, current, item(at: point))
        gesture = .undecided
        velocity = 0
        lastSample = (point.x, event.timestamp)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let press else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - press.point.x, dy = point.y - press.point.y
        if let last = lastSample, event.timestamp > last.time {
            let sample = (point.x - last.x) / (event.timestamp - last.time)
            velocity = velocity * 0.4 + sample * 0.6
        }
        lastSample = (point.x, event.timestamp)
        switch gesture {
        case .scroll: apply(rubberBanded(press.offset - dx), animated: false)
        case .undecided:
            guard hypot(dx, dy) >= 4 else { return }
            // Up or down takes the file; sideways moves the strip.
            if abs(dy) > abs(dx) * 1.2, let item = press.item {
                gesture = .file
                beginFileDrag(item, event: event)
            } else {
                gesture = .scroll
                setHovered(nil)
                apply(rubberBanded(press.offset - dx), animated: false)
            }
        case .file, .none: return
        }
    }
    override func mouseUp(with event: NSEvent) {
        defer { press = nil; gesture = .none }
        guard let press else { return }
        switch gesture {
        case .scroll: settle(velocity: velocity)
        case .undecided: if let item = press.item, item.id == self.item(at: convert(event.locationInWindow, from: nil))?.id { open?(item) }
        default: break
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        tracking = area; addTrackingArea(area)
    }
    override func mouseMoved(with event: NSEvent) {
        guard gesture == .none else { return }
        setHovered(item(at: convert(event.locationInWindow, from: nil))?.id)
    }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }
    private func setHovered(_ id: String?) {
        guard id != hovered else { return }
        if let hovered { tiles[hovered]?.setHovered(false, screen: window?.screen) }
        hovered = id
        if let id { tiles[id]?.setHovered(true, screen: window?.screen) }
        toolTip = id.flatMap { id in items.first { $0.id == id }?.title }
    }

    // MARK: File drag

    private func beginFileDrag(_ item: CaptureItem, event: NSEvent) {
        guard let url = try? PanelCaptureDrag(item: item)?.validatedURL() else { return }
        let drag = NSDraggingItem(pasteboardWriter: url as NSURL)
        let index = items.firstIndex { $0.id == item.id } ?? 0
        let tileFrame = CGRect(x: CGFloat(index) * (Self.tile.width + Self.gap) - offset, y: (bounds.height - Self.tile.height) / 2,
                               width: Self.tile.width, height: Self.tile.height)
        drag.setDraggingFrame(tileFrame, contents: tiles[item.id]?.snapshot())
        beginDraggingSession(with: [drag], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    // MARK: Accessibility

    private func updateAccessibility() {
        setAccessibilityChildren(items.map { item in
            let element = PanelCarouselAccessibilityItem(item: item) { [weak self] in self?.open?(item) }
            element.setAccessibilityParent(self)
            return element
        })
    }
}

private final class PanelCarouselAccessibilityItem: NSAccessibilityElement {
    private let press: () -> Void
    init(item: CaptureItem, press: @escaping () -> Void) {
        self.press = press
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)
        setAccessibilityHelp(String(localized: "Opens the capture; drag to use its file", comment: "Accessibility: recent capture tile"))
    }
    override func accessibilityPerformPress() -> Bool { press(); return true }
}

/// One tile: the capture whole over its blur, a play mark for recordings, its age in a pill.
final class PanelCarouselTile: CALayer {
    private let fill = CALayer()
    private let dim = CALayer()
    private let picture = CALayer()
    private let play = CALayer()
    private let age = CATextLayer()
    private let ageBack = CALayer()
    private var image: CGImage?
    private static let context = CIContext(options: [.cacheIntermediates: false])

    @MainActor init(item: CaptureItem) {
        super.init()
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        cornerRadius = 10
        cornerCurve = .continuous
        masksToBounds = true
        backgroundColor = Theme.Palette.well.ns.cgColor
        fill.contentsGravity = .resizeAspectFill
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        picture.contentsGravity = .resizeAspect
        picture.shadowColor = NSColor.black.cgColor
        picture.shadowOpacity = 0.35
        picture.shadowRadius = 3
        picture.shadowOffset = CGSize(width: 0, height: 1)
        for layer in [fill, dim, picture] { addSublayer(layer) }
        if item.kind == .recording {
            play.contents = InkCenteredSymbol.render("play.fill", pointSize: 12, weight: .bold, canvas: 28, scale: scale, color: .white)
            play.contentsScale = scale
            play.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
            play.cornerRadius = 14
            play.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
            play.borderWidth = 1
            addSublayer(play)
        }
        ageBack.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        ageBack.cornerRadius = 8
        age.string = PanelRelativeDate.string(for: item.createdAt)
        age.font = Theme.Font.ns.mono(10, weight: .medium)
        age.fontSize = 10
        age.foregroundColor = NSColor.white.cgColor
        age.alignmentMode = .center
        age.contentsScale = scale
        addSublayer(ageBack)
        addSublayer(age)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }

    @MainActor func setImage(_ image: CGImage?) {
        guard image !== self.image else { return }
        self.image = image
        picture.contents = image
        guard let image else { fill.contents = nil; return }
        Task { [weak self] in
            let blurred = await Task.detached(priority: .utility) { Self.blurred(image) }.value
            guard let self, self.image === image else { return }
            CATransaction.begin(); CATransaction.setAnimationDuration(0.18)
            self.fill.contents = blurred
            CATransaction.commit()
        }
    }

    private static func blurred(_ image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        let output = source.clampedToExtent().applyingGaussianBlur(sigma: 10)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.75])
            .cropped(to: source.extent)
        return context.createCGImage(output, from: source.extent)
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds; dim.frame = bounds
        picture.frame = bounds.insetBy(dx: 3, dy: 3)
        play.frame = CGRect(x: bounds.midX - 14, y: bounds.midY - 14, width: 28, height: 28)
        let text = (age.string as? String) ?? ""
        let width = ceil(NSAttributedString(string: text, attributes: [.font: Theme.Font.ns.mono(10, weight: .medium)]).size().width) + 12
        ageBack.frame = CGRect(x: 6, y: bounds.maxY - 6 - 16, width: width, height: 16)
        age.frame = CGRect(x: 6, y: bounds.maxY - 6 - 15, width: width, height: 14)
        CATransaction.commit()
    }

    /// Hover lifts the tile and lights its edge.
    @MainActor func setHovered(_ hovered: Bool, screen: NSScreen?) {
        let from = presentation()?.transform ?? transform
        let to = hovered ? CATransform3DMakeScale(1.04, 1.04, 1) : CATransform3DIdentity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        transform = to
        borderWidth = hovered ? 1 : 0
        borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        let spring = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: to),
                                            response: 0.32, dampingRatio: hovered ? 0.62 : 0.85)
        spring.preferFullRefreshRate(on: screen)
        add(spring, forKey: "tile-hover")
        CATransaction.commit()
    }

    @MainActor func snapshot() -> NSImage? {
        guard let image else { return nil }
        return NSImage(cgImage: image, size: bounds.size)
    }
}
