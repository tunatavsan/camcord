import AppKit
import QuartzCore

/// Where the hub rests: the four corners of the display plus the top centre — five places
/// a control hub belongs, and the reason a throw can no longer land it "to the right" when
/// the owner aimed at the top middle. Persisted in `RecordingSettings.hubDock`.
enum RecordingHubDock: String, Codable, CaseIterable, Sendable {
    case topLeft
    case topCenter
    case topRight
    case bottomLeft
    case bottomRight

    /// Unit position in the dock's travel area, origin bottom-left.
    var unit: CGPoint {
        switch self {
        case .topLeft: CGPoint(x: 0, y: 1)
        case .topCenter: CGPoint(x: 0.5, y: 1)
        case .topRight: CGPoint(x: 1, y: 1)
        case .bottomLeft: CGPoint(x: 0, y: 0)
        case .bottomRight: CGPoint(x: 1, y: 0)
        }
    }

    /// A dock on the right edge: the capsule grows inward so it never expands off screen.
    var mirrored: Bool { self == .topRight || self == .bottomRight }

    /// The resting rect inside `area`, using the camera tile's own margin so the two
    /// floating surfaces sit the same distance off the edge.
    func rect(size: CGSize, in area: CGRect) -> CGRect {
        let margin = CameraOptions.margin(in: area.size)
        let travelX = max(0, area.width - margin * 2 - size.width)
        let travelY = max(0, area.height - margin * 2 - size.height)
        return CGRect(x: area.minX + margin + travelX * unit.x,
                      y: area.minY + margin + travelY * unit.y,
                      width: size.width, height: size.height)
    }

    static func nearest(to rect: CGRect, in area: CGRect) -> RecordingHubDock {
        allCases.min {
            distance(from: rect, to: $0, in: area) < distance(from: rect, to: $1, in: area)
        } ?? .topCenter
    }

    private static func distance(from rect: CGRect, to dock: RecordingHubDock, in area: CGRect) -> CGFloat {
        let target = dock.rect(size: rect.size, in: area)
        return hypot(target.midX - rect.midX, target.midY - rect.midY)
    }

    /// The camera tile's release rule: past `CameraDragMotion.flingSpeed` a throw docks
    /// where it was heading, projected by the same `flingProjection`; a slower drop docks
    /// to the nearest.
    static func dock(forDrop rect: CGRect, velocity: CGPoint, in area: CGRect) -> RecordingHubDock {
        guard hypot(velocity.x, velocity.y) >= CameraDragMotion.flingSpeed else {
            return nearest(to: rect, in: area)
        }
        let projection = CGFloat(CameraDragMotion.flingProjection)
        return nearest(to: rect.offsetBy(dx: velocity.x * projection, dy: velocity.y * projection), in: area)
    }
}

/// Hover expand/collapse, pure and clock-injected. Expanding is immediate; collapsing
/// waits, so crossing the gap between two controls — or slipping off the capsule for a
/// frame — never snaps the hub shut under the pointer.
struct RecordingHubHover: Equatable, Sendable {
    static let collapseDelay: TimeInterval = 0.4

    private(set) var expanded = false
    private(set) var pointerInside = false
    private(set) var collapseAt: TimeInterval?

    mutating func pointerEntered(at now: TimeInterval) {
        pointerInside = true
        collapseAt = nil
        expanded = true
    }

    mutating func pointerExited(at now: TimeInterval) {
        guard pointerInside else { return }
        pointerInside = false
        collapseAt = expanded ? now + Self.collapseDelay : nil
    }

    mutating func advance(to now: TimeInterval) {
        guard let collapseAt, now >= collapseAt else { return }
        self.collapseAt = nil
        expanded = false
    }

    /// The idle hub sits back so it never demands attention; hovering brings it forward.
    var alpha: CGFloat { expanded ? 1 : 0.55 }
}

/// The disc → capsule morph: one spring, integrated with `CameraDragMotion.integrate` so
/// the hub and the camera tile move by the same maths. ζ = 0.8 — one whisper of overshoot,
/// settled inside 260 ms.
struct RecordingHubExpansion: Equatable, Sendable {
    static let stiffness: CGFloat = 450
    static let dampingRatio: CGFloat = 0.8
    static var damping: CGFloat { 2 * dampingRatio * sqrt(stiffness) }

    var target: CGFloat = 0
    private(set) var progress: CGFloat = 0
    private(set) var velocity: CGFloat = 0

    var isSettled: Bool { abs(target - progress) < 0.001 && abs(velocity) < 0.02 }

    mutating func finishImmediately() {
        progress = target
        velocity = 0
    }

    mutating func step(seconds: TimeInterval) {
        let elapsed = min(max(seconds, 0), 1.0 / 30)
        let steps = max(1, Int(ceil(elapsed * 480)))
        let dt = elapsed / Double(steps)
        for _ in 0..<steps {
            var position = CGPoint(x: progress, y: 0)
            var speed = CGPoint(x: velocity, y: 0)
            CameraDragMotion.integrate(&position, velocity: &speed, toward: CGPoint(x: target, y: 0),
                                       stiffness: Self.stiffness, damping: Self.damping, seconds: dt)
            progress = position.x
            velocity = speed.x
        }
        if isSettled { finishImmediately() }
    }
}

/// The hub's own window: nonactivating, on every Space, above full-screen chrome, and
/// raised to the shielding level when a game owns the display — otherwise a fullscreen
/// game draws straight over the only way to stop a recording. Owns the drag (five docks,
/// the tile's magnet and fling rules) and the expansion spring.
@MainActor
final class RecordingHubPanel {
    typealias PanelPresenter = @MainActor (NSPanel) -> Void

    var onStop: (() -> Void)?
    var onPauseResume: (() -> Void)?
    var onTogglePreview: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Fires as the pointer arrives on and leaves the hub — the recording frame rides on
    /// this, so hovering the hub is what reveals it.
    var onHoverChange: ((Bool) -> Void)?

    private let panel: NSPanel
    private let view: RecordingHubView
    private let defaults: UserDefaults
    private let present: PanelPresenter

    private var mode: RecordingHubMode = .recording
    private var dock: RecordingHubDock = .topCenter
    private var area: CGRect = .zero
    private var capsule: CGRect = .zero

    private var hover = RecordingHubHover()
    private var expansion = RecordingHubExpansion()
    private var collapseTask: Task<Void, Never>?

    private var motionLink: CADisplayLink?
    private var motionProxy: HubMotionProxy?
    private var motionTimestamp: CFTimeInterval?
    /// The released dock spring: where it is going, how fast, and the throw distance the
    /// shared spring was chosen for.
    private var settle: (target: CGPoint, velocity: CGPoint, distance: CGFloat)?

    private var dragStart: (capsule: CGRect, point: CGPoint)?
    private var dragVelocity: CGPoint = .zero
    private var dragSample: (point: CGPoint, time: CFTimeInterval)?

    private var previewObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, panelPresenter: PanelPresenter? = nil) {
        self.defaults = defaults
        self.present = panelPresenter ?? { $0.orderFrontRegardless() }
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        view = RecordingHubView(frame: .zero)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the hub draws its own, inside the panel's margin
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        view.onHover = { [weak self] inside in self?.setHovered(inside) }
        view.onPress = { [weak self] item in self?.press(item) }
        view.onDrag = { [weak self] phase, point in self?.drag(phase, point: point) }
        previewObserver = NotificationCenter.default.addObserver(
            forName: CameraOverlayController.previewVisibilityDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPreviewState() }
        }
    }

    isolated deinit {
        collapseTask?.cancel()
        motionLink?.invalidate()
        if let previewObserver { NotificationCenter.default.removeObserver(previewObserver) }
    }

    // MARK: - Presentation

    func show(mode: RecordingHubMode, on screen: NSScreen?) {
        self.mode = mode
        view.mode = mode
        // The VISIBLE frame: a hub resting on the live menu bar would eat clicks meant
        // for the status items.
        area = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        dock = RecordingSettings.load(from: defaults).hubDock
        view.mirrored = dock.mirrored
        hover = RecordingHubHover()
        expansion = RecordingHubExpansion()
        capsule = dock.rect(size: RecordingHubLayout.size(mode: mode, progress: 0), in: area)
        applyGeometry()
        panel.alphaValue = hover.alpha
        refreshPreviewState()
        refreshElevation()
        present(panel)
    }

    func hide() {
        collapseTask?.cancel()
        collapseTask = nil
        stopMotion()
        panel.orderOut(nil)
    }

    func setElapsed(_ text: String?) { view.elapsed = text }

    func setMode(_ mode: RecordingHubMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        view.mode = mode
        applyGeometry()
    }

    /// Elapsed/pause updates must never turn an armed hub into a recording one — the arming
    /// pushes idle UI state while it waits for Başlat.
    func setRecordingMode(paused: Bool) {
        guard !mode.isArmed else { return }
        setMode(paused ? .paused : .recording)
    }

    /// The display the hub is currently on, and the view a display link can hang off.
    var screen: NSScreen? { panel.screen }
    var hostView: NSView { view }

    func setMicLevel(_ dbfs: Double?) {
        view.micLevel = RecordingHubLayout.micFraction(dbfs: dbfs)
    }

    /// Above a fullscreen game nothing at `.statusBar` is visible; the shielding level is
    /// the last one a nonactivating panel can reach.
    func setElevated(_ elevated: Bool) {
        let level = elevated ? GameOverlayElevation.shieldingLevel : NSWindow.Level.statusBar
        guard panel.level != level else { return }
        panel.level = level
    }

    var isHovering: Bool { hover.expanded }

    // MARK: - Hover

    private func setHovered(_ inside: Bool) {
        let now = CACurrentMediaTime()
        let wasExpanded = hover.expanded
        if inside {
            hover.pointerEntered(at: now)
            refreshElevation()
        } else {
            hover.pointerExited(at: now)
            scheduleCollapse()
        }
        if hover.expanded != wasExpanded { onHoverChange?(hover.expanded) }
        applyHover()
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(RecordingHubHover.collapseDelay * 1000)))
            guard !Task.isCancelled, let self else { return }
            let wasExpanded = self.hover.expanded
            self.hover.advance(to: CACurrentMediaTime())
            if self.hover.expanded != wasExpanded { self.onHoverChange?(self.hover.expanded) }
            self.applyHover()
        }
    }

    private func applyHover() {
        expansion.target = hover.expanded ? 1 : 0
        if Self.reducesMotion {
            expansion.finishImmediately()
            applyGeometry()
        } else {
            startMotion()
        }
        let alpha = hover.alpha
        guard panel.alphaValue != alpha else { return }
        if Self.reducesMotion {
            panel.alphaValue = alpha
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = alpha
            }
        }
    }

    private func refreshPreviewState() {
        view.previewVisible = CameraOverlayController.shared.previewVisible
    }

    /// Read-only use of the shared context: `covering()` rather than `current()` because
    /// clicking our own hub makes Camcord frontmost, which would hide the game behind it.
    private func refreshElevation() {
        let context = FullscreenContext.covering(at: capsule.center)
        setElevated(context.isGameLike)
    }

    // MARK: - Geometry

    private static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Resizes the capsule around its docked edge, so the identity cell stays put while
    /// the controls grow out of it, then clamps the whole thing inside the display.
    private func applyGeometry() {
        let size = RecordingHubLayout.size(mode: mode, progress: expansion.progress)
        let x: CGFloat
        switch dock {
        case .topRight, .bottomRight: x = capsule.maxX - size.width
        case .topCenter: x = capsule.midX - size.width / 2
        case .topLeft, .bottomLeft: x = capsule.minX
        }
        capsule = clamped(CGRect(x: x, y: capsule.midY - size.height / 2,
                                 width: size.width, height: size.height))
        let inset = RecordingHubLayout.shadowInset
        let frame = capsule.insetBy(dx: -inset, dy: -inset)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            view.frame = CGRect(origin: .zero, size: frame.size)
        }
        view.progress = expansion.progress
    }

    private func clamped(_ rect: CGRect) -> CGRect {
        guard area.width > rect.width, area.height > rect.height else { return rect }
        let margin = CameraOptions.margin(in: area.size)
        return CGRect(
            x: min(max(rect.minX, area.minX + margin), area.maxX - margin - rect.width),
            y: min(max(rect.minY, area.minY + margin), area.maxY - margin - rect.height),
            width: rect.width, height: rect.height
        )
    }

    // MARK: - Drag, dock and fling

    private func press(_ item: RecordingHubItem) {
        switch item {
        case .stop: onStop?()
        case .start: onStop?()
        case .pause: onPauseResume?()
        case .preview: onTogglePreview?()
        case .cancel: onCancel?()
        case .elapsed, .divider, .micLevel: break
        }
    }

    private func drag(_ phase: RecordingHubView.DragPhase, point: CGPoint) {
        switch phase {
        case .began:
            stopMotion()
            dragStart = (capsule, point)
            dragVelocity = .zero
            dragSample = (point, CACurrentMediaTime())
        case .changed, .ended:
            guard let start = dragStart else { return }
            capsule = clamped(start.capsule.offsetBy(dx: point.x - start.point.x,
                                                     dy: point.y - start.point.y))
            sampleVelocity(at: point)
            let inset = RecordingHubLayout.shadowInset
            panel.setFrameOrigin(capsule.insetBy(dx: -inset, dy: -inset).origin)
            if phase == .ended {
                dragStart = nil
                dragSample = nil
                land()
            }
        }
    }

    /// A smoothed pointer velocity in points per second, so the fling test sees the throw
    /// rather than the last frame's jitter.
    private func sampleVelocity(at point: CGPoint) {
        let now = CACurrentMediaTime()
        guard let previous = dragSample, now > previous.time else {
            dragSample = (point, now)
            return
        }
        let dt = now - previous.time
        let instant = CGPoint(x: (point.x - previous.point.x) / CGFloat(dt),
                              y: (point.y - previous.point.y) / CGFloat(dt))
        dragVelocity = CGPoint(x: dragVelocity.x * 0.35 + instant.x * 0.65,
                               y: dragVelocity.y * 0.35 + instant.y * 0.65)
        dragSample = (point, now)
    }

    private func land() {
        let landed = RecordingHubDock.dock(forDrop: capsule, velocity: dragVelocity, in: area)
        dock = landed
        view.mirrored = landed.mirrored
        persist(landed)
        let target = landed.rect(size: capsule.size, in: area).origin
        if Self.reducesMotion {
            capsule.origin = target
            applyGeometry()
            return
        }
        settle = (target, dragVelocity, hypot(target.x - capsule.minX, target.y - capsule.minY))
        startMotion()
    }

    private func persist(_ dock: RecordingHubDock) {
        var settings = RecordingSettings.load(from: defaults)
        guard settings.hubDock != dock else { return }
        settings.hubDock = dock
        settings.save(to: defaults)
        TriggerLog.overlay("hub dock=\(dock.rawValue)")
    }

    // MARK: - One display link for both springs

    private func startMotion() {
        guard motionLink == nil else { return }
        let proxy = HubMotionProxy(panel: self)
        let link = view.displayLink(target: proxy, selector: #selector(HubMotionProxy.step(_:)))
        let fps = Float(min(120, panel.screen?.maximumFramesPerSecond ?? 60))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, fps), maximum: fps, preferred: fps)
        motionProxy = proxy
        motionLink = link
        link.add(to: .main, forMode: .common)
    }

    private func stopMotion() {
        motionLink?.invalidate()
        motionLink = nil
        motionProxy = nil
        motionTimestamp = nil
        settle = nil
    }

    fileprivate func step(_ link: CADisplayLink) {
        let elapsed = link.timestamp - (motionTimestamp ?? link.timestamp - 1.0 / 120)
        motionTimestamp = link.timestamp
        if !expansion.isSettled { expansion.step(seconds: elapsed) }
        if var running = settle {
            let spring = CameraDragMotion.releasedSpring(distance: running.distance)
            var origin = capsule.origin
            CameraDragMotion.integrate(&origin, velocity: &running.velocity, toward: running.target,
                                       stiffness: spring.stiffness, damping: spring.damping,
                                       seconds: min(max(elapsed, 0), 1.0 / 30))
            capsule.origin = origin
            settle = running
            if hypot(running.target.x - origin.x, running.target.y - origin.y) < 0.12,
               hypot(running.velocity.x, running.velocity.y) < 2 {
                capsule.origin = running.target
                settle = nil
            }
        }
        applyGeometry()
        if expansion.isSettled, settle == nil { stopMotion() }
    }

    // MARK: - Offscreen test seams

    var panelForTesting: NSPanel { panel }
    var viewForTesting: RecordingHubView { view }
    var dockForTesting: RecordingHubDock { dock }

    func setHoveredForTesting(_ inside: Bool) { setHovered(inside) }
}

private final class HubMotionProxy: NSObject {
    private weak var panel: RecordingHubPanel?
    init(panel: RecordingHubPanel) { self.panel = panel }

    @MainActor
    @objc func step(_ link: CADisplayLink) { panel?.step(link) }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
