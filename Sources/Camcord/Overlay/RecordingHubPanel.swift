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

    /// Corners grow away from their edge; top-centre grows to both sides so the disc
    /// stays on the dock's centre.
    var growth: RecordingHubGrowth {
        switch self {
        case .topLeft, .bottomLeft: .leading
        case .topRight, .bottomRight: .trailing
        case .topCenter: .centered
        }
    }

    /// The point of the capsule that stays put while it opens and closes: the docked
    /// edge's middle, or the centre at top-centre. Every dock rect puts it at the same
    /// place whatever the capsule's width, which is what lets the settle spring aim at it
    /// while the capsule is still changing size.
    func anchor(of rect: CGRect) -> CGPoint {
        switch growth {
        case .leading: CGPoint(x: rect.minX, y: rect.midY)
        case .trailing: CGPoint(x: rect.maxX, y: rect.midY)
        case .centered: CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    /// A `size` capsule whose anchor is at `anchor`.
    func rect(size: CGSize, anchoredAt anchor: CGPoint) -> CGRect {
        let x: CGFloat
        switch growth {
        case .leading: x = anchor.x
        case .trailing: x = anchor.x - size.width
        case .centered: x = anchor.x - size.width / 2
        }
        return CGRect(x: x, y: anchor.y - size.height / 2, width: size.width, height: size.height)
    }

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

/// Where the hub docks for a target, kept pure. A recorded WINDOW puts the five docks inside
/// the window — the same model as the camera tile — so the controls sit on the thing being
/// recorded and follow it; a window too small to hold the open capsule falls back to its
/// display. The hub is never recorded there: a window capture sees only that window.
enum RecordingHubPlacement {
    /// The dock area: the window's frame clipped to its display's visible frame (so no dock
    /// sits under the menu bar or off screen), or the display's visible frame when there is no
    /// window or it cannot hold the open capsule plus a margin on each side.
    static func area(window: CGRect?, display: CGRect, mode: RecordingHubMode) -> CGRect {
        guard let window else { return display }
        let inside = window.intersection(display)
        guard !inside.isNull, !inside.isEmpty else { return display }
        let margin = CameraOptions.margin(in: inside.size)
        let widest = RecordingHubDock.allCases
            .map { RecordingHubLayout.expandedWidth(mode: mode, growth: $0.growth) }
            .max() ?? RecordingHubLayout.disc
        guard inside.width >= widest + margin * 2,
              inside.height >= RecordingHubLayout.disc + margin * 2 else { return display }
        return inside
    }

    /// The dock to rest on: `preferred`, unless the camera tile holds it — then the free dock
    /// nearest to it. A dock is held when the open capsule there would touch the tile. With
    /// every dock held, `preferred` wins; the hub's level keeps it above the tile.
    static func dock(
        preferred: RecordingHubDock,
        in area: CGRect,
        mode: RecordingHubMode,
        avoiding obstacle: CGRect?
    ) -> RecordingHubDock {
        guard let obstacle, !obstacle.isEmpty else { return preferred }
        func isFree(_ dock: RecordingHubDock) -> Bool {
            let open = RecordingHubLayout.size(mode: mode, progress: 1, growth: dock.growth)
            return !dock.rect(size: open, in: area).intersects(obstacle)
        }
        if isFree(preferred) { return preferred }
        let disc = CGSize(width: RecordingHubLayout.disc, height: RecordingHubLayout.disc)
        let from = preferred.rect(size: disc, in: area)
        return RecordingHubDock.allCases.filter(isFree).min {
            let a = $0.rect(size: disc, in: area), b = $1.rect(size: disc, in: area)
            return hypot(a.midX - from.midX, a.midY - from.midY) < hypot(b.midX - from.midX, b.midY - from.midY)
        } ?? preferred
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

/// The hub's own window: nonactivating, on every Space, above full-screen chrome and the
/// camera tile, and raised to the shielding level when a game owns the display — otherwise a
/// fullscreen game draws straight over the only way to stop a recording. Owns the drag (five
/// docks, the tile's magnet and fling rules) and the expansion spring.
@MainActor
final class RecordingHubPanel {
    typealias PanelPresenter = @MainActor (NSPanel) -> Void

    /// One above the camera tile, so a tile that shares a dock can never cover the hub.
    static let baseLevel = NSWindow.Level(rawValue: CameraOverlayController.baseLevel.rawValue + 1)

    /// The camera tile's frame on screen while it shows, for dock collisions.
    var tileFrame: () -> CGRect? = { CameraOverlayController.shared.visibleTileFrame }

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
    /// The dock the hub rests on now, and the one the owner chose (persisted): they differ
    /// only while the camera tile holds the chosen one.
    private var dock: RecordingHubDock = .topCenter
    private var preferredDock: RecordingHubDock = .topCenter
    /// The recorded window's frame (window targets only) and its display's visible frame;
    /// `area` is the dock area resolved from the two.
    private var windowFrame: CGRect?
    private var displayFrame: CGRect = .zero
    private var area: CGRect = .zero
    private var capsule: CGRect = .zero

    private var hover = RecordingHubHover()
    private var expansion = RecordingHubExpansion()
    private var collapseTask: Task<Void, Never>?

    private var motionLink: CADisplayLink?
    private var motionProxy: HubMotionProxy?
    private var motionTimestamp: CFTimeInterval?
    /// The released dock spring, run on the dock's ANCHOR rather than the capsule's origin
    /// so a hub that collapses while it settles still lands on its dock: where the anchor is
    /// going, how fast, and the throw distance the shared spring was chosen for.
    private var settle: (target: CGPoint, velocity: CGPoint, distance: CGFloat)?

    private var dragStart: (capsule: CGRect, point: CGPoint)?
    private var dragVelocity: CGPoint = .zero
    private var dragSample: (point: CGPoint, time: CFTimeInterval)?

    private var previewObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?

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
        panel.level = Self.baseLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        view.onHover = { [weak self] inside in self?.setHovered(inside) }
        view.onPress = { [weak self] item in self?.press(item) }
        view.onDrag = { [weak self] phase, point in self?.drag(phase, point: point) }
        previewObserver = NotificationCenter.default.addObserver(
            forName: CameraOverlayController.previewVisibilityDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPreviewState()
                // The tile appearing or leaving can free or take the hub's dock.
                if self.panel.isVisible { self.relayout() }
            }
        }
        // Entering and LEAVING a game are both app switches. Without this the level was
        // decided once, at show(), and on pointer-enter — and a hub that a game has covered
        // can never BE entered, so it could not recover for the rest of the recording.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.refreshElevation()
            }
        }
    }

    isolated deinit {
        collapseTask?.cancel()
        motionLink?.invalidate()
        if let previewObserver { NotificationCenter.default.removeObserver(previewObserver) }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    // MARK: - Presentation

    /// Shows the hub docked to `screen`, or — for a window target — inside `window`
    /// (AppKit coordinates) on that screen.
    func show(mode: RecordingHubMode, on screen: NSScreen?, window: CGRect? = nil) {
        // The VISIBLE frame: a hub resting on the live menu bar would eat clicks meant
        // for the status items.
        let display = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        presentHub(mode: mode, display: display, window: window)
    }

    /// The recorded window moved or resized: the docks move with it, and a hub at rest
    /// follows in the same frame, like the border. A hub being dragged keeps the pointer.
    func updateWindow(_ window: CGRect, on screen: NSScreen?) {
        guard windowFrame != nil else { return }
        windowFrame = window
        if let screen { displayFrame = screen.visibleFrame }
        relayout()
    }

    private func presentHub(mode: RecordingHubMode, display: CGRect, window: CGRect?) {
        self.mode = mode
        view.mode = mode
        displayFrame = display
        windowFrame = window
        preferredDock = RecordingSettings.load(from: defaults).hubDock
        hover = RecordingHubHover()
        expansion = RecordingHubExpansion()
        resolveDock()
        capsule = dock.rect(size: RecordingHubLayout.size(mode: mode, progress: 0, growth: dock.growth), in: area)
        applyGeometry()
        // The hub is a solid dark object at rest too: an idle dim made it read as pale grey.
        panel.alphaValue = 1
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
        let level = elevated ? GameOverlayElevation.shieldingLevel : Self.baseLevel
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

    /// Re-reads the area and the dock (window frame, display, camera tile).
    private func resolveDock() {
        area = RecordingHubPlacement.area(window: windowFrame, display: displayFrame, mode: mode)
        dock = RecordingHubPlacement.dock(preferred: preferredDock, in: area, mode: mode, avoiding: tileFrame())
        view.growth = dock.growth
    }

    /// Puts the hub back on its dock after the area or the tile changed: at once when it is
    /// at rest (it follows the window like the border does), by retargeting the spring when
    /// it is still settling, and not at all mid-drag.
    private func relayout() {
        resolveDock()
        guard dragStart == nil else { return }
        let target = dock.anchor(of: dock.rect(size: capsule.size, in: area))
        if var running = settle {
            running.target = target
            settle = running
            return
        }
        capsule = dock.rect(size: capsule.size, anchoredAt: target)
        applyGeometry()
    }

    private static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Resizes the capsule around its dock's anchor, so the identity cell stays put while
    /// the controls are uncovered around it, then clamps the whole thing inside the area.
    /// Top-centre grows to both sides: its cells are laid out from the centre, not the
    /// leading edge, so the symmetric growth moves no control under a stationary pointer.
    private func applyGeometry() {
        let size = RecordingHubLayout.size(mode: mode, progress: expansion.progress, growth: dock.growth)
        capsule = clamped(dock.rect(size: size, anchoredAt: dock.anchor(of: capsule)))
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

    private func drag(_ phase: RecordingHubView.DragPhase, point: CGPoint,
                      time: CFTimeInterval = CACurrentMediaTime()) {
        switch phase {
        case .began:
            stopMotion()
            dragStart = (capsule, point)
            dragVelocity = .zero
            dragSample = (point, time)
        case .changed, .ended:
            guard let start = dragStart else { return }
            capsule = clamped(start.capsule.offsetBy(dx: point.x - start.point.x,
                                                     dy: point.y - start.point.y))
            sampleVelocity(at: point, time: time)
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
    private func sampleVelocity(at point: CGPoint, time now: CFTimeInterval) {
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
        let dropped = RecordingHubDock.dock(forDrop: capsule, velocity: dragVelocity, in: area)
        // A drop onto the camera tile's dock rests on the nearest free one — and that is
        // what is remembered, because that is where the owner sees it land.
        let landed = RecordingHubPlacement.dock(preferred: dropped, in: area, mode: mode, avoiding: tileFrame())
        preferredDock = landed
        dock = landed
        view.growth = landed.growth
        persist(landed)
        // The anchor of a dock rect does not depend on the capsule's width, so this target
        // holds even if the hub collapses while it is still on its way.
        let target = landed.anchor(of: landed.rect(size: capsule.size, in: area))
        let anchor = landed.anchor(of: capsule)
        if Self.reducesMotion {
            capsule = landed.rect(size: capsule.size, anchoredAt: target)
            applyGeometry()
            return
        }
        settle = (target, dragVelocity, hypot(target.x - anchor.x, target.y - anchor.y))
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
            var anchor = dock.anchor(of: capsule)
            CameraDragMotion.integrate(&anchor, velocity: &running.velocity, toward: running.target,
                                       stiffness: spring.stiffness, damping: spring.damping,
                                       seconds: min(max(elapsed, 0), 1.0 / 30))
            settle = running
            if hypot(running.target.x - anchor.x, running.target.y - anchor.y) < 0.12,
               hypot(running.velocity.x, running.velocity.y) < 2 {
                anchor = running.target
                settle = nil
            }
            capsule = dock.rect(size: capsule.size, anchoredAt: anchor)
        }
        applyGeometry()
        if expansion.isSettled, settle == nil { stopMotion() }
    }

    // MARK: - Offscreen test seams

    var panelForTesting: NSPanel { panel }
    var viewForTesting: RecordingHubView { view }
    var dockForTesting: RecordingHubDock { dock }
    /// The drawn capsule, in screen coordinates.
    var capsuleForTesting: CGRect { capsule }

    func setHoveredForTesting(_ inside: Bool) { setHovered(inside) }

    /// `show` on an explicit display area (and window) instead of a real screen.
    func showForTesting(mode: RecordingHubMode, area: CGRect, window: CGRect? = nil) {
        presentHub(mode: mode, display: area, window: window)
    }

    func updateWindowForTesting(_ window: CGRect) { updateWindow(window, on: nil) }

    var areaForTesting: CGRect { area }

    /// A drag with explicit timestamps, so the fling test sees a real speed.
    func dragForTesting(_ phase: RecordingHubView.DragPhase, to point: CGPoint, at time: CFTimeInterval) {
        drag(phase, point: point, time: time)
    }

    /// Runs the collapse grace period out and both springs to rest, as the display link would.
    func settleForTesting() {
        hover.advance(to: .greatestFiniteMagnitude)
        expansion.target = hover.expanded ? 1 : 0
        expansion.finishImmediately()
        if let running = settle {
            capsule = dock.rect(size: capsule.size, anchoredAt: running.target)
        }
        stopMotion()
        applyGeometry()
    }
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
