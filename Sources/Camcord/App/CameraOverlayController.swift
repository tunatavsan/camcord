import AppKit
import Combine
import QuartzCore

/// One visible camera, sharing the recording's source. Placement changes are sent
/// to the compositor immediately; UserDefaults is written only when a drag ends.
@MainActor
final class CameraOverlayController: NSObject {
    static let shared = CameraOverlayController()
    var onPlacementChange: ((CameraOptions) -> Void)?
    var isVisible: Bool { panel.isVisible }

    private let panel: NSPanel
    private let cameraView = FloatingCameraView()
    private let shadowPanel: NSPanel
    private let shadowView = CameraShadowView()
    private var observations = Set<AnyCancellable>()
    private var options = CameraOptions()
    private var recordingBounds: CGRect?
    private var previewBounds: CGRect = .zero
    private var dragStart: (frame: CGRect, point: CGPoint, corner: CameraCorner?)?
    private var restartTask: Task<Void, Never>?
    private var motion: CameraDragMotion?
    private var motionTimestamp: CFTimeInterval?
    private var motionLink: CADisplayLink?

    private override init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        shadowPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        shadowPanel.isReleasedWhenClosed = false
        shadowPanel.backgroundColor = .clear
        shadowPanel.isOpaque = false
        shadowPanel.hasShadow = false
        shadowPanel.ignoresMouseEvents = true
        shadowPanel.hidesOnDeactivate = false
        shadowPanel.level = panel.level
        shadowPanel.collectionBehavior = panel.collectionBehavior
        shadowPanel.contentView = shadowView
        panel.addChildWindow(shadowPanel, ordered: .below)
        panel.contentView = cameraView
        panel.animationBehavior = .none
        cameraView.onDrag = { [weak self] phase, point, corner in self?.drag(phase, point: point, corner: corner) }
        let monitor = CameraPreviewMonitor.shared
        monitor.$image.sink { [weak self] image in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cameraView.image = image
            }
        }.store(in: &observations)
        monitor.$message.sink { [weak self] message in
            MainActor.assumeIsolated { self?.cameraView.message = message ?? "Kamera açılıyor…" }
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: RecordingSettings.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.settingsChanged() }
            }.store(in: &observations)
    }

    func showPreview(requestPermission: Bool = false) {
        let settings = RecordingSettings.load(from: .standard)
        guard settings.camera.enabled else { hide(); return }
        options = settings.camera.resolved()
        previewBounds = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame ?? .zero
        show()
        guard !CameraPreviewMonitor.shared.recordingLocked else { return }
        restartTask?.cancel()
        restartTask = Task {
            await CameraPreviewMonitor.shared.start(
                deviceID: options.deviceID,
                fps: settings.fps,
                requestPermission: requestPermission
            )
        }
    }

    func prepareRecording(cgRect: CGRect, options: CameraOptions) {
        stopMotion()
        dragStart = nil
        guard !cgRect.isEmpty, [cgRect.minX, cgRect.minY, cgRect.width, cgRect.height].allSatisfy(\.isFinite) else {
            hide()
            return
        }
        self.options = options.resolved()
        recordingBounds = Geometry.cgToAppKit(cgRect, primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
        if options.enabled { show() } else { hide() }
    }

    func updateRecordingBounds(cgRect: CGRect) {
        guard recordingBounds != nil, dragStart == nil else { return }
        let updated = Geometry.cgToAppKit(cgRect, primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
        if recordingBounds?.size != updated.size { stopMotion() }
        recordingBounds = updated
        layout()
    }

    private func show() {
        cameraView.mirrored = options.mirrored
        CameraPreviewMonitor.shared.setVisible(true, owner: "floating")
        layout()
        shadowPanel.orderFrontRegardless()
        panel.orderFrontRegardless()
    }

    func hide() {
        stopMotion()
        recordingBounds = nil
        shadowPanel.orderOut(nil)
        panel.orderOut(nil)
        restartTask?.cancel()
        CameraPreviewMonitor.shared.setVisible(false, owner: "floating")
        Task { await CameraPreviewMonitor.shared.stopIfUnobserved() }
    }

    private func settingsChanged() {
        let updated = RecordingSettings.load(from: .standard).camera.resolved()
        let deviceChanged = options.deviceID != updated.deviceID
        let displayed = options
        options = updated
        if motion != nil || dragStart != nil {
            options.position = displayed.position
            options.corner = displayed.corner
            options.widthFraction = displayed.widthFraction
        }
        if !updated.enabled { hide(); return }
        guard panel.isVisible else { return }
        cameraView.mirrored = updated.mirrored
        if dragStart == nil, motion == nil { layout() }
        if deviceChanged, !CameraPreviewMonitor.shared.recordingLocked {
            restartTask?.cancel()
            restartTask = Task {
                await CameraPreviewMonitor.shared.stop()
                guard !Task.isCancelled else { return }
                await CameraPreviewMonitor.shared.start(deviceID: updated.deviceID, fps: RecordingSettings.load(from: .standard).fps)
            }
        }
    }

    private var bounds: CGRect { recordingBounds ?? previewBounds }

    private func layout() {
        guard !bounds.isEmpty else { return }
        let local = options.rect(in: bounds.size)
        let frame = local.offsetBy(dx: bounds.minX, dy: bounds.minY)
        let resized = panel.frame.size != frame.size
        if resized { panel.setFrame(frame, display: true) }
        else { panel.setFrameOrigin(frame.origin) }
        let padding = CameraOptions.cornerRadius(for: local.size) * 3
        shadowView.padding = padding
        let shadowFrame = frame.insetBy(dx: -padding, dy: -padding)
        if shadowPanel.frame.size != shadowFrame.size {
            shadowPanel.setFrame(shadowFrame, display: true)
            shadowView.needsDisplay = true
        } else if shadowPanel.frame.origin != shadowFrame.origin {
            shadowPanel.setFrameOrigin(shadowFrame.origin)
        }
    }

    private func stopDisplayLink() {
        motionLink?.invalidate()
        motionLink = nil
        motionTimestamp = nil
    }

    private func stopMotion() {
        stopDisplayLink()
        motion = nil
    }

    private func startMotion() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            motion?.finishImmediately()
            displayMotion()
            if dragStart == nil { stopMotion() }
            return
        }
        guard motionLink == nil else { return }
        let link = cameraView.displayLink(target: self, selector: #selector(animateDrag(_:)))
        let fps = Float(min(120, panel.screen?.maximumFramesPerSecond ?? 60))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, fps), maximum: fps, preferred: fps)
        motionLink = link
        link.add(to: .main, forMode: .common)
    }

    private func displayMotion() {
        guard let motion else { return }
        options.place(motion.frame, in: bounds.size)
        if let corner = motion.magnetCorner { options.corner = corner }
        layout()
        onPlacementChange?(options)
    }

    @objc private func animateDrag(_ link: CADisplayLink) {
        guard motion != nil else { stopDisplayLink(); return }
        let elapsed = link.timestamp - (motionTimestamp ?? link.timestamp - 1.0 / 120)
        motionTimestamp = link.timestamp
        motion?.step(seconds: elapsed)
        displayMotion()
        if motion?.isSettled == true {
            stopDisplayLink()
            if dragStart == nil { motion = nil }
        }
    }

    private func drag(_ phase: FloatingCameraView.DragPhase, point: CGPoint, corner: CameraCorner?) {
        switch phase {
        case .began:
            let velocity = motion?.velocity ?? .zero
            stopMotion()
            dragStart = (panel.frame, point, corner)
            if corner == nil {
                motion = CameraDragMotion(frame: panel.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY),
                                          area: bounds.size, velocity: velocity)
            }
        case .changed, .ended:
            guard let start = dragStart else { return }
            let translation = CGPoint(x: point.x - start.point.x, y: point.y - start.point.y)
            let local = start.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            var final = options
            if let corner = start.corner {
                options = CameraResizeGeometry.resize(start: local, translation: translation,
                                                      corner: corner, options: options, in: bounds.size)
                final = options
                layout()
                onPlacementChange?(options)
            } else {
                motion?.follow(CGPoint(x: local.minX + translation.x, y: local.minY + translation.y),
                               released: phase == .ended)
                if let motion {
                    final.place(CGRect(origin: motion.target, size: motion.frame.size), in: bounds.size)
                    if let corner = motion.magnetCorner { final.corner = corner }
                }
            }
            if phase == .ended {
                dragStart = nil
                var settings = RecordingSettings.load(from: .standard)
                settings.camera.position = final.position
                settings.camera.corner = final.corner
                settings.camera.widthFraction = final.widthFraction
                settings.save(to: .standard)
            }
            if start.corner == nil { startMotion() }
        }
    }

}

/// Native mouse tracking leaves dragging/resizing on AppKit's event path, independent
/// of image delivery. The whole rectangle drags; its four corners resize proportionally.
@MainActor
final class FloatingCameraView: NSView {
    enum DragPhase { case began, changed, ended }
    var onDrag: ((DragPhase, CGPoint, CameraCorner?) -> Void)?
    var image: NSImage? { didSet { needsDisplay = true } }
    var mirrored = true { didSet { needsDisplay = true } }
    var message = "Kamera açılıyor…" { didSet { needsDisplay = true } }
    private var resizeCorner: CameraCorner?
    private(set) var indicatedCorner: CameraCorner?
    private var dragging = false
    private var tracking: NSTrackingArea?
    private let handle = CALayer()
    private let grip = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        handle.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        handle.cornerRadius = 9
        handle.backgroundColor = NSColor.black.withAlphaComponent(0.36).cgColor
        handle.opacity = 0
        handle.shadowColor = NSColor.black.cgColor
        handle.shadowOpacity = 0.35
        handle.shadowRadius = 4
        handle.shadowOffset = CGSize(width: 0, height: -1)
        grip.fillColor = nil
        grip.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        grip.lineWidth = 2.3
        grip.lineCap = .round
        grip.lineJoin = .round
        handle.addSublayer(grip)
        layer?.addSublayer(handle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        positionHandle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func cursor(for corner: CameraCorner) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch corner {
        case .topLeft: position = .topLeft
        case .topRight: position = .topRight
        case .bottomLeft: position = .bottomLeft
        case .bottomRight: position = .bottomRight
        }
        return .frameResize(position: position, directions: .all)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
        for corner in CameraCorner.allCases {
            addCursorRect(CameraResizeGeometry.hitRect(corner, in: bounds), cursor: cursor(for: corner))
        }
    }

    private func track(_ event: NSEvent) {
        guard !dragging else { return }
        indicate(CameraResizeGeometry.corner(at: convert(event.locationInWindow, from: nil), in: bounds))
    }

    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { if !dragging { indicate(nil) } }
    override func mouseDown(with event: NSEvent) {
        resizeCorner = CameraResizeGeometry.corner(at: convert(event.locationInWindow, from: nil), in: bounds)
        dragging = true
        indicate(resizeCorner)
        (resizeCorner.map { cursor(for: $0) } ?? .closedHand).set()
        onDrag?(.began, NSEvent.mouseLocation, resizeCorner)
    }
    override func mouseDragged(with event: NSEvent) { onDrag?(.changed, NSEvent.mouseLocation, resizeCorner) }
    override func mouseUp(with event: NSEvent) {
        onDrag?(.ended, NSEvent.mouseLocation, resizeCorner)
        resizeCorner = nil
        dragging = false
        track(event)
        window?.invalidateCursorRects(for: self)
    }

    private func indicate(_ corner: CameraCorner?) {
        guard corner != indicatedCorner else { return }
        let wasHidden = indicatedCorner == nil
        indicatedCorner = corner
        if corner != nil { positionHandle() }
        let previous = handle.presentation()?.opacity ?? handle.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        handle.opacity = corner == nil ? 0 : 1
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = previous
        fade.toValue = handle.opacity
        fade.duration = corner == nil ? 0.12 : 0.16
        handle.add(fade, forKey: "reveal")
        if corner != nil, wasHidden {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.72
            spring.toValue = 1
            spring.mass = 1
            spring.stiffness = 520
            spring.damping = 32
            spring.duration = 0.28
            handle.add(spring, forKey: "lift")
        }
    }

    private func positionHandle() {
        guard let corner = indicatedCorner else { return }
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topLeft || corner == .topRight
        let inset = max(17, CameraOptions.cornerRadius(for: bounds.size) * 0.48)
        let path = CGMutablePath()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: right ? 28 - x : x, y: top ? 28 - y : y)
        }
        path.move(to: point(20, 8))
        path.addLine(to: point(13, 8))
        path.addQuadCurve(to: point(8, 13), control: point(8, 8))
        path.addLine(to: point(8, 20))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        handle.position = CGPoint(x: right ? bounds.maxX - inset : bounds.minX + inset,
                                  y: top ? bounds.maxY - inset : bounds.minY + inset)
        grip.path = path
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = CameraOptions.cornerRadius(for: bounds.size)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.black.withAlphaComponent(0.92).setFill()
        bounds.fill()
        if let image {
            if mirrored {
                let flip = AffineTransform(m11: -1, m12: 0, m21: 0, m22: 1, tX: bounds.width, tY: 0)
                (flip as NSAffineTransform).concat()
            }
            let cropHeight = min(image.size.height, image.size.width / CameraOptions.aspectRatio)
            let cropWidth = cropHeight * CameraOptions.aspectRatio
            let crop = CGRect(x: (image.size.width - cropWidth) / 2, y: (image.size.height - cropHeight) / 2,
                              width: cropWidth, height: cropHeight)
            image.draw(in: bounds, from: crop, operation: .copy, fraction: 1)
        } else {
            let text = NSAttributedString(string: message, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.8)])
            text.draw(in: bounds.insetBy(dx: 14, dy: max(10, bounds.height / 2 - 20)))
        }
        NSGraphicsContext.restoreGraphicsState()

    }
}

/// The expanded shadow is click-through, so its soft halo never steals desktop clicks.
@MainActor
private final class CameraShadowView: NSView {
    var padding: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: padding, dy: padding)
        let radius = CameraOptions.cornerRadius(for: rect.size)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = radius * 1.6
        shadow.shadowOffset = NSSize(width: 0, height: -radius * 0.4)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
