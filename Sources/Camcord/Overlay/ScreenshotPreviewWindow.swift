import AppKit
import Combine
import ImageIO
import QuartzCore

/// The preview's first size: the whole capture, never magnified. A preview is there to look
/// closely, so it takes most of the screen; a pin floats beside the work, so it stays modest and
/// opens where its card was.
struct ScreenshotPreviewGeometry {
    static let ring: CGFloat = 8
    static let shadowInset: CGFloat = 32
    /// A pin's largest first size.
    static let maximumWell = CGSize(width: 520, height: 360)
    static let minimumWell = CGSize(width: 300, height: 190)
    /// How much of the screen a preview may take.
    static let previewShare: CGFloat = 0.86
    let well: CGSize
    let frame: CGRect
    init(pointSize: CGSize, visible: CGRect, pinned: Bool = true, anchor: CGRect? = nil) {
        let room = pinned
            ? CGSize(width: min(Self.maximumWell.width, visible.width * 0.6), height: min(Self.maximumWell.height, visible.height * 0.6))
            : CGSize(width: visible.width * Self.previewShare - 2 * (Self.ring + Self.shadowInset),
                     height: visible.height * Self.previewShare - 2 * (Self.ring + Self.shadowInset))
        let valid = pointSize.width.isFinite && pointSize.height.isFinite && pointSize.width > 0 && pointSize.height > 0
        let scale = valid ? min(1, room.width / pointSize.width, room.height / pointSize.height) : 0
        let fitted = CGSize(width: (pointSize.width * scale).rounded(), height: (pointSize.height * scale).rounded())
        well = CGSize(width: max(Self.minimumWell.width, fitted.width), height: max(Self.minimumWell.height, fitted.height))
        let outset = 2 * (Self.ring + Self.shadowInset)
        let size = CGSize(width: well.width + outset, height: well.height + outset)
        // A pin grows out of its card, kept on the screen; the shadow margin may leave it.
        let centre = pinned ? anchor.map { CGPoint(x: $0.midX, y: $0.midY) } : nil
        let wanted = centre ?? CGPoint(x: visible.midX, y: visible.midY)
        let margin = Self.shadowInset
        let x = min(max(wanted.x - size.width / 2, visible.minX - margin), visible.maxX + margin - size.width)
        let y = min(max(wanted.y - size.height / 2, visible.minY - margin), visible.maxY + margin - size.height)
        frame = CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
}

/// Lightweight looks at screenshots. An unpinned preview goes away with Esc, its close button
/// or a click elsewhere; a pinned one stays in front until it is closed. Pinned previews are
/// the app's pins: there is no other pin window.
@MainActor final class ScreenshotPreviewWindow {
    var onEdit: (@MainActor (CapturedScreenshot) -> Void)?
    private(set) var sessions: [ScreenshotPreviewSession] = []
    var isVisible: Bool { !sessions.isEmpty }

    /// - Parameters: pinned opens it as a pin; from is the card it grows out of, in screen points.
    func show(_ capture: CapturedScreenshot, operations: ScreenshotCardModel.Operations, on visible: CGRect,
              claim: (@MainActor () -> (@MainActor () -> Bool))?, pinned: Bool = false, from: CGRect? = nil) {
        // A new preview replaces the unpinned one; pinned previews stay.
        for session in sessions where !session.pinned { session.close(animated: false) }
        let session = ScreenshotPreviewSession(capture: capture, operations: operations, visible: visible, claim: claim,
                                               canEdit: onEdit != nil, pinned: pinned, from: from)
        session.onEdit = { [weak self] in self?.onEdit?(capture) }
        session.onClosed = { [weak self, weak session] in self?.sessions.removeAll { $0 === session } }
        sessions.append(session)
        session.present(from: from)
    }

    func closeAll() { for session in sessions { session.close(animated: false) } }
}

/// One preview window and its own model, so a dismissed card never takes it down.
@MainActor final class ScreenshotPreviewSession: NSObject, NSWindowDelegate {
    var onEdit: (@MainActor () -> Void)?
    var onClosed: (@MainActor () -> Void)?
    private(set) var pinned = false
    let panel: NSPanel
    let host: ScreenshotPreviewHost
    private let model: ScreenshotCardModel
    private var closed = false

    init(capture: CapturedScreenshot, operations: ScreenshotCardModel.Operations, visible: CGRect,
         claim: (@MainActor () -> (@MainActor () -> Bool))?, canEdit: Bool, pinned: Bool = false, from: CGRect? = nil) {
        model = ScreenshotCardModel(capture: capture, operations: operations)
        model.claimClipboardPublication = claim
        self.pinned = pinned
        let geometry = ScreenshotPreviewGeometry(pointSize: capture.pointSize, visible: visible, pinned: pinned, anchor: from)
        host = ScreenshotPreviewHost(model: model, wellSize: geometry.well, canEdit: canEdit)
        panel = ScreenshotPreviewPanel(contentRect: geometry.frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.contentView = host
        panel.delegate = self
        host.onClose = { [weak self] in self?.close(animated: true) }
        host.onEdit = { [weak self] in
            guard let self else { return }
            self.onEdit?()
            if !self.pinned { self.close(animated: false) }
        }
        host.onPin = { [weak self] in
            guard let self else { return }
            self.pinned.toggle()
            self.host.setPinned(self.pinned)
        }
        host.setPinned(pinned)
    }

    func present(from card: CGRect? = nil) {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(host)
        host.animateIn(from: card)
    }

    func close(animated: Bool) {
        guard !closed else { return }
        closed = true
        model.invalidate()
        host.invalidate()
        panel.delegate = nil
        let panel = panel
        if animated { host.animateOut { panel.orderOut(nil) } } else { panel.orderOut(nil) }
        onClosed?()
    }

    func windowDidResignKey(_ notification: Notification) {
        // A click elsewhere puts an unpinned preview away, unless its own share sheet took the focus.
        guard !pinned, !host.isSharing, !host.isResizing else { return }
        close(animated: true)
    }
}

private final class ScreenshotPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The preview's content: the capture's well on the tray. Hover shows Edit, Copy, Preview (a pin)
/// or Pin (a passing preview), and Share; the capture moves the window; the tray's edge resizes it
/// at the capture's own ratio. It arrives lit by the glass light.
@MainActor final class ScreenshotPreviewHost: NSView {
    var onClose: (@MainActor () -> Void)?
    var onEdit: (@MainActor () -> Void)?
    var onPin: (@MainActor () -> Void)?
    private(set) var isSharing = false
    private(set) var isResizing = false
    private let model: ScreenshotCardModel
    let well: ScreenshotCardWell
    private let surface: TraySurface
    private let share: ScreenshotCardShare
    private let canEdit: Bool
    private var observers: Set<AnyCancellable> = []
    private var tracking: NSTrackingArea?
    private var hovering = false
    private var alive = true
    private var copied = false
    private var pinned = false
    private var resize: (edges: Edges, frame: CGRect, mouse: CGPoint)?
    /// The capture, zoomable; it stands in for the well's still image.
    let zoom: ScreenshotPreviewZoom
    /// The glass light that draws around the tray as it arrives.
    private let ring = LitRing(sheen: .none, flarePeak: 0.8)
    /// The camera's buttons over the capture: the × at the top, a resize chip in each corner.
    private let chrome = PinChrome()
    private var surfaceRect: CGRect { bounds.insetBy(dx: ScreenshotPreviewGeometry.shadowInset, dy: ScreenshotPreviewGeometry.shadowInset) }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), bottom = Edges(rawValue: 4), top = Edges(rawValue: 8)
    }

    init(model: ScreenshotCardModel, wellSize: CGSize, canEdit: Bool) {
        self.model = model
        self.canEdit = canEdit
        well = ScreenshotCardWell(capture: model.capture, size: wellSize)
        zoom = ScreenshotPreviewZoom(image: model.capture.image, pointSize: model.capture.pointSize)
        surface = TraySurface(content: ScreenshotPreviewContent(well: well), shadowRadius: 14)
        share = ScreenshotCardShare(model: model, pause: { _, _ in })
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(surface)
        // Inside the tray's own layer, so it grows with the tray as it arrives.
        ring.layer.zPosition = 20
        ring.layer.opacity = 0
        surface.layer?.addSublayer(ring.layer)
        share.pause = { [weak self] reason, active in if reason == .sharing { self?.isSharing = active } }
        let image = well.imageView
        image.export = model.export
        image.movesWindow = true
        image.canInteract = { [weak model] in model?.isAlive == true }
        image.setAccessibilityHelp(nil)
        image.isHidden = true
        zoom.frame = well.bounds
        zoom.autoresizingMask = [.width, .height]
        zoom.canInteract = { [weak model] in model?.isAlive == true }
        zoom.setAccessibilityHelp(String(localized: "Pinch or double-click to zoom; drag to move around"))
        well.addSubview(zoom, positioned: .above, relativeTo: image)
        // The camera's × and resize corners stand in for the card's corner ×; the actions keep
        // to the middle so the corners stay free to resize.
        well.closeButton.isHidden = true
        well.band.centersButtons = true
        chrome.frame = well.bounds
        chrome.autoresizingMask = [.width, .height]
        chrome.outlineRadius = Theme.Radius.well
        chrome.onClose = { [weak self] in self?.onClose?() }
        chrome.onResize = { [weak self] corner, phase in
            guard let self else { return }
            switch phase {
            case .began: self.beginResize(Self.edges(for: corner))
            case .changed: self.continueResize()
            case .ended: self.endResize()
            }
        }
        well.addSubview(chrome)
        refreshActions()
        model.$isBusy.sink { [weak self] busy in self?.updateBadge(busy: busy, error: self?.model.error) }.store(in: &observers)
        model.$error.sink { [weak self] error in self?.updateBadge(busy: self?.model.isBusy ?? false, error: error) }.store(in: &observers)
    }
    required init?(coder: NSCoder) { nil }

    func setPinned(_ pinned: Bool) {
        self.pinned = pinned
        refreshActions()
    }
    private func refreshActions() {
        var actions: [ScreenshotCardActionBand.Action] = []
        if canEdit { actions.append(.init(title: String(localized: "Edit"), symbol: "pencil") { [weak self] _ in self?.onEdit?() }) }
        actions.append(.init(title: String(localized: "Copy"), symbol: "doc.on.doc") { [weak self] _ in self?.copy() })
        // A pin is already the closest look in the app; the system's Preview is the next one.
        actions.append(pinned
            ? .init(title: String(localized: "Preview"), symbol: "eye") { [weak self] _ in self?.openInPreview() }
            : .init(title: String(localized: "Pin"), symbol: "pin") { [weak self] _ in self?.onPin?() })
        actions.append(.init(title: String(localized: "Share"), symbol: "square.and.arrow.up") { [weak self] anchor in self?.share.share(anchor) })
        well.band.actions = actions
    }
    private func openInPreview() {
        Task { [model] in
            guard let url = await model.previewFile() else { return }
            ScreenshotCardModel.openInPreview(url)
        }
    }
    private func copy() {
        Task { [weak self, model] in
            guard await model.copy(), let self, self.alive else { return }
            self.copied = true
            self.updateBadge(busy: false, error: nil)
        }
    }
    private func updateBadge(busy: Bool, error: String?) {
        guard alive else { return }
        well.badge.show(status: copied ? String(localized: "Copied") : nil, busy: busy, error: error)
        well.badge.pop(after: 0, reduceMotion: reduceMotion)
        well.band.isEnabled = !busy
    }

    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { onClose?() } else { super.keyDown(with: event) }
    }
    /// ⌘+ and ⌘− zoom, ⌘0 shows the capture whole.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .numericPad]) == .command
        else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "=", "+": zoom.zoomIn()
        case "-": zoom.zoomOut()
        case "0": zoom.showWhole()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
    override func layout() {
        super.layout()
        if surface.frame != surfaceRect { surface.frame = surfaceRect }
        let tray = surface.bounds
        guard ring.layer.frame != tray else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.layer.frame = tray
        CATransaction.commit()
        let inset = ScreenshotPreviewGeometry.ring
        ring.set(ring: tray.insetBy(dx: 1, dy: 1), radius: Theme.Radius.floating - 1,
                 area: tray.insetBy(dx: inset, dy: inset), areaRadius: Theme.Radius.well)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        tracking = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) {
        if !isResizing { NSCursor.arrow.set() }
        setHovering(false)
        chrome.rest()
    }
    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHovering(surfaceRect.contains(point))
        guard !isResizing else { return }
        // A zoomed capture is grabbed to move around it.
        let overCapture = zoom.isZoomed && zoom.bounds.contains(zoom.convert(event.locationInWindow, from: nil))
        (Self.cursor(for: edges(at: point)) ?? chrome.cursor(atWindowPoint: event.locationInWindow)
            ?? (overCapture ? .openHand : .arrow)).set()
    }
    private func setHovering(_ active: Bool) {
        guard alive, active != hovering else { return }
        hovering = active
        well.setHovering(active, busy: model.isBusy, reduceMotion: reduceMotion)
    }

    // MARK: Resizing at the capture's ratio

    /// The tray's edge, a little either side of it, resizes; corners take both directions.
    private func edges(at point: CGPoint) -> Edges {
        let surface = surfaceRect, reach: CGFloat = 10, corner: CGFloat = 22
        guard surface.insetBy(dx: -reach, dy: -reach).contains(point),
              !surface.insetBy(dx: reach, dy: reach).contains(point) else { return [] }
        var edges: Edges = []
        let nearLeft = point.x < surface.minX + reach, nearRight = point.x > surface.maxX - reach
        let nearBottom = point.y < surface.minY + reach, nearTop = point.y > surface.maxY - reach
        if nearLeft || (point.x < surface.minX + corner && (nearBottom || nearTop)) { edges.insert(.left) }
        if nearRight || (point.x > surface.maxX - corner && (nearBottom || nearTop)) { edges.insert(.right) }
        if nearBottom || (point.y < surface.minY + corner && (nearLeft || nearRight)) { edges.insert(.bottom) }
        if nearTop || (point.y > surface.maxY - corner && (nearLeft || nearRight)) { edges.insert(.top) }
        return edges
    }
    private static func cursor(for edges: Edges) -> NSCursor? {
        let position: NSCursor.FrameResizePosition
        switch edges {
        case [.left]: position = .left
        case [.right]: position = .right
        case [.top]: position = .top
        case [.bottom]: position = .bottom
        case [.left, .top]: position = .topLeft
        case [.right, .top]: position = .topRight
        case [.left, .bottom]: position = .bottomLeft
        case [.right, .bottom]: position = .bottomRight
        default: return nil
        }
        return .frameResize(position: position, directions: .all)
    }
    override func mouseDown(with event: NSEvent) {
        let found = edges(at: convert(event.locationInWindow, from: nil))
        guard !found.isEmpty, window != nil else { super.mouseDown(with: event); return }
        beginResize(found)
    }
    override func mouseDragged(with event: NSEvent) {
        guard resize != nil else { super.mouseDragged(with: event); return }
        continueResize()
    }
    override func mouseUp(with event: NSEvent) {
        guard resize != nil else { super.mouseUp(with: event); return }
        endResize()
    }
    private static func edges(for corner: CameraCorner) -> Edges {
        switch corner {
        case .topLeft: [.left, .top]
        case .topRight: [.right, .top]
        case .bottomLeft: [.left, .bottom]
        case .bottomRight: [.right, .bottom]
        }
    }
    private func beginResize(_ edges: Edges) {
        guard let window else { return }
        resize = (edges, window.frame, NSEvent.mouseLocation)
        isResizing = true
    }
    private func continueResize() {
        guard let resize, let window else { return }
        let inset = ScreenshotPreviewGeometry.shadowInset
        let start = resize.frame.insetBy(dx: inset, dy: inset)
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - resize.mouse.x, dy = mouse.y - resize.mouse.y
        let ratio = start.width / start.height
        var width = start.width, height = start.height
        let horizontal = !resize.edges.isDisjoint(with: [.left, .right]), vertical = !resize.edges.isDisjoint(with: [.top, .bottom])
        if resize.edges.contains(.right) { width = start.width + dx }
        if resize.edges.contains(.left) { width = start.width - dx }
        if resize.edges.contains(.top) { height = start.height + dy }
        if resize.edges.contains(.bottom) { height = start.height - dy }
        if horizontal && vertical { let scale = max(width / start.width, height / start.height); width = start.width * scale }
        else if vertical { width = height * ratio }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? start
        width = min(max(width, 220), screen.width * 0.95, screen.height * 0.95 * ratio)
        height = width / ratio
        let x = resize.edges.contains(.left) ? start.maxX - width : resize.edges.contains(.right) ? start.minX : start.midX - width / 2
        let y = resize.edges.contains(.bottom) ? start.maxY - height : resize.edges.contains(.top) ? start.minY : start.midY - height / 2
        let frame = CGRect(x: x, y: y, width: width, height: height).insetBy(dx: -inset, dy: -inset).integral
        window.setFrame(frame, display: true)
    }
    private func endResize() {
        resize = nil
        isResizing = false
        layoutSubtreeIfNeeded()
        well.rerender()
    }

    func invalidate() {
        alive = false; observers.removeAll(); share.close()
        onClose = nil; onEdit = nil; onPin = nil
    }

    /// Opens from slightly smaller, the way a window zooms into place; from a card, it grows out
    /// of the card's own place and size.
    func animateIn(from card: CGRect? = nil) {
        layoutSubtreeIfNeeded()
        guard let layer = surface.layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        fade.duration = reduceMotion ? Theme.Motion.Duration.reduced : card == nil ? 0.18 : 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.preferFullRefreshRate(on: window?.screen)
        layer.add(fade, forKey: "preview-fade")
        if !reduceMotion {
            // The glass light draws around the tray as it settles, then lets go.
            let lit = CACurrentMediaTime() + (card == nil ? 0.1 : 0.2)
            ring.layer.opacity = 1
            ring.light(at: lit)
            let release = CABasicAnimation(keyPath: "opacity")
            release.fromValue = 1; release.toValue = 0
            release.beginTime = lit + 1.0; release.duration = 0.5
            release.fillMode = .backwards
            ring.layer.add(release, forKey: "release")
            ring.layer.opacity = 0
            let start = card.flatMap { grownFrom($0, for: layer) } ?? centeredScale(0.92, for: layer)
            let grow = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: start),
                                              to: NSValue(caTransform3D: CATransform3DIdentity),
                                              response: card == nil ? 0.42 : 0.46, dampingRatio: card == nil ? 0.82 : 0.86)
            grow.preferFullRefreshRate(on: window?.screen)
            layer.add(grow, forKey: "preview-zoom")
        }
        CATransaction.commit()
    }

    /// The transform that lays the tray over `card` (screen points): the same centre, scaled
    /// to the card's size.
    private func grownFrom(_ card: CGRect, for layer: CALayer) -> CATransform3D? {
        guard let window, surfaceRect.width > 0, surfaceRect.height > 0 else { return nil }
        let tray = surfaceRect.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        let scale = min(card.width / tray.width, card.height / tray.height)
        let shift = CGPoint(x: card.midX - tray.midX, y: card.midY - tray.midY)
        return CATransform3DConcat(centeredScale(scale, for: layer), CATransform3DMakeTranslation(shift.x, shift.y, 0))
    }

    func animateOut(completion: @escaping @MainActor () -> Void) {
        guard let layer = surface.layer else { completion(); return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = 0; fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.preferFullRefreshRate(on: window?.screen)
        layer.add(fade, forKey: "preview-fade")
        if !reduceMotion {
            layer.transform = centeredScale(0.9, for: layer)
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: layer.transform)
            shrink.duration = 0.18
            shrink.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            shrink.preferFullRefreshRate(on: window?.screen)
            layer.add(shrink, forKey: "preview-zoom")
        }
        CATransaction.commit()
    }

    /// A scale about the layer's centre, whatever its anchor point.
    private func centeredScale(_ scale: CGFloat, for layer: CALayer) -> CATransform3D {
        let x = layer.bounds.width * (0.5 - layer.anchorPoint.x), y = layer.bounds.height * (0.5 - layer.anchorPoint.y)
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-x, -y, 0), CATransform3DMakeScale(scale, scale, 1)),
                                   CATransform3DMakeTranslation(x, y, 0))
    }
}

private final class ScreenshotPreviewContent: NSView {
    private let well: NSView
    init(well: NSView) {
        self.well = well
        super.init(frame: .zero)
        addSubview(well)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        well.frame = bounds.insetBy(dx: ScreenshotPreviewGeometry.ring, dy: ScreenshotPreviewGeometry.ring)
    }
}

/// A Library capture as a preview's screenshot: the file's pixels at their recorded density.
enum ScreenshotPreviewSource {
    static func capture(for item: CaptureItem) async -> CapturedScreenshot? {
        let url = item.url
        return await Task.detached(priority: .userInitiated) { () -> CapturedScreenshot? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
            let scale = max(1, dpi / 72)
            return CapturedScreenshot(id: UUID(), image: image,
                                      pointSize: CGSize(width: Double(image.width) / scale, height: Double(image.height) / scale),
                                      kind: .screenshot, saveToDiskRequested: true)
        }.value
    }
}
