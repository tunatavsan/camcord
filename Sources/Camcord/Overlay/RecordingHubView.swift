import AppKit

/// What the hub is offering right now. `armed` is a window waiting for Başlat; the other
/// two are a live recording, which changes the glyphs but never the geometry.
enum RecordingHubMode: Equatable, Sendable {
    case armed
    case recording
    case paused

    var isArmed: Bool { self == .armed }
}

/// One cell of the hub. Only some of them answer a press — the elapsed readout, the
/// divider and the mic meter are readouts, not controls.
enum RecordingHubItem: Equatable, Sendable {
    case elapsed
    case start
    case divider
    case pause
    case stop
    case preview
    case micLevel
    case cancel

    var isControl: Bool {
        switch self {
        case .start, .pause, .stop, .preview, .cancel: true
        case .elapsed, .divider, .micLevel: false
        }
    }
}

/// Which way the capsule grows out of the disc. Corner docks grow away from their edge;
/// top-centre grows to both sides, so the disc stays on the dock's centre.
enum RecordingHubGrowth: Equatable, Sendable {
    /// Left-edge docks: the identity keeps the capsule's left edge.
    case leading
    /// Right-edge docks: the identity keeps the capsule's right edge.
    case trailing
    /// Top-centre: the identity keeps the capsule's centre.
    case centered
}

/// The hub's geometry, kept pure so the disc, the capsule and every hit target can be
/// measured in a test instead of on screen. The collapsed hub is one 44 pt disc holding
/// the identity cell; expanding lays the same cell against the docked edge and grows the
/// controls out of it, so nothing the owner was already reading moves.
enum RecordingHubLayout {
    /// A 44 pt disc: the platform's comfortable target, and small enough to live over a
    /// game without becoming furniture.
    static let disc: CGFloat = 44
    /// The collapsed recording hub: a pill with the live dot and the time, read at a glance.
    static let timePill: CGFloat = 84
    static let button: CGFloat = 36
    static let dividerZone: CGFloat = 9
    static let meterZone: CGFloat = 30
    static let startLabelZone: CGFloat = 68
    static let trailing: CGFloat = 6
    /// The panel is grown by this on every side so the hub's own shadow has room inside
    /// it; the capsule itself is `bounds` inset by the same amount.
    static let shadowInset: CGFloat = 12
    static let dot: CGFloat = 6

    static func items(mode: RecordingHubMode) -> [RecordingHubItem] {
        mode.isArmed
            ? [.start, .divider, .cancel, .preview]
            : [.elapsed, .divider, .pause, .stop, .preview, .micLevel]
    }

    /// The identity cell — the one thing the hub shows while collapsed.
    static func identity(mode: RecordingHubMode) -> RecordingHubItem {
        mode.isArmed ? .start : .elapsed
    }

    static func width(of item: RecordingHubItem) -> CGFloat {
        switch item {
        case .elapsed: timePill
        case .start: disc + startLabelZone
        case .divider: dividerZone
        case .pause, .stop, .preview, .cancel: button
        case .micLevel: meterZone
        }
    }

    static func expandedWidth(mode: RecordingHubMode) -> CGFloat {
        items(mode: mode).reduce(0) { $0 + width(of: $1) } + trailing
    }

    static func expandedWidth(mode: RecordingHubMode, growth: RecordingHubGrowth) -> CGFloat {
        growth == .centered ? 2 * centeredHalfWidth(mode: mode) : expandedWidth(mode: mode)
    }

    /// Collapsed, the hub is its identity cell: the time pill, or Başlat.
    static func collapsedWidth(mode: RecordingHubMode) -> CGFloat { width(of: identity(mode: mode)) }

    /// The capsule's width at a point in the expansion spring.
    static func width(mode: RecordingHubMode, progress: CGFloat, growth: RecordingHubGrowth = .leading) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        let collapsed = collapsedWidth(mode: mode)
        return collapsed + (expandedWidth(mode: mode, growth: growth) - collapsed) * clamped
    }

    static func size(mode: RecordingHubMode, progress: CGFloat, growth: RecordingHubGrowth = .leading) -> CGSize {
        CGSize(width: width(mode: mode, progress: progress, growth: growth), height: disc)
    }

    // MARK: Centred growth (the top-centre dock)

    /// The cells either side of the identity at top-centre, each list read left to right.
    /// Stop sits next to the time it ends; Başlat's label is part of its own cell.
    static func centeredItems(mode: RecordingHubMode) -> (left: [RecordingHubItem], right: [RecordingHubItem]) {
        mode.isArmed
            ? ([.cancel, .divider], [.divider, .preview])
            : ([.pause, .stop, .divider], [.divider, .preview, .micLevel])
    }

    /// How far the open capsule reaches either side of the identity's centre: half the
    /// identity plus the longer side plus the end padding, on BOTH sides, so the identity's
    /// centre is the capsule's centre at every point of the spring.
    static func centeredHalfWidth(mode: RecordingHubMode) -> CGFloat {
        let split = centeredItems(mode: mode)
        let left = split.left.reduce(0) { $0 + width(of: $1) }
        let right = split.right.reduce(0) { $0 + width(of: $1) }
        return width(of: identity(mode: mode)) / 2 + max(left, right) + trailing
    }

    /// Top-centre cells, fixed relative to the disc's centre: the identity cell is pinned at
    /// `center` and the others sit where they will rest, so the growing capsule only
    /// uncovers them and nothing ever slides under a stationary pointer.
    static func centeredCells(
        mode: RecordingHubMode,
        center: CGFloat,
        verticalCenter: CGFloat
    ) -> [(item: RecordingHubItem, rect: CGRect)] {
        let split = centeredItems(mode: mode)
        let identity = identity(mode: mode)
        let y = verticalCenter - disc / 2
        var cells: [(item: RecordingHubItem, rect: CGRect)] = []
        let identityRect = CGRect(x: center - width(of: identity) / 2, y: y, width: width(of: identity), height: disc)
        var leftEdge = identityRect.minX
        for item in split.left.reversed() {
            leftEdge -= width(of: item)
            cells.insert((item, CGRect(x: leftEdge, y: y, width: width(of: item), height: disc)), at: 0)
        }
        cells.append((identity, identityRect))
        var rightEdge = identityRect.maxX
        for item in split.right {
            cells.append((item, CGRect(x: rightEdge, y: y, width: width(of: item), height: disc)))
            rightEdge += width(of: item)
        }
        return cells
    }

    /// The expanded cells, laid out from the docked edge. `mirrored` is a hub docked
    /// against the right edge: the order flips so the capsule grows inward, away from the
    /// screen edge, and the identity cell still sits on the edge it is docked to.
    static func cells(
        mode: RecordingHubMode,
        anchoredAt edge: CGFloat,
        verticalCenter: CGFloat,
        mirrored: Bool
    ) -> [(item: RecordingHubItem, rect: CGRect)] {
        var offset: CGFloat = 0
        var cells: [(item: RecordingHubItem, rect: CGRect)] = []
        for item in items(mode: mode) {
            let width = width(of: item)
            let x = mirrored ? edge - offset - width : edge + offset
            cells.append((item, CGRect(x: x, y: verticalCenter - disc / 2, width: width, height: disc)))
            offset += width
        }
        return cells
    }

    /// A mic level as a 0…1 fill, on the same dBFS scale the panel's meter uses.
    static func micFraction(dbfs: Double?) -> CGFloat {
        guard let dbfs, dbfs.isFinite else { return 0 }
        return CGFloat(min(max((dbfs + 60) / 60, 0), 1))
    }
}


/// The recording hub in the app's language: a capsule of the window tray (its light frost, the
/// window rim, a shadow cast outside) carrying Liquid Glass chips. Collapsed it is one pill —
/// the live dot and the time, or Başlat; hovering grows the tray and uncovers pause, a red
/// glass stop, the camera and a live level, which never move while they are uncovered.
/// Hovering a chip raises and lights its symbol while the others step back, as everywhere.
///
/// The panel keeps one window the size of the open capsule: the growth is a layer change in
/// that window at the display's rate, never a window resize and never a redraw.
@MainActor
final class RecordingHubView: NSView {
    enum DragPhase { case began, changed, ended }

    var onDrag: ((DragPhase, CGPoint) -> Void)?
    var onPress: ((RecordingHubItem) -> Void)?
    var onHover: ((Bool) -> Void)?

    var mode: RecordingHubMode = .recording {
        didSet { if mode != oldValue { rebuildChips(); refresh() } }
    }
    var elapsed: String? {
        didSet {
            guard elapsed != oldValue else { return }
            chips[.elapsed]?.setText(elapsed ?? "0:00")
            // The time ticks every second while nothing about the geometry changes, so the
            // accessibility value is written here or VoiceOver reads a stale time.
            setAccessibilityValue(elapsed)
        }
    }
    var previewVisible = false {
        didSet {
            guard previewVisible != oldValue else { return }
            chips[.preview]?.setSymbol(previewVisible ? "video.fill" : "video.slash.fill", color: .white)
            rebuildAccessibility()
        }
    }
    var micLevel: CGFloat = 0 {
        didSet { if abs(micLevel - oldValue) > 0.02 { meter.setLevel(micLevel) } }
    }
    /// 0 = disc, 1 = capsule. Driven by the panel's expansion spring.
    var progress: CGFloat = 0 {
        didSet { if progress != oldValue { refresh() } }
    }
    /// How the capsule grows out of the disc, from the dock the hub rests on.
    var growth: RecordingHubGrowth = .leading {
        didSet { if growth != oldValue { refresh() } }
    }
    private var mirrored: Bool { growth == .trailing }

    private let content = HubContent()
    /// The tray reads as the app's frame over anything: a touch of tint, the rim, a real shadow.
    private lazy var surface = TraySurface(content: content, shadowRadius: 11, cornerRadius: nil,
                                           tint: NSColor.black.withAlphaComponent(0.16))
    private var chips: [RecordingHubItem: HubChip] = [:]
    private var dividers: [CALayer] = []
    private let meter = HubBars()
    private var focus: RecordingHubItem?
    private var tracking: NSTrackingArea?
    /// Glass tints: dark for every chip, the record red for stop and Başlat.
    private static let neutral = NSColor.black.withAlphaComponent(0.18)
    private static let red = Theme.Palette.record.ns.withAlphaComponent(0.62)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // A HUD reads as light marks on dark glass in both appearances.
        appearance = NSAppearance(named: .darkAqua)
        addSubview(surface)
        content.layer?.addSublayer(meter)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Kayıt merkezi")
        rebuildChips()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refresh()
    }

    /// The capsule as it is now: its width from the spring, held against the edge (or the
    /// centre) it grows from, inside the panel's shadow margin.
    var capsuleRect: CGRect {
        let inset = RecordingHubLayout.shadowInset
        let full = bounds.insetBy(dx: inset, dy: inset)
        let width = min(full.width, RecordingHubLayout.width(mode: mode, progress: progress, growth: growth))
        let x: CGFloat
        switch growth {
        case .leading: x = full.minX
        case .trailing: x = full.maxX - width
        case .centered: x = full.midX - width / 2
        }
        return CGRect(x: x, y: full.minY, width: max(0, width), height: full.height)
    }

    var cells: [(item: RecordingHubItem, rect: CGRect)] {
        let capsule = capsuleRect
        guard progress > 0.001 else {
            return [(RecordingHubLayout.identity(mode: mode), capsule)]
        }
        return restingCells
    }

    /// Where every cell rests in the open capsule — the same at every point of the spring.
    private var restingCells: [(item: RecordingHubItem, rect: CGRect)] {
        let capsule = capsuleRect
        switch growth {
        case .centered:
            return RecordingHubLayout.centeredCells(mode: mode, center: capsule.midX, verticalCenter: capsule.midY)
        case .leading, .trailing:
            return RecordingHubLayout.cells(mode: mode, anchoredAt: mirrored ? capsule.maxX : capsule.minX,
                                            verticalCenter: capsule.midY, mirrored: mirrored)
        }
    }

    /// The control a press at `point` (view coordinates) fires. A control answers only once
    /// it is fully uncovered, so a click can only land on something already at rest.
    func control(at point: CGPoint) -> RecordingHubItem? {
        guard progress > 0.001 else { return mode.isArmed ? .start : nil }
        let visible = capsuleRect.insetBy(dx: -0.5, dy: -0.5)
        return cells.first { $0.item.isControl && visible.contains($0.rect) && $0.rect.contains(point) }?.item
    }

    // MARK: - Chips

    private func rebuildChips() {
        chips.values.forEach { $0.removeFromSuperview() }
        chips = [:]
        dividers.forEach { $0.removeFromSuperlayer() }
        dividers = []
        let items = Set(RecordingHubLayout.items(mode: mode)).union(RecordingHubLayout.centeredItems(mode: mode).left)
        for item in items {
            switch item {
            case .elapsed:
                let chip = HubChip(kind: .identity, symbol: nil, tint: Self.neutral)
                chip.setText(elapsed ?? "0:00")
                // Paused stills and hollows the dot: the state never rests on colour alone.
                chip.setRecording(mode == .recording)
                chips[item] = chip
            case .start:
                let chip = HubChip(kind: .start, symbol: "play.fill", tint: Self.red)
                chip.setText(String(localized: "Start"))
                chips[item] = chip
            case .pause:
                chips[item] = HubChip(kind: .button, symbol: mode == .paused ? "play.fill" : "pause.fill", tint: Self.neutral)
            case .stop:
                chips[item] = HubChip(kind: .button, symbol: "stop.fill", tint: Self.red)
            case .preview:
                chips[item] = HubChip(kind: .button, symbol: previewVisible ? "video.fill" : "video.slash.fill", tint: Self.neutral)
            case .cancel:
                chips[item] = HubChip(kind: .button, symbol: "xmark", tint: Self.neutral)
            case .divider, .micLevel:
                break
            }
        }
        for chip in chips.values { content.addSubview(chip) }
        meter.isHidden = mode.isArmed
        rebuildAccessibility()
    }

    /// One spring step: the tray's frame, and each chip's place and how uncovered it is.
    /// Only layer geometry changes; nothing is redrawn.
    private func refresh() {
        let capsule = capsuleRect
        surface.isHidden = capsule.width < 1 || capsule.height < 1
        if surface.frame != capsule { surface.frame = capsule }
        content.layer?.cornerRadius = capsule.height / 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let identity = RecordingHubLayout.identity(mode: mode)
        var dividerIndex = 0
        for cell in restingCells {
            let local = cell.rect.offsetBy(dx: -capsule.minX, dy: -capsule.minY)
            // How much of the cell the capsule has uncovered: 0 hidden, 1 at rest.
            let covered = cell.item == identity ? 1 : max(0, min(1, capsule.intersection(cell.rect).width / max(cell.rect.width, 1)))
            let shown = covered * covered
            switch cell.item {
            case .divider:
                let line = divider(at: dividerIndex); dividerIndex += 1
                line.frame = CGRect(x: local.midX - 0.5, y: local.midY - 11, width: 1, height: 22)
                line.opacity = Float(shown)
            case .micLevel:
                meter.frame = CGRect(x: local.midX - 10, y: local.midY - 9, width: 20, height: 18)
                meter.opacity = Float(shown)
            default:
                guard let chip = chips[cell.item] else { continue }
                let frame = chip.kind.frame(in: local, mirrored: mirrored)
                if chip.frame != frame { chip.frame = frame }
                chip.layer?.opacity = Float(shown)
            }
        }
        for extra in dividers.dropFirst(dividerIndex) { extra.opacity = 0 }
        CATransaction.commit()
        if progress <= 0.001 { setFocus(nil) }
        rebuildAccessibility()
    }

    private func divider(at index: Int) -> CALayer {
        while dividers.count <= index {
            let line = CALayer()
            line.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
            content.layer?.addSublayer(line)
            dividers.append(line)
        }
        return dividers[index]
    }

    /// One chip in focus at a time; the others step back.
    private func setFocus(_ item: RecordingHubItem?) {
        guard item != focus else { return }
        focus = item
        for (key, chip) in chips where chip.kind != .identity {
            chip.setFocus(item.map { $0 == key }, screen: window?.screen)
        }
    }

    // MARK: - Hit testing, hover and gestures

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return capsuleRect.contains(convert(point, from: superview)) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // The whole window: hover is decided against the capsule as it is right now.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        tracking = area; addTrackingArea(area)
    }

    private var pointerInside = false
    private func updatePointer(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inside = capsuleRect.contains(point)
        if inside != pointerInside {
            pointerInside = inside
            onHover?(inside)
        }
        setFocus(inside ? control(at: point) : nil)
    }
    override func mouseEntered(with event: NSEvent) { updatePointer(event) }
    override func mouseMoved(with event: NSEvent) { updatePointer(event) }
    override func mouseExited(with event: NSEvent) {
        if pointerInside { pointerInside = false; onHover?(false) }
        setFocus(nil)
    }

    override func resetCursorRects() { addCursorRect(capsuleRect, cursor: .pointingHand) }

    private var pressedItem: RecordingHubItem?
    private var downPoint: CGPoint?
    private var draggedBeyondSlop = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressedItem = control(at: point)
        if let pressedItem { chips[pressedItem]?.setPressed(true, screen: window?.screen) }
        downPoint = NSEvent.mouseLocation
        draggedBeyondSlop = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downPoint else { return }
        let now = NSEvent.mouseLocation
        if !draggedBeyondSlop {
            guard abs(now.x - downPoint.x) > 3 || abs(now.y - downPoint.y) > 3 else { return }
            draggedBeyondSlop = true
            if let pressedItem { chips[pressedItem]?.setPressed(false, screen: window?.screen) }
            onDrag?(.began, downPoint)
        }
        onDrag?(.changed, now)
    }

    override func mouseUp(with event: NSEvent) {
        if let pressedItem { chips[pressedItem]?.setPressed(false, screen: window?.screen) }
        if draggedBeyondSlop {
            onDrag?(.ended, NSEvent.mouseLocation)
        } else if let pressedItem, control(at: convert(event.locationInWindow, from: nil)) == pressedItem {
            onPress?(pressedItem)
        }
        pressedItem = nil
        downPoint = nil
        draggedBeyondSlop = false
    }

    /// Test seam: the press path without an NSEvent.
    func pressForTesting(_ item: RecordingHubItem) { onPress?(item) }

    // MARK: - Accessibility

    private func rebuildAccessibility() {
        setAccessibilityValue(elapsed)
        var elements: [Any] = []
        let controls = cells.filter { $0.item.isControl }
        let visible = controls.isEmpty
            ? [(item: mode.isArmed ? RecordingHubItem.start : .stop, rect: capsuleRect)]
            : controls
        for cell in visible {
            let element = HubControlElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(Self.label(for: cell.item, mode: mode, previewVisible: previewVisible))
            element.setAccessibilityFrameInParentSpace(cell.rect)
            let item = cell.item
            element.press = { [weak self] in self?.onPress?(item) }
            elements.append(element)
        }
        setAccessibilityChildren(elements)
    }

    static func label(for item: RecordingHubItem, mode: RecordingHubMode, previewVisible: Bool) -> String {
        switch item {
        case .start: String(localized: "Start")
        case .pause: mode == .paused ? String(localized: "Resume") : String(localized: "Pause")
        case .stop: "Kaydı durdur"
        case .preview: previewVisible ? "Kamerayı kapat" : "Kamerayı göster"
        case .cancel: String(localized: "Cancel")
        case .elapsed: "Geçen süre"
        case .micLevel: "Mikrofon seviyesi"
        case .divider: ""
        }
    }
}

/// A pressable element for one hub cell, so VoiceOver reaches the controls the hub draws itself.
private final class HubControlElement: NSAccessibilityElement {
    var press: (@MainActor () -> Void)?

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        MainActor.assumeIsolated { press() }
        return true
    }
}

/// The tray's content: clipped to the capsule, so growth uncovers the chips. Takes no events.
private final class HubContent: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One Liquid Glass chip on the hub: a round button, the time pill, or Başlat's pill.
@MainActor final class HubChip: NSView {
    enum Kind {
        case button, identity, start
        /// The chip's frame inside its cell (content coordinates).
        func frame(in cell: CGRect, mirrored: Bool) -> CGRect {
            switch self {
            // A ring of tray shows around every chip, as around the panel's cells.
            case .button: CGRect(x: cell.midX - 15, y: cell.midY - 15, width: 30, height: 30)
            case .identity, .start: cell.insetBy(dx: 6, dy: 6)
            }
        }
    }
    let kind: Kind
    private let glass = NSGlassEffectView()
    private let face = NSView()
    /// Hover lifts this; the press scales `press` inside it, so the two never fight.
    private let press = CALayer()
    private let lift = CALayer()
    private let icon = CALayer()
    private let label = CATextLayer()
    private let dot = CALayer()
    private let ring = CALayer()
    private let tint: NSColor
    private var focus: Bool?

    init(kind: Kind, symbol: String?, tint: NSColor, symbolColor: NSColor = .white) {
        self.kind = kind
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        glass.style = .clear
        glass.tintColor = tint
        face.wantsLayer = true
        // A coloured chip is the panel's Record red, solid inside the glass, with its light rim.
        if tint.alphaComponent > 0.5 {
            face.layer?.backgroundColor = Theme.Palette.record.ns.withAlphaComponent(0.92).cgColor
            face.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            face.layer?.borderWidth = 1
        }
        glass.contentView = face
        addSubview(glass)
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        icon.contentsScale = scale
        icon.shadowColor = NSColor.white.cgColor
        icon.shadowOpacity = 0
        icon.shadowRadius = 6
        icon.shadowOffset = .zero
        lift.addSublayer(icon)
        press.addSublayer(lift)
        face.layer?.addSublayer(press)
        label.contentsScale = scale
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = kind == .identity ? .left : .left
        label.shadowColor = NSColor.black.cgColor
        label.shadowOpacity = 0.35
        label.shadowRadius = 2
        label.shadowOffset = .zero
        face.layer?.addSublayer(label)
        if kind == .identity {
            ring.backgroundColor = Theme.Palette.record.ns.cgColor
            ring.opacity = 0
            face.layer?.addSublayer(ring)
            face.layer?.addSublayer(dot)
            label.font = Theme.Font.ns.mono(13, weight: .semibold)
            label.fontSize = 13
        } else {
            label.font = Theme.Font.ns.text(14, weight: .semibold)
            label.fontSize = 14
        }
        if let symbol { setSymbol(symbol, color: symbolColor) }
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setSymbol(_ name: String, color: NSColor) {
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        icon.contents = InkCenteredSymbol.render(name, pointSize: kind == .start ? 15 : 13, weight: .semibold,
                                                 canvas: 22, scale: scale, color: color)
    }
    func setText(_ text: String) { label.string = text }

    /// Recording: a solid dot with a ring that keeps leaving it. Paused: a still, hollow dot.
    func setRecording(_ recording: Bool) {
        let red = Theme.Palette.record.ns.cgColor
        dot.backgroundColor = recording ? red : NSColor.clear.cgColor
        dot.borderColor = red
        dot.borderWidth = recording ? 0 : 1.5
        ring.removeAllAnimations()
        guard recording, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 1; grow.toValue = 2.4
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.55; fade.toValue = 0
        let pulse = CAAnimationGroup()
        pulse.animations = [grow, fade]
        pulse.duration = 1.4
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulse.repeatCount = .infinity
        ring.add(pulse, forKey: "pulse")
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        glass.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        face.layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        layer?.masksToBounds = false
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: min(bounds.width, bounds.height) / 2,
                                   cornerHeight: min(bounds.width, bounds.height) / 2, transform: nil)
        let iconBox: CGRect
        switch kind {
        case .button:
            iconBox = bounds
        case .identity:
            iconBox = .zero
            let center = CGPoint(x: 15, y: bounds.midY)
            for layer in [dot, ring] {
                layer.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
                layer.cornerRadius = 4
                layer.position = center
            }
            label.frame = CGRect(x: 26, y: (bounds.height - 17) / 2, width: bounds.width - 30, height: 17)
        case .start:
            iconBox = CGRect(x: 2, y: 0, width: bounds.height, height: bounds.height)
            label.frame = CGRect(x: iconBox.maxX - 2, y: (bounds.height - 18) / 2, width: bounds.width - iconBox.maxX, height: 18)
        }
        press.frame = iconBox
        lift.frame = press.bounds
        icon.frame = CGRect(x: lift.bounds.midX - 11, y: lift.bounds.midY - 11, width: 22, height: 22)
        CATransaction.commit()
    }

    /// Hover blooms like the panel's Record, Start and Open: the symbol swells a little on a
    /// spring and the chip glows in its own colour. Nothing rises and nothing steps back.
    func setFocus(_ focus: Bool?, screen: NSScreen?) {
        let lifted = focus == true
        let was = self.focus == true
        self.focus = focus
        guard lifted != was, let layer else { return }
        let glowColor = tint.alphaComponent > 0.5 ? Theme.Palette.record.ns : NSColor.white
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let from = lift.presentation()?.transform ?? lift.transform
        lift.transform = lifted ? CATransform3DMakeScale(1.14, 1.14, 1) : CATransform3DIdentity
        let swell = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: from),
                                           to: NSValue(caTransform3D: lift.transform), response: 0.3, dampingRatio: lifted ? 0.55 : 0.8)
        swell.preferFullRefreshRate(on: screen)
        lift.add(swell, forKey: "hub-swell")
        layer.shadowColor = glowColor.cgColor
        layer.shadowRadius = 10
        layer.shadowOffset = .zero
        let fromGlow = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
        layer.shadowOpacity = lifted ? 0.6 : 0
        let glow = CABasicAnimation(keyPath: "shadowOpacity")
        glow.fromValue = fromGlow; glow.toValue = layer.shadowOpacity; glow.duration = lifted ? 0.16 : 0.22
        glow.preferFullRefreshRate(on: screen)
        layer.add(glow, forKey: "hub-glow")
        let fromIcon = icon.presentation()?.shadowOpacity ?? icon.shadowOpacity
        icon.shadowOpacity = lifted ? 0.7 : 0
        let iconGlow = CABasicAnimation(keyPath: "shadowOpacity")
        iconGlow.fromValue = fromIcon; iconGlow.toValue = icon.shadowOpacity; iconGlow.duration = 0.16
        icon.add(iconGlow, forKey: "hub-icon-glow")
        CATransaction.commit()
    }

    func setPressed(_ down: Bool, screen: NSScreen?) {
        let from = press.presentation()?.transform ?? press.transform
        let to = down ? CATransform3DMakeScale(0.86, 0.86, 1) : CATransform3DIdentity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        press.transform = to
        let motion = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: to),
                                            response: down ? 0.16 : 0.32, dampingRatio: down ? 1 : 0.6)
        motion.preferFullRefreshRate(on: screen)
        press.add(motion, forKey: "hub-press")
        CATransaction.commit()
    }
}

/// The microphone's level as four live bars, each at its own share of the level, moved by the
/// render server in short steps.
private final class HubBars: CALayer {
    private let bars = (0..<4).map { _ in CALayer() }
    private static let shares: [CGFloat] = [0.55, 1, 0.8, 0.45]
    private var level: CGFloat = 0
    override init() {
        super.init()
        for bar in bars {
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = 1.5
            addSublayer(bar)
        }
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }
    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        place()
        CATransaction.commit()
    }
    private func place() {
        let width: CGFloat = 3, gap: CGFloat = 2.5
        let total = width * 4 + gap * 3
        for (index, bar) in bars.enumerated() {
            let height = max(3, bounds.height * (0.18 + 0.82 * level * Self.shares[index]))
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            bar.position = CGPoint(x: bounds.midX - total / 2 + width / 2 + CGFloat(index) * (width + gap), y: bounds.midY)
            bar.opacity = Float(0.45 + 0.55 * min(1, level * 1.4))
        }
    }
    func setLevel(_ level: CGFloat) {
        self.level = min(max(level, 0), 1)
        CATransaction.begin(); CATransaction.setAnimationDuration(0.09)
        place()
        CATransaction.commit()
    }
}
