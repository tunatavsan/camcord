import AppKit
import Combine
import QuartzCore

/// One visible camera, sharing the recording's source. Placement changes are sent
/// to the compositor and the persisted placement through one shared funnel.
@MainActor
final class CameraOverlayController: NSObject {
    static let shared = CameraOverlayController()
    enum PlacementSource { case floating, stage, settings }

    var onPlacementChange: ((CameraOptions) -> Void)?
    var isVisible: Bool { panel.isVisible }
    /// Only the owner's own surfaces change `previewVisible` -- the panel chip, the
    /// status-menu item, the tile's own close button and the shortcut, all through
    /// `setPreviewVisible`. Arming and recording may CONFINE the preview
    /// (`prepareRecording`), never open it: a placement made with it closed lands in the
    /// file just the same. `private(set)` is what enforces that -- no arming, recording or
    /// panel-visible path can even compile a write to it.
    private(set) var previewVisible = false

    /// Posted whenever `previewVisible` changes, so a chip drawn elsewhere (the panel) does
    /// not go stale when the shortcut or the tile's × flips it.
    static let previewVisibilityDidChange = Notification.Name("dev.tavsan.camcord.previewVisibilityDidChange")

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
    /// True while the panels are laid out but deliberately off screen, waiting for the
    /// camera's first frame so the preview never flashes an empty black tile.
    private var pendingReveal = false
    private var revealTimeout: Task<Void, Never>?
    private var motion: CameraDragMotion?
    private var motionTimestamp: CFTimeInterval?
    private var motionLink: CADisplayLink?
    /// The last latched magnet/size stop, so each latch ticks exactly once.
    private var hapticCorner: CameraCorner?
    private(set) var hapticWidthStop: Double?
    /// Guards a fade-out completion against a show() that raced it.
    private var visibilityToken = 0

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
        cameraView.onClose = { [weak self] in self?.setPreviewVisible(false) }
        let monitor = CameraPreviewMonitor.shared
        monitor.$image.sink { [weak self] image in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cameraView.image = image
                if image != nil, self.pendingReveal { self.reveal(appearing: true) }
            }
        }.store(in: &observations)
        monitor.$message.sink { [weak self] message in
            MainActor.assumeIsolated { self?.cameraView.message = message ?? "Kamera açılıyor…" }
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: RecordingSettings.didChangeNotification)
            .sink { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in self?.settingsChanged() }
            }.store(in: &observations)
    }

    /// `persists: false` is the live-drag path: the compositor and the floating preview
    /// follow every frame, but UserDefaults (and the settings notification that fans out
    /// to two more observers) is written only when the gesture settles.
    func applyPlacement(_ options: CameraOptions, source: PlacementSource, persists: Bool = true) {
        if source != .floating { stopMotion(); dragStart = nil }
        self.options = options.resolved()
        if persists {
            var settings = RecordingSettings.load(from: .standard)
            if settings.camera != self.options {
                settings.camera = self.options
                settings.save(to: .standard)
            }
        }
        // While a spring is running it owns the panel's frame (`displayMotion` lays out
        // every frame): laying out here would snap the panel to the dock mid-flight and
        // the next spring step would jump it back.
        if panel.isVisible {
            cameraView.mirrored = self.options.mirrored
            if motion == nil { layout() }
        }
        onPlacementChange?(self.options)
    }

    #if DEBUG
    /// Test seam: places the owner's switch without `setPreviewVisible`'s device side
    /// effects (opening it asks for camera permission, which a unit test must never do).
    func setPreviewVisibleForTesting(_ value: Bool) { previewVisible = value }
    #endif

    /// The single writer behind every owner surface: chip, status menu, the tile's × and
    /// the shortcut. Opening asks for permission only when the owner asked for it directly.
    func setPreviewVisible(_ visible: Bool, requestPermission: Bool = false) {
        guard previewVisible != visible else { return }
        previewVisible = visible
        if visible { showPreview(requestPermission: requestPermission) } else { hide(animated: true) }
        NotificationCenter.default.post(name: Self.previewVisibilityDidChange, object: nil)
    }

    /// The chip and the status-menu item both land here.
    func togglePreview() {
        setPreviewVisible(!previewVisible, requestPermission: true)
    }

    /// Drops the confinement rect an arming or a recording put up. The owner's choice is
    /// untouched: an open preview goes back to free-floating, a closed one stays closed.
    func recordingEnded() {
        recordingBounds = nil
        if previewVisible { showPreview() } else { hide() }
    }

    func showPreview(requestPermission: Bool = false) {
        let settings = RecordingSettings.load(from: .standard)
        guard previewVisible else { hide(); return }
        options = settings.camera.resolved()
        previewBounds = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.frame ?? .zero
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
        if previewVisible { show() } else { hide() }
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
        visibilityToken &+= 1
        let appearing = !panel.isVisible
        layout()
        // Opening onto a black rectangle while the device warms up is the ugliest second of
        // the whole flow. The panel goes up (so confinement, layout and every caller's
        // notion of "shown" are unchanged) but stays fully transparent and click-through
        // until the first frame arrives — or until the grace period expires, after which
        // the placeholder appears and says what is happening.
        let waiting = appearing && cameraView.image == nil
        // A show() landing inside the 150 ms fade-out has to cancel it through the same
        // animator: a plain assignment loses the race and leaves the panel at alpha 0. The
        // target is the alpha we actually want — animating to 1 and then assigning 0 let a
        // fully opaque placeholder tile flash for a frame before it disappeared again.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = waiting ? 0 : 1
            shadowPanel.animator().alphaValue = waiting ? 0 : 1
        }
        if waiting {
            pendingReveal = true
            panel.ignoresMouseEvents = true
            panel.alphaValue = 0
            shadowPanel.alphaValue = 0
            shadowPanel.orderFrontRegardless()
            panel.orderFrontRegardless()
            revealTimeout?.cancel()
            let token = visibilityToken
            revealTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1_200))
                guard let self, !Task.isCancelled, self.visibilityToken == token, self.pendingReveal else { return }
                self.reveal(appearing: true)
            }
            return
        }
        reveal(appearing: appearing)
    }

    /// Puts the panels on screen. Split out of `show()` so the first frame (or the timeout)
    /// can drive it instead of the caller.
    private func reveal(appearing: Bool) {
        pendingReveal = false
        revealTimeout?.cancel()
        revealTimeout = nil
        panel.ignoresMouseEvents = false
        let animate = appearing && !Self.reducesMotion
        let final = panel.frame
        // Every pixel of the opening state is set BEFORE the panel is ordered front.
        // Ordering a window in makes the server composite it at its current alpha, so the
        // old "order front at 1, then set 0 and animate up" showed one opaque frame first.
        if animate {
            panel.setFrame(final.insetBy(dx: final.width * 0.04, dy: final.height * 0.04), display: false)
            panel.alphaValue = 0
            shadowPanel.alphaValue = 0
        } else {
            panel.alphaValue = 1
            shadowPanel.alphaValue = 1
        }
        shadowPanel.orderFrontRegardless()
        panel.orderFrontRegardless()
        guard animate else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(final, display: true)
            panel.animator().alphaValue = 1
            shadowPanel.animator().alphaValue = 1
        }
    }

    /// `animated` is the owner dismissing the preview. Every other caller (recording
    /// preparation, teardown) must leave the screen in the same run loop pass, or a
    /// fading preview would burn into the recording's first frames.
    func hide(animated: Bool = false) {
        stopMotion()
        restartTask?.cancel()
        // A preview waiting for its first frame is cancelled here too, or it would fade in
        // onto a screen the owner has already closed it on.
        pendingReveal = false
        revealTimeout?.cancel()
        revealTimeout = nil
        panel.ignoresMouseEvents = false
        visibilityToken &+= 1
        guard animated, panel.isVisible, !Self.reducesMotion else {
            releaseDevice()
            orderOutPanels()
            return
        }
        let token = visibilityToken
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
            shadowPanel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit runs this on the main thread; the closure itself is only Sendable.
            MainActor.assumeIsolated {
                guard let self, self.visibilityToken == token else { return }
                self.releaseDevice()
                self.orderOutPanels()
            }
        }
    }

    /// Dropping the device blanks the view back to "Kamera açılıyor…", so it waits for
    /// the fade: the preview must dissolve on its last frame, not on a placeholder.
    private func releaseDevice() {
        CameraPreviewMonitor.shared.setVisible(false, owner: "floating")
        Task { await CameraPreviewMonitor.shared.stopIfUnobserved() }
    }

    private func orderOutPanels() {
        shadowPanel.orderOut(nil)
        panel.orderOut(nil)
        panel.alphaValue = 1
        shadowPanel.alphaValue = 1
    }

    static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// One alignment tick when a magnet or a size stop latches -- never while sliding.
    private func latchHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
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
        // Room for the blur plus its drop, or the halo is clipped by its own panel.
        let padding = ceil(min(local.width, local.height) * 0.30)
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
        if Self.reducesMotion {
            motion?.finishImmediately()
            displayMotion()
            if dragStart == nil { settleMotion() }
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
        if motion.magnetCorner != hapticCorner {
            hapticCorner = motion.magnetCorner
            if hapticCorner != nil { latchHaptic() }
        }
        applyPlacement(options, source: .floating, persists: false)
        if panel.isVisible { layout() }
    }

    /// The spring, not the mouse-up, hands over the final placement: persisting at the
    /// release would send the compositor to the dock before the preview gets there.
    private func settleMotion() {
        stopDisplayLink()
        motion = nil
        applyPlacement(options, source: .floating)
    }

    @objc private func animateDrag(_ link: CADisplayLink) {
        guard motion != nil else { stopDisplayLink(); return }
        let elapsed = link.timestamp - (motionTimestamp ?? link.timestamp - 1.0 / 120)
        motionTimestamp = link.timestamp
        let wasThrown = motion?.released == true
        motion?.step(seconds: elapsed)
        displayMotion()
        if motion?.isSettled == true {
            if wasThrown { latchHaptic() }
            stopDisplayLink()
            if dragStart == nil { settleMotion() }
        }
    }

    /// Screen-space gesture from the floating view: the whole rectangle drags, its four
    /// corners resize. `.ended` hands the placement to the spring, which persists it.
    func drag(_ phase: FloatingCameraView.DragPhase, point: CGPoint, corner: CameraCorner?) {
        switch phase {
        case .began:
            let velocity = motion?.velocity ?? .zero
            stopMotion()
            dragStart = (panel.frame, point, corner)
            hapticWidthStop = CameraResizeGeometry.latchedStop(of: options.widthFraction)
            if corner == nil {
                motion = CameraDragMotion(frame: panel.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY),
                                          area: bounds.size, velocity: velocity)
            }
            hapticCorner = motion?.magnetCorner
        case .changed, .ended:
            guard let start = dragStart else { return }
            let translation = CGPoint(x: point.x - start.point.x, y: point.y - start.point.y)
            let local = start.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            if let corner = start.corner {
                options = CameraResizeGeometry.resize(start: local, translation: translation,
                                                      corner: corner, options: options, in: bounds.size)
                let stop = CameraResizeGeometry.latchedStop(of: options.widthFraction)
                if stop != hapticWidthStop {
                    hapticWidthStop = stop
                    if stop != nil { latchHaptic() }
                }
                applyPlacement(options, source: .floating, persists: phase == .ended)
            } else {
                motion?.follow(CGPoint(x: local.minX + translation.x, y: local.minY + translation.y),
                               released: phase == .ended)
            }
            if phase == .ended { dragStart = nil }
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
    /// The owner dismissing the preview from the tile itself.
    var onClose: (() -> Void)?
    var image: NSImage? { didSet { needsDisplay = true } }
    var mirrored = true { didSet { needsDisplay = true } }
    var message = "Kamera açılıyor…" { didSet { needsDisplay = true } }
    private var resizeCorner: CameraCorner?
    private(set) var indicated: CameraHotspot?
    var indicatedCorner: CameraCorner? { indicated?.corner }
    private var dragging = false
    private var tracking: NSTrackingArea?
    private let handle = CALayer()
    private let grip = CAShapeLayer()
    private let closeBadge = CALayer()
    private let closeGlyph = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Both badges are drawn, not filled: a hairline of white that carries its own soft
        // shadow, so they separate from bright video without putting a slab over it.
        handle.opacity = 0
        Self.style(grip)
        handle.addSublayer(grip)
        layer?.addSublayer(handle)

        closeBadge.opacity = 0
        Self.style(closeGlyph)
        closeBadge.addSublayer(closeGlyph)
        layer?.addSublayer(closeBadge)
    }

    private static func style(_ shape: CAShapeLayer) {
        shape.fillColor = nil
        shape.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        shape.lineCap = .round
        shape.lineJoin = .round
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowOpacity = 0.55
        shape.shadowRadius = 3
        shape.shadowOffset = CGSize(width: 0, height: -1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        positionHandle()
        positionCloseBadge()
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
        if let close = CameraResizeGeometry.closeHitRect(in: bounds) {
            addCursorRect(close, cursor: .arrow)
        }
        for corner in CameraCorner.allCases {
            addCursorRect(CameraResizeGeometry.hitRect(corner, in: bounds), cursor: cursor(for: corner))
        }
    }

    private func track(_ event: NSEvent) {
        guard !dragging else { return }
        indicate(CameraResizeGeometry.hotspot(at: convert(event.locationInWindow, from: nil), in: bounds))
    }

    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { if !dragging { indicate(nil) } }
    override func mouseDown(with event: NSEvent) {
        let hotspot = CameraResizeGeometry.hotspot(at: convert(event.locationInWindow, from: nil), in: bounds)
        // The × is a button: it closes on mouse-DOWN and starts no drag, so the tile can
        // never be dragged out from under the click that was meant to dismiss it.
        if hotspot == .close {
            indicate(nil)
            onClose?()
            return
        }
        resizeCorner = hotspot?.corner
        dragging = true
        indicate(hotspot)
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

    private func indicate(_ hotspot: CameraHotspot?) {
        guard hotspot != indicated else { return }
        let previousHotspot = indicated
        indicated = hotspot
        if hotspot?.corner != nil { positionHandle() }
        if hotspot == .close { positionCloseBadge() }
        reveal(handle, shown: hotspot?.corner != nil, wasShown: previousHotspot?.corner != nil)
        reveal(closeBadge, shown: hotspot == .close, wasShown: previousHotspot == .close)
    }

    /// One fade (plus a spring on the way in) for whichever badge is appearing or leaving.
    private func reveal(_ badge: CALayer, shown: Bool, wasShown: Bool) {
        guard shown != wasShown else { return }
        let previous = badge.presentation()?.opacity ?? badge.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badge.opacity = shown ? 1 : 0
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = previous
        fade.toValue = badge.opacity
        fade.duration = shown ? 0.16 : 0.12
        badge.add(fade, forKey: "reveal")
        guard shown else { return }
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.72
        spring.toValue = 1
        spring.mass = 1
        spring.stiffness = 520
        spring.damping = 32
        spring.duration = 0.28
        badge.add(spring, forKey: "lift")
    }

    private func positionHandle() {
        guard let corner = indicated?.corner else { return }
        let frame = CameraResizeGeometry.handleFrame(corner, in: bounds)
        let arc = CameraResizeGeometry.gripArcRadius(in: bounds)
        let angles = CameraResizeGeometry.gripArcAngles(corner)
        // A quarter circle sharing the tile corner's centre: the same curve, one gap in.
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: arc, y: arc), radius: arc,
                    startAngle: angles.start, endAngle: angles.end, clockwise: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        handle.bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        handle.position = CGPoint(x: frame.midX, y: frame.midY)
        grip.lineWidth = CameraResizeGeometry.badgeLineWidth(in: bounds)
        grip.path = path
        CATransaction.commit()
    }

    private func positionCloseBadge() {
        guard let frame = CameraResizeGeometry.closeFrame(in: bounds) else {
            closeBadge.opacity = 0
            return
        }
        let side = frame.width
        let line = CameraResizeGeometry.badgeLineWidth(in: bounds)
        let arm = side * 0.22
        // The same language as the grip: a drawn ring, not a filled disc, with the × inside.
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: line / 2, y: line / 2,
                                   width: side - line, height: side - line))
        path.move(to: CGPoint(x: side / 2 - arm, y: side / 2 - arm))
        path.addLine(to: CGPoint(x: side / 2 + arm, y: side / 2 + arm))
        path.move(to: CGPoint(x: side / 2 - arm, y: side / 2 + arm))
        path.addLine(to: CGPoint(x: side / 2 + arm, y: side / 2 - arm))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        closeBadge.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        closeBadge.position = CGPoint(x: frame.midX, y: frame.midY)
        closeGlyph.lineWidth = line
        closeGlyph.path = path
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = CameraOptions.cornerRadius(for: bounds.size)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if image == nil {
            // The warming-up state. A flat black rectangle read as a broken window; this is
            // a quiet graphite tile with the camera glyph, and it is only ever seen when the
            // device is slow enough that `show()` gave up waiting for the first frame.
            NSGradient(
                starting: NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.19, alpha: 0.95),
                ending: NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 0.95)
            )?.draw(in: bounds, angle: -90)
        } else {
            NSColor.black.withAlphaComponent(0.92).setFill()
            bounds.fill()
        }
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
            let text = NSAttributedString(string: message, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.72),
            ])
            let textSize = text.size()
            let glyphPoint = min(30, bounds.height * 0.24)
            let configuration = NSImage.SymbolConfiguration(pointSize: glyphPoint, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(0.42)]))
            let glyph = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            let gap: CGFloat = glyph == nil ? 0 : 9
            let stack = (glyph?.size.height ?? 0) + gap + textSize.height
            var y = bounds.midY + stack / 2
            if let glyph {
                y -= glyph.size.height
                glyph.draw(in: CGRect(x: bounds.midX - glyph.size.width / 2, y: y,
                                      width: glyph.size.width, height: glyph.size.height))
                y -= gap
            }
            text.draw(at: CGPoint(x: bounds.midX - textSize.width / 2, y: y - textSize.height))
        }
        NSGraphicsContext.restoreGraphicsState()

        // The same hairline the compositor draws into the file.
        let hairline = CameraOptions.edgeHighlightWidth(for: bounds.size)
        let edge = NSBezierPath(
            roundedRect: bounds.insetBy(dx: hairline / 2, dy: hairline / 2),
            xRadius: max(0, radius - hairline / 2), yRadius: max(0, radius - hairline / 2)
        )
        edge.lineWidth = hairline
        NSColor.white.withAlphaComponent(0.28).setStroke()
        edge.stroke()

    }
}

/// The expanded shadow is click-through, so its soft halo never steals desktop clicks.
@MainActor
private final class CameraShadowView: NSView {
    var padding: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: padding, dy: padding)
        let radius = CameraOptions.cornerRadius(for: rect.size)
        // Sized off the tile, not off the corner — the curve is light now, the separation
        // from the desktop behind is not. Matches the compositor's shadow, so what the owner
        // places on screen is what the file shows.
        let short = min(rect.width, rect.height)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.62)
        shadow.shadowBlurRadius = short * 0.16
        shadow.shadowOffset = NSSize(width: 0, height: -short * 0.06)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
