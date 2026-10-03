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
    /// What a right click offers for one capture.
    var menu: (CaptureItem) -> [PanelHoverInfo.MenuAction] = { _ in [] }

    func makeNSView(context: Context) -> PanelCarouselView { PanelCarouselView(frame: .zero) }
    func updateNSView(_ view: PanelCarouselView, context: Context) {
        view.open = open
        view.captureMenu = menu
        view.update(items: items, images: images)
    }
}

@MainActor final class PanelCarouselView: NSView, NSDraggingSource {
    static let tile = CGSize(width: 136, height: 85)
    static let gap: CGFloat = 8
    var open: ((CaptureItem) -> Void)?
    var captureMenu: ((CaptureItem) -> [PanelHoverInfo.MenuAction])?
    private var items: [CaptureItem] = []
    private var tiles: [String: PanelCarouselTileView] = [:]
    /// Tiles live in one view whose layer slides; glass needs views, motion needs one layer.
    private let stripView = PanelCarouselStrip()
    private var strip: CALayer { stripView.layer! }
    private let fade = CAGradientLayer()
    private var offset: CGFloat = 0
    private var tracking: NSTrackingArea?
    private var hovered: String?
    private let info = PanelHoverInfo()
    private enum Gesture { case none, undecided, scroll, file }
    private var gesture = Gesture.none
    private var press: (point: CGPoint, offset: CGFloat, item: CaptureItem?)?
    private var velocity: CGFloat = 0
    private var lastSample: (x: CGFloat, time: TimeInterval)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(stripView)
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
            for (id, tile) in tiles where !ids.contains(id) { tile.removeFromSuperview(); tiles[id] = nil }
            for item in items where tiles[item.id] == nil {
                let tile = PanelCarouselTileView(item: item)
                tiles[item.id] = tile
                stripView.addSubview(tile)
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
        let stripFrame = CGRect(x: 0, y: 0, width: max(contentWidth, bounds.width), height: bounds.height)
        if stripView.frame != stripFrame { stripView.frame = stripFrame }
        for (index, item) in items.enumerated() {
            let frame = CGRect(x: CGFloat(index) * (Self.tile.width + Self.gap), y: (bounds.height - Self.tile.height) / 2 + 2,
                               width: Self.tile.width, height: Self.tile.height)
            if tiles[item.id]?.frame != frame { tiles[item.id]?.frame = frame }
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

    /// The strip owns every press: tiles and their glass never take the mouse.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
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
    /// A right click grows the hover note into the capture's menu.
    override func rightMouseDown(with event: NSEvent) {
        guard let item = item(at: convert(event.locationInWindow, from: nil)),
              let actions = captureMenu?(item), !actions.isEmpty else { return }
        setHovered(item.id)
        info.expandMenu(for: item, actions: actions, from: self)
    }

    override func mouseMoved(with event: NSEvent) {
        guard gesture == .none, !info.isMenuOpen else { return }
        setHovered(item(at: convert(event.locationInWindow, from: nil))?.id)
        if hovered != nil { info.move(to: NSEvent.mouseLocation) }
    }
    override func mouseExited(with event: NSEvent) { if !info.isMenuOpen { setHovered(nil) } }
    private func setHovered(_ id: String?) {
        guard id != hovered, !info.isMenuOpen else { return }
        if let hovered { tiles[hovered]?.setHovered(false, screen: window?.screen) }
        hovered = id
        if let id { tiles[id]?.setHovered(true, screen: window?.screen) }
        if let item = id.flatMap({ id in items.first { $0.id == id } }) { info.show(item, from: self) } else { info.hide() }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { info.hide() }
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

private final class PanelCarouselStrip: NSView {
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
}

/// A tile as a view: its layer draws the capture, and a recording carries a glass play button.
@MainActor final class PanelCarouselTileView: NSView {
    private let item: CaptureItem
    private let play: PanelPlayChip?
    init(item: CaptureItem) {
        self.item = item
        play = item.kind == .recording ? PanelPlayChip(frame: .zero) : nil
        super.init(frame: .zero)
        wantsLayer = true
        // AppKit owns a view layer's clipping: ask it, or the tile's corners stay square.
        clipsToBounds = true
        if let play { addSubview(play) }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func makeBackingLayer() -> CALayer { PanelCarouselTile(item: item) }
    private var tile: PanelCarouselTile? { layer as? PanelCarouselTile }
    func setImage(_ image: CGImage?) { tile?.setImage(image) }
    /// Hover lifts the tile a little, like every control in the panel, and brightens it.
    func setHovered(_ hovered: Bool, screen: NSScreen?) {
        tile?.setHovered(hovered, screen: screen)
        play?.setVeil(active: hovered)
        guard let layer else { return }
        let lifted = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-bounds.width / 2, -bounds.height / 2, 0), CATransform3DMakeScale(1.03, 1.03, 1)),
            CATransform3DMakeTranslation(bounds.width / 2, bounds.height / 2 - 3, 0))
        let from = layer.presentation()?.transform ?? layer.transform
        let to = hovered ? lifted : CATransform3DIdentity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = to
        let spring = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: to),
                                            response: 0.32, dampingRatio: hovered ? 0.62 : 0.85)
        spring.preferFullRefreshRate(on: screen)
        layer.add(spring, forKey: "tile-lift")
        CATransaction.commit()
    }
    func snapshot() -> NSImage? { tile?.snapshot() }
    override func layout() {
        super.layout()
        layer?.cornerRadius = Theme.Radius.thumb
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        play?.frame = CGRect(x: bounds.midX - 15, y: bounds.midY - 15, width: 30, height: 30)
    }
}

/// The play mark of a recording, in the card's Liquid Glass.
@MainActor final class PanelPlayChip: ScreenshotCardChip {
    private let icon = CALayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        icon.contents = InkCenteredSymbol.render("play.fill", pointSize: 12, weight: .bold, canvas: 30, scale: scale, color: .white)
        icon.contentsScale = scale
        clip.addSublayer(icon)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        icon.frame = bounds
        CATransaction.commit()
    }
}

/// One tile's drawing: the capture whole over its blur and its age in a pill.
final class PanelCarouselTile: CALayer {
    private let fill = CALayer()
    private let dim = CALayer()
    private let picture = CALayer()
    private let age = CATextLayer()
    private let ageBack = CALayer()
    private var image: CGImage?
    private static let context = CIContext(options: [.cacheIntermediates: false])

    @MainActor init(item: CaptureItem) {
        super.init()
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        cornerRadius = Theme.Radius.thumb
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
        let text = (age.string as? String) ?? ""
        let width = ceil(NSAttributedString(string: text, attributes: [.font: Theme.Font.ns.mono(10, weight: .medium)]).size().width) + 12
        ageBack.frame = CGRect(x: 6, y: bounds.maxY - 6 - 16, width: width, height: 16)
        age.frame = CGRect(x: 6, y: bounds.maxY - 6 - 15, width: width, height: 14)
        CATransaction.commit()
    }

    /// Hover brightens the capture.
    @MainActor func setHovered(_ hovered: Bool, screen: NSScreen?) {
        CATransaction.begin(); CATransaction.setAnimationDuration(0.16)
        dim.opacity = hovered ? 0.35 : 1
        CATransaction.commit()
    }

    @MainActor func snapshot() -> NSImage? {
        guard let image else { return nil }
        return NSImage(cgImage: image, size: bounds.size)
    }
}

/// A small glass note that follows the pointer over the strip on a spring: the capture's
/// name and what it is, at once, instead of the system's delayed tooltip. A right click grows
/// the same glass into the capture's menu.
@MainActor final class PanelHoverInfo {
    struct MenuAction {
        let title: String
        let symbol: String
        var destructive = false
        let perform: @MainActor (NSView) -> Void
    }
    private let panel: InfoPanel
    private let content = InfoContent()
    /// Holds the tray and its glass at the size they have now; the menu scales them rather
    /// than resizing them, so the glass keeps the note's own look as it grows.
    private let holder = NSView()
    private let glass = NSGlassEffectView()
    private lazy var tray = TraySurface(content: InfoWell(glass: glass), shadowRadius: 6, cornerRadius: 12 + Self.ring)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var rows: [InfoRow] = []
    private weak var host: NSView?
    private var link: CADisplayLink?
    private var proxy: PanelHoverInfoProxy?
    private var position: CGPoint = .zero
    private var velocity: CGPoint = .zero
    private var target: CGPoint = .zero
    private var lastTick: CFTimeInterval?
    private(set) var itemID: String?
    private(set) var isMenuOpen = false
    private var noteSize: CGSize = .zero
    private var monitors: [Any] = []
    private var watch: Timer?
    /// The note rides above and to the right of the pointer.
    private static let offset = CGPoint(x: 14, y: 16)
    private static let menuWidth: CGFloat = 228
    private static let rowHeight: CGFloat = 30
    private static let header: CGFloat = 44
    /// The tray shows this much around the glass, like the panel's cells on its tray.
    fileprivate static let ring: CGFloat = 4
    /// Room around the tray inside the panel for its shadow.
    private static let margin: CGFloat = 16

    init() {
        panel = InfoPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        content.wantsLayer = true
        glass.style = .regular
        glass.cornerRadius = 12
        titleLabel.font = Theme.Font.ns.text(12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = Theme.Font.ns.mono(10.5, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, detailLabel] { label.isSelectable = false }
        holder.wantsLayer = true
        holder.addSubview(tray)
        content.addSubview(holder)
        content.addSubview(titleLabel)
        content.addSubview(detailLabel)
        panel.contentView = content
    }

    func show(_ item: CaptureItem, from host: NSView) {
        guard !isMenuOpen else { return }
        self.host = host
        let mouse = NSEvent.mouseLocation
        if itemID == nil {
            position = CGPoint(x: mouse.x + Self.offset.x, y: mouse.y + Self.offset.y)
            velocity = .zero
        }
        itemID = item.id
        titleLabel.stringValue = item.title
        detailLabel.stringValue = Self.details(item)
        let width = min(300, max(titleLabel.intrinsicContentSize.width, detailLabel.intrinsicContentSize.width) + 32)
        noteSize = CGSize(width: ceil(width), height: Self.header)
        panel.setContentSize(CGSize(width: noteSize.width + 2 * Self.margin, height: noteSize.height + 2 * Self.margin))
        layoutNote(in: CGRect(origin: CGPoint(x: Self.margin, y: Self.margin), size: noteSize))
        move(to: mouse)
        if !panel.isVisible {
            place()
            panel.orderFrontRegardless()
            if let layer = content.layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let pop = CASpringAnimation.card(keyPath: "transform.scale", from: 0.92, to: 1, response: 0.3, dampingRatio: 0.7)
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.12
                layer.add(pop, forKey: "info-pop"); layer.add(fade, forKey: "info-fade")
            }
        }
        startFollowing()
    }

    func move(to mouse: CGPoint) {
        guard !isMenuOpen else { return }
        target = CGPoint(x: mouse.x + Self.offset.x, y: mouse.y + Self.offset.y)
        startFollowing()
    }

    func hide() {
        itemID = nil
        closeMenuState()
        stopFollowing()
        resetMotion()
        panel.orderOut(nil)
    }

    /// The menu folds back the way it opened: the rows go, the glass shrinks to the note and
    /// fades with it.
    func closeMenu() {
        guard isMenuOpen, let holderLayer = holder.layer, let contentLayer = content.layer,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { hide(); return }
        removeMenuMonitors()
        panel.ignoresMouseEvents = true
        let folded = foldedTransform
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { if self?.isMenuOpen == true { self?.hide() } }
        }
        for row in rows {
            row.layer?.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.1
            row.layer?.add(fade, forKey: "row-out")
        }
        let from = holderLayer.presentation()?.transform ?? holderLayer.transform
        holderLayer.transform = folded
        let fold = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: folded),
                                          response: 0.28, dampingRatio: 1)
        fold.duration = 0.22
        fold.preferFullRefreshRate(on: panel.screen)
        holderLayer.add(fold, forKey: "menu-fold")
        contentLayer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 0.08; fade.duration = 0.14; fade.fillMode = .backwards
        contentLayer.add(fade, forKey: "menu-fade")
        CATransaction.commit()
    }

    /// The note's rectangle inside the menu, as a transform of the menu-sized glass.
    private var foldedTransform: CATransform3D = CATransform3DIdentity
    private func resetMotion() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        holder.layer?.removeAllAnimations(); holder.layer?.transform = CATransform3DIdentity
        content.layer?.removeAllAnimations(); content.layer?.opacity = 1
        CATransaction.commit()
    }

    /// The note grows into the capture's menu where it stands: the glass springs from the
    /// note's size to the menu's, and the rows arrive one after another.
    func expandMenu(for item: CaptureItem, actions: [MenuAction], from host: NSView) {
        if itemID != item.id || !panel.isVisible { show(item, from: host) }
        stopFollowing()
        resetMotion()
        isMenuOpen = true
        let note = panel.frame.insetBy(dx: Self.margin, dy: Self.margin)
        let size = CGSize(width: max(Self.menuWidth, noteSize.width), height: Self.header + CGFloat(actions.count) * Self.rowHeight + 10)
        var frame = CGRect(x: note.minX, y: note.maxY - size.height, width: size.width, height: size.height)
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX + 4), visible.maxX - size.width - 4)
            frame.origin.y = max(frame.minY, visible.minY + 4)
        }
        panel.setFrame(frame.insetBy(dx: -Self.margin, dy: -Self.margin), display: false)
        panel.ignoresMouseEvents = false
        content.frame = CGRect(origin: .zero, size: panel.frame.size)
        rows.forEach { $0.removeFromSuperview() }
        rows = actions.enumerated().map { index, action in
            let row = InfoRow(action: action) { [weak self] row in
                self?.hide()
                action.perform(row)
            }
            let inset = Self.ring + 4
            row.frame = CGRect(x: Self.margin + inset, y: Self.margin + Self.header + CGFloat(index) * Self.rowHeight,
                               width: size.width - 2 * inset, height: Self.rowHeight)
            content.addSubview(row)
            return row
        }
        // The note's frame, inside the menu: its top-left corner stays where it was.
        let start = CGRect(x: note.minX - frame.minX, y: frame.maxY - note.maxY, width: note.width, height: note.height)
        let full = CGRect(origin: .zero, size: size)
        layoutNote(in: full.offsetBy(dx: Self.margin, dy: Self.margin))
        // The glass is menu-sized at once and grows out of the note's rectangle by a transform.
        foldedTransform = CATransform3DConcat(CATransform3DMakeScale(start.width / full.width, start.height / full.height, 1),
                                              CATransform3DMakeTranslation(start.minX, start.minY, 0))
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduce, let holderLayer = holder.layer {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            holderLayer.transform = CATransform3DIdentity
            let grow = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: foldedTransform),
                                              to: NSValue(caTransform3D: CATransform3DIdentity), response: 0.36, dampingRatio: 0.82)
            grow.preferFullRefreshRate(on: panel.screen)
            holderLayer.add(grow, forKey: "menu-grow")
            CATransaction.commit()
        }
        for (index, row) in rows.enumerated() {
            row.arrive(delay: reduce ? 0 : 0.06 + Double(index) * 0.03, reduceMotion: reduce, screen: panel.screen)
        }
        installMenuMonitors()
    }

    private func layoutNote(in bounds: CGRect) {
        holder.frame = bounds
        tray.frame = holder.bounds
        titleLabel.frame = CGRect(x: bounds.minX + 13, y: bounds.minY + 6, width: bounds.width - 24, height: 16)
        detailLabel.frame = CGRect(x: bounds.minX + 13, y: bounds.minY + 23, width: bounds.width - 24, height: 14)
    }

    /// A click elsewhere, Esc, or the strip's panel leaving puts the menu away.
    private func installMenuMonitors() {
        removeMenuMonitors()
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.closeMenu(); return nil }
                return event
            }
            guard event.window !== self.panel else { return event }
            self.closeMenu()
            // A second right click closes the menu; it never opens it again at once.
            return event.type == .rightMouseDown ? nil : event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closeMenu() }
        }) { monitors.append(global) }
        watch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.host?.window?.isVisible != true else { return }
                self.hide()
            }
        }
    }
    private func removeMenuMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        watch?.invalidate(); watch = nil
    }
    private func closeMenuState() {
        guard isMenuOpen else { return }
        isMenuOpen = false
        removeMenuMonitors()
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        panel.ignoresMouseEvents = true
    }

    static func details(_ item: CaptureItem) -> String {
        let kind: String
        switch item.kind {
        case .screenshot: kind = String(localized: "Screenshot")
        case .scrollCapture: kind = String(localized: "Scroll capture")
        case .recording: kind = String(localized: "Recording")
        }
        var parts = [kind]
        if let duration = item.duration, duration.isFinite {
            let total = Int(duration.rounded())
            parts.append(total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
                                       : String(format: "%d:%02d", total / 60, total % 60))
        }
        if let pixels = item.pixelSize, pixels.width > 0 { parts.append("\(Int(pixels.width))×\(Int(pixels.height))") }
        parts.append(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
        return parts.joined(separator: " · ")
    }

    // MARK: Spring follow at the display's rate

    private func startFollowing() {
        guard link == nil, !isMenuOpen else { return }
        let proxy = PanelHoverInfoProxy(owner: self)
        let link = content.displayLink(target: proxy, selector: #selector(PanelHoverInfoProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.proxy = proxy; self.link = link; lastTick = nil
    }
    private func stopFollowing() {
        link?.invalidate(); link = nil; proxy = nil; lastTick = nil
    }
    fileprivate func tick(_ link: CADisplayLink) {
        // The strip's panel closing takes the note with it.
        guard host?.window?.isVisible == true else { hide(); return }
        let dt = min(max(link.timestamp - (lastTick ?? link.timestamp - 1.0 / 120), 0), 1.0 / 30)
        lastTick = link.timestamp
        let stiffness = pow(2 * Double.pi / 0.24, 2), damping = 2 * 0.82 * sqrt(stiffness)
        let steps = 4
        for _ in 0..<steps {
            let h = dt / Double(steps)
            velocity.x += (stiffness * (target.x - position.x) - damping * velocity.x) * h
            velocity.y += (stiffness * (target.y - position.y) - damping * velocity.y) * h
            position.x += velocity.x * h
            position.y += velocity.y * h
        }
        place()
        if hypot(target.x - position.x, target.y - position.y) < 0.2, hypot(velocity.x, velocity.y) < 2 {
            position = target; place(); stopFollowing()
        }
    }
    /// `position` is the note's own corner; the panel stands a shadow's margin around it.
    private func place() {
        var origin = position
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(target) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let note = panel.frame.insetBy(dx: Self.margin, dy: Self.margin).size
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - note.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - note.height - 4)
        }
        panel.setFrameOrigin(CGPoint(x: origin.x.rounded() - Self.margin, y: origin.y.rounded() - Self.margin))
    }
}

/// The note and menu window: it takes clicks while it is a menu, never the app's activation.
private final class InfoPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

private final class InfoContent: NSView {
    override var isFlipped: Bool { true }
}

/// The note's glass, a ring in from the tray's edge.
private final class InfoWell: NSView {
    private let glass: NSView
    init(glass: NSView) {
        self.glass = glass
        super.init(frame: .zero)
        addSubview(glass)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        glass.frame = bounds.insetBy(dx: PanelHoverInfo.ring, dy: PanelHoverInfo.ring)
    }
}

/// One menu row: a symbol and its title; hovered, a soft band appears and the symbol swells.
@MainActor private final class InfoRow: NSView {
    private let action: PanelHoverInfo.MenuAction
    private let chosen: (InfoRow) -> Void
    private let band = CALayer()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    init(action: PanelHoverInfo.MenuAction, chosen: @escaping (InfoRow) -> Void) {
        self.action = action
        self.chosen = chosen
        super.init(frame: .zero)
        wantsLayer = true
        band.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
        band.cornerRadius = 8
        band.cornerCurve = .continuous
        band.opacity = 0
        layer?.addSublayer(band)
        let colour: NSColor = action.destructive ? .systemRed : .labelColor
        icon.image = InkCenteredSymbol.template(action.symbol, pointSize: 13, canvas: 20)
        icon.contentTintColor = colour
        icon.wantsLayer = true
        label.stringValue = action.title
        label.font = Theme.Font.ns.text(13, weight: .medium)
        label.textColor = colour
        label.isSelectable = false
        addSubview(icon); addSubview(label)
        layer?.opacity = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(action.title)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        band.frame = bounds.insetBy(dx: 2, dy: 1)
        CATransaction.commit()
        icon.frame = CGRect(x: 10, y: (bounds.height - 20) / 2, width: 20, height: 20)
        label.frame = CGRect(x: 38, y: (bounds.height - 17) / 2, width: bounds.width - 46, height: 17)
    }
    func arrive(delay: CFTimeInterval, reduceMotion: Bool, screen: NSScreen?) {
        guard let layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
        fade.duration = reduceMotion ? Theme.Motion.Duration.reduced : 0.16
        fade.beginTime = CACurrentMediaTime() + delay; fade.fillMode = .backwards
        layer.add(fade, forKey: "row-fade")
        if !reduceMotion {
            let slide = CASpringAnimation.card(keyPath: "transform.translation.y", from: -5, to: 0, response: 0.34, dampingRatio: 0.75)
            slide.beginTime = CACurrentMediaTime() + delay; slide.fillMode = .backwards
            slide.preferFullRefreshRate(on: screen)
            layer.add(slide, forKey: "row-slide")
        }
        CATransaction.commit()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        tracking = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { chosen(self) }
    }
    override func accessibilityPerformPress() -> Bool { chosen(self); return true }
    private func setHovered(_ hovered: Bool) {
        CATransaction.begin(); CATransaction.setAnimationDuration(0.12)
        band.opacity = hovered ? 1 : 0
        CATransaction.commit()
        guard let iconLayer = icon.layer else { return }
        let size = icon.bounds.size
        let swell = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0),
                                                            CATransform3DMakeScale(1.14, 1.14, 1)),
                                        CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0))
        let from = iconLayer.presentation()?.transform ?? iconLayer.transform
        CATransaction.begin(); CATransaction.setDisableActions(true)
        iconLayer.transform = hovered ? swell : CATransform3DIdentity
        let spring = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: from),
                                            to: NSValue(caTransform3D: iconLayer.transform), response: 0.3, dampingRatio: hovered ? 0.55 : 0.8)
        iconLayer.add(spring, forKey: "row-swell")
        CATransaction.commit()
    }
}

private final class PanelHoverInfoProxy: NSObject {
    weak var owner: PanelHoverInfo?
    init(owner: PanelHoverInfo) { self.owner = owner }
    @MainActor @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
}
