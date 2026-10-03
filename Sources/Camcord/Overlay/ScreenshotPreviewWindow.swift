import AppKit
import Combine
import QuartzCore

/// The preview's size: the whole capture as large as the screen allows, never magnified.
struct ScreenshotPreviewGeometry {
    static let ring: CGFloat = 8
    static let shadowInset: CGFloat = 32
    static let minimumWell = CGSize(width: 360, height: 240)
    let well: CGSize
    let frame: CGRect
    init(pointSize: CGSize, visible: CGRect) {
        let room = CGSize(width: max(1, visible.width * 0.72 - 2 * Self.ring), height: max(1, visible.height * 0.8 - 2 * Self.ring))
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

/// A lightweight look at one screenshot: the capture alone on the window tray, its actions on
/// hover. Esc, the close button or a click elsewhere puts it away.
@MainActor final class ScreenshotPreviewWindow: NSObject, NSWindowDelegate {
    var onEdit: (@MainActor (CapturedScreenshot) -> Void)?
    var onPin: (@MainActor (CapturedScreenshot) -> Void)?
    private var panel: NSPanel?
    private var host: ScreenshotPreviewHost?
    private var model: ScreenshotCardModel?
    var isVisible: Bool { panel != nil }

    func show(_ capture: CapturedScreenshot, operations: ScreenshotCardModel.Operations, on visible: CGRect,
              claim: (@MainActor () -> (@MainActor () -> Bool))?) {
        close(animated: false)
        let model = ScreenshotCardModel(capture: capture, operations: operations)
        model.claimClipboardPublication = claim
        let geometry = ScreenshotPreviewGeometry(pointSize: capture.pointSize, visible: visible)
        let host = ScreenshotPreviewHost(model: model, wellSize: geometry.well, canEdit: onEdit != nil, canPin: onPin != nil)
        host.onClose = { [weak self] in self?.close(animated: true) }
        host.onEdit = { [weak self] in
            guard let self else { return }
            self.close(animated: false)
            self.onEdit?(capture)
        }
        host.onPin = { [weak self] in self?.onPin?(capture) }
        let panel = ScreenshotPreviewPanel(contentRect: geometry.frame, styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none; panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.contentView = host
        panel.delegate = self
        self.panel = panel; self.host = host; self.model = model
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(host)
        host.animateIn()
    }

    func close(animated: Bool) {
        guard let panel, let host else { return }
        self.panel = nil; self.host = nil
        model?.invalidate(); model = nil
        host.invalidate()
        panel.delegate = nil
        if animated { host.animateOut { panel.orderOut(nil) } } else { panel.orderOut(nil) }
    }

    func windowDidResignKey(_ notification: Notification) {
        // A click elsewhere puts the preview away, unless its own share sheet took the focus.
        guard let host, !host.isSharing else { return }
        close(animated: true)
    }
}

private final class ScreenshotPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The preview's content: the capture's well on the tray, with Edit, Copy, Pin and Share on hover.
@MainActor final class ScreenshotPreviewHost: NSView {
    var onClose: (@MainActor () -> Void)?
    var onEdit: (@MainActor () -> Void)?
    var onPin: (@MainActor () -> Void)?
    private(set) var isSharing = false
    private let model: ScreenshotCardModel
    let well: ScreenshotCardWell
    private let surface: TraySurface
    private let share: ScreenshotCardShare
    private var observers: Set<AnyCancellable> = []
    private var tracking: NSTrackingArea?
    private var hovering = false
    private var alive = true
    private var copied = false
    private var surfaceRect: CGRect { bounds.insetBy(dx: ScreenshotPreviewGeometry.shadowInset, dy: ScreenshotPreviewGeometry.shadowInset) }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(model: ScreenshotCardModel, wellSize: CGSize, canEdit: Bool, canPin: Bool) {
        self.model = model
        well = ScreenshotCardWell(capture: model.capture, size: wellSize)
        surface = TraySurface(content: ScreenshotPreviewContent(well: well), shadowRadius: 14)
        share = ScreenshotCardShare(model: model, pause: { _, _ in })
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(surface)
        share.pause = { [weak self] reason, active in if reason == .sharing { self?.isSharing = active } }
        let image = well.imageView
        image.export = model.export
        image.canInteract = { [weak model] in model?.isAlive == true }
        well.closeButton.action = { [weak self] in self?.onClose?() }
        var actions: [ScreenshotCardActionBand.Action] = []
        if canEdit { actions.append(.init(title: String(localized: "Edit"), symbol: "pencil") { [weak self] _ in self?.onEdit?() }) }
        actions.append(.init(title: String(localized: "Copy"), symbol: "doc.on.doc") { [weak self] _ in self?.copy() })
        if canPin { actions.append(.init(title: String(localized: "Pin"), symbol: "pin") { [weak self] _ in self?.onPin?() }) }
        actions.append(.init(title: String(localized: "Share"), symbol: "square.and.arrow.up") { [weak self] anchor in self?.share.share(anchor) })
        well.band.actions = actions
        model.$preparedExportURL.sink { image.preparedURL = $0 }.store(in: &observers)
        model.$preparedExportPNG.sink { image.preparedPNG = $0 }.store(in: &observers)
        model.$isBusy.sink { [weak self] busy in self?.updateBadge(busy: busy, error: self?.model.error) }.store(in: &observers)
        model.$error.sink { [weak self] error in self?.updateBadge(busy: self?.model.isBusy ?? false, error: error) }.store(in: &observers)
    }
    required init?(coder: NSCoder) { nil }

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
        let area = NSTrackingArea(rect: surfaceRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        tracking = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }
    private func setHovering(_ active: Bool) {
        guard alive else { return }
        hovering = active
        well.setHovering(active, busy: model.isBusy, reduceMotion: reduceMotion)
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
