import AppKit
import Combine
import ImageIO
import QuartzCore

/// The preview's first size: the whole capture, modest on any screen, never magnified.
struct ScreenshotPreviewGeometry {
    static let ring: CGFloat = 8
    static let shadowInset: CGFloat = 32
    static let maximumWell = CGSize(width: 520, height: 360)
    static let minimumWell = CGSize(width: 300, height: 190)
    let well: CGSize
    let frame: CGRect
    init(pointSize: CGSize, visible: CGRect) {
        let room = CGSize(width: min(Self.maximumWell.width, visible.width * 0.6), height: min(Self.maximumWell.height, visible.height * 0.6))
        let valid = pointSize.width.isFinite && pointSize.height.isFinite && pointSize.width > 0 && pointSize.height > 0
        let scale = valid ? min(1, room.width / pointSize.width, room.height / pointSize.height) : 0
        let fitted = CGSize(width: (pointSize.width * scale).rounded(), height: (pointSize.height * scale).rounded())
        well = CGSize(width: max(Self.minimumWell.width, fitted.width), height: max(Self.minimumWell.height, fitted.height))
        let outset = 2 * (Self.ring + Self.shadowInset)
        let size = CGSize(width: well.width + outset, height: well.height + outset)
        frame = CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                       width: size.width, height: size.height)
    }
}

/// Lightweight looks at screenshots. An unpinned preview goes away with Esc, its close button
/// or a click elsewhere; a pinned one stays in front until it is closed. Pinned previews are
/// the app's pins: there is no other pin window.
@MainActor final class ScreenshotPreviewWindow {
    var onEdit: (@MainActor (CapturedScreenshot) -> Void)?
    private(set) var sessions: [ScreenshotPreviewSession] = []
    var isVisible: Bool { !sessions.isEmpty }

    func show(_ capture: CapturedScreenshot, operations: ScreenshotCardModel.Operations, on visible: CGRect,
              claim: (@MainActor () -> (@MainActor () -> Bool))?) {
        // A new preview replaces the unpinned one; pinned previews stay.
        for session in sessions where !session.pinned { session.close(animated: false) }
        let session = ScreenshotPreviewSession(capture: capture, operations: operations, visible: visible, claim: claim,
                                               canEdit: onEdit != nil)
        session.onEdit = { [weak self] in self?.onEdit?(capture) }
        session.onClosed = { [weak self, weak session] in self?.sessions.removeAll { $0 === session } }
        sessions.append(session)
        session.present()
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
         claim: (@MainActor () -> (@MainActor () -> Bool))?, canEdit: Bool) {
        model = ScreenshotCardModel(capture: capture, operations: operations)
        model.claimClipboardPublication = claim
        let geometry = ScreenshotPreviewGeometry(pointSize: capture.pointSize, visible: visible)
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
    }

    func present() {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(host)
        host.animateIn()
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

/// The preview's content: the capture's well on the tray. Hover shows Edit, Copy, Pin and Share;
/// the capture moves the window; the tray's edge resizes it at the capture's own ratio.
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
        surface = TraySurface(content: ScreenshotPreviewContent(well: well), shadowRadius: 14)
        share = ScreenshotCardShare(model: model, pause: { _, _ in })
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(surface)
        share.pause = { [weak self] reason, active in if reason == .sharing { self?.isSharing = active } }
        let image = well.imageView
        image.export = model.export
        image.movesWindow = true
        image.canInteract = { [weak model] in model?.isAlive == true }
        image.setAccessibilityHelp(nil)
        well.closeButton.action = { [weak self] in self?.onClose?() }
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
        actions.append(pinned
            ? .init(title: String(localized: "Unpin"), symbol: "pin.slash.fill") { [weak self] _ in self?.onPin?() }
            : .init(title: String(localized: "Pin"), symbol: "pin") { [weak self] _ in self?.onPin?() })
        actions.append(.init(title: String(localized: "Share"), symbol: "square.and.arrow.up") { [weak self] anchor in self?.share.share(anchor) })
        well.band.actions = actions
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
    override func layout() {
        super.layout()
        if surface.frame != surfaceRect { surface.frame = surfaceRect }
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
    }
    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHovering(surfaceRect.contains(point))
        guard !isResizing else { return }
        (Self.cursor(for: edges(at: point)) ?? .arrow).set()
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
        guard !found.isEmpty, let window else { super.mouseDown(with: event); return }
        resize = (found, window.frame, NSEvent.mouseLocation)
        isResizing = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let resize, let window else { super.mouseDragged(with: event); return }
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
    override func mouseUp(with event: NSEvent) {
        guard resize != nil else { super.mouseUp(with: event); return }
        resize = nil
        isResizing = false
        layoutSubtreeIfNeeded()
        well.rerender()
    }

    func invalidate() {
        alive = false; observers.removeAll(); share.close()
        onClose = nil; onEdit = nil; onPin = nil
    }

    /// Opens from slightly smaller, the way a window zooms into place.
    func animateIn() {
        layoutSubtreeIfNeeded()
        guard let layer = surface.layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        fade.duration = reduceMotion ? Theme.Motion.Duration.reduced : 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.preferFullRefreshRate(on: window?.screen)
        layer.add(fade, forKey: "preview-fade")
        if !reduceMotion {
            let zoom = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: centeredScale(0.92, for: layer)),
                                              to: NSValue(caTransform3D: CATransform3DIdentity), response: 0.42, dampingRatio: 0.82)
            zoom.preferFullRefreshRate(on: window?.screen)
            layer.add(zoom, forKey: "preview-zoom")
        }
        CATransaction.commit()
    }

    func animateOut(completion: @escaping @MainActor () -> Void) {
        guard let layer = surface.layer else { completion(); return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = 0; fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.preferFullRefreshRate(on: window?.screen)
        layer.add(fade, forKey: "preview-fade")
        if !reduceMotion {
            layer.transform = centeredScale(0.96, for: layer)
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: layer.transform)
            shrink.duration = 0.16
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
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
