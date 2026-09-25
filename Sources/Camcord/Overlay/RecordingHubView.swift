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
    static let button: CGFloat = 36
    static let dividerZone: CGFloat = 7
    static let meterZone: CGFloat = 24
    static let startLabelZone: CGFloat = 58
    static let trailing: CGFloat = 6
    /// The panel is grown by this on every side so the hub's own shadow has room inside
    /// it; the capsule itself is `bounds` inset by the same amount.
    static let shadowInset: CGFloat = 12
    static let dot: CGFloat = 6

    static func items(mode: RecordingHubMode) -> [RecordingHubItem] {
        mode.isArmed
            ? [.start, .divider, .cancel]
            : [.elapsed, .divider, .pause, .stop, .preview, .micLevel]
    }

    /// The identity cell — the one thing the hub shows while collapsed.
    static func identity(mode: RecordingHubMode) -> RecordingHubItem {
        mode.isArmed ? .start : .elapsed
    }

    static func width(of item: RecordingHubItem) -> CGFloat {
        switch item {
        case .elapsed: disc
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
        growth == .centered ? disc + 2 * centeredHalfWidth(mode: mode) : expandedWidth(mode: mode)
    }

    /// The capsule's width at a point in the expansion spring.
    static func width(mode: RecordingHubMode, progress: CGFloat, growth: RecordingHubGrowth = .leading) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        return disc + (expandedWidth(mode: mode, growth: growth) - disc) * clamped
    }

    static func size(mode: RecordingHubMode, progress: CGFloat, growth: RecordingHubGrowth = .leading) -> CGSize {
        CGSize(width: width(mode: mode, progress: progress, growth: growth), height: disc)
    }

    // MARK: Centred growth (the top-centre dock)

    /// The cells either side of the identity at top-centre, each list read left to right.
    /// Stop sits next to the time it ends; Başlat's label is part of its own cell.
    static func centeredItems(mode: RecordingHubMode) -> (left: [RecordingHubItem], right: [RecordingHubItem]) {
        mode.isArmed
            ? ([.cancel, .divider], [])
            : ([.pause, .stop, .divider], [.divider, .preview, .micLevel])
    }

    /// How far the capsule reaches either side of the disc's centre, beyond the disc: the
    /// longer side plus the end padding, on BOTH sides, so the disc's centre is the
    /// capsule's centre at every point of the spring.
    static func centeredHalfWidth(mode: RecordingHubMode) -> CGFloat {
        let split = centeredItems(mode: mode)
        let left = split.left.reduce(0) { $0 + width(of: $1) }
        let right = width(of: identity(mode: mode)) - disc + split.right.reduce(0) { $0 + width(of: $1) }
        return max(left, right) + trailing
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
        var leftEdge = center - disc / 2
        for item in split.left.reversed() {
            leftEdge -= width(of: item)
            cells.insert((item, CGRect(x: leftEdge, y: y, width: width(of: item), height: disc)), at: 0)
        }
        let identityRect = CGRect(x: center - disc / 2, y: y, width: width(of: identity), height: disc)
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

/// The round, hover-expanding recording hub. Collapsed it is a 44 pt disc showing the
/// elapsed time under one steady dot — never a blink. Hovering springs it open into a
/// capsule with pause, stop, the camera-preview eye and a mic level; the pointer leaving
/// closes it again. The capsule is a dark, tinted Liquid Glass surface (`NSGlassEffectView`)
/// with the cells drawn inside it; this view owns hit testing, hover and accessibility, and
/// lives in a nonactivating panel that the owner can drag to one of five docks.
@MainActor
final class RecordingHubView: NSView {
    enum DragPhase { case began, changed, ended }

    var onDrag: ((DragPhase, CGPoint) -> Void)?
    var onPress: ((RecordingHubItem) -> Void)?
    var onHover: ((Bool) -> Void)?

    var mode: RecordingHubMode = .recording {
        didSet { if mode != oldValue { refresh() } }
    }
    var elapsed: String? {
        didSet {
            guard elapsed != oldValue else { return }
            content.needsDisplay = true
            // The drawn label ticks every second while nothing about the geometry changes,
            // so the accessibility value has to be written here or VoiceOver reads the time
            // the hub had when it opened for the whole recording.
            setAccessibilityValue(elapsed)
        }
    }
    var previewVisible = false {
        didSet { if previewVisible != oldValue { refresh() } }
    }
    var micLevel: CGFloat = 0 {
        didSet {
            // The dot only exists in the expanded capsule; while collapsed this would be a
            // full repaint of the hub up to 30x a second, for the length of a recording.
            guard progress > 0.001, abs(micLevel - oldValue) > 0.04 else { return }
            content.needsDisplay = true
        }
    }
    /// 0 = disc, 1 = capsule. Driven by the panel's expansion spring.
    var progress: CGFloat = 0 {
        didSet { if progress != oldValue { refresh() } }
    }
    /// How the capsule grows out of the disc, from the dock the hub rests on.
    var growth: RecordingHubGrowth = .leading {
        didSet { if growth != oldValue { refresh() } }
    }
    /// True when the hub is docked against the right edge.
    private var mirrored: Bool { growth == .trailing }

    /// The glass's tint: toward near-black and strong enough that the hub reads as a solid
    /// dark object over any wallpaper or game, so the 11 pt time never competes for
    /// contrast. Interim — the palette comes from the design direction chosen in UI-2.
    static let glassTint = NSColor(calibratedWhite: 0.06, alpha: 0.72)
    /// The app's one hairline (`CamcordStyle.innerBorder`), resolved on dark chrome.
    private static let hairline = NSColor.labelColor.withAlphaComponent(0.09)
    private static let recordingTint = NSColor(CamcordStyle.recording)
    private static let accentTint = NSColor(CamcordStyle.accent)

    private var symbolCache: [String: NSImage] = [:]

    /// The capsule's surface. Liquid Glass draws its own edge and shadow.
    let glass = NSGlassEffectView()
    /// The cells, drawn inside the glass.
    private let content = HubContentView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // A HUD is dark in both appearances; fixing it here makes the glass, `labelColor`
        // and the hairline resolve as light marks on dark glass without a second palette.
        appearance = NSAppearance(named: .darkAqua)
        glass.style = .regular
        glass.tintColor = Self.glassTint
        content.owner = self
        glass.contentView = content
        addSubview(glass)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Kayıt merkezi")
        layoutGlass()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    /// The drawn capsule, inside the panel's shadow margin.
    var capsuleRect: CGRect {
        bounds.insetBy(dx: RecordingHubLayout.shadowInset, dy: RecordingHubLayout.shadowInset)
    }

    var cells: [(item: RecordingHubItem, rect: CGRect)] {
        let capsule = capsuleRect
        guard progress > 0.001 else {
            return [(RecordingHubLayout.identity(mode: mode), capsule)]
        }
        switch growth {
        case .centered:
            return RecordingHubLayout.centeredCells(mode: mode, center: capsule.midX, verticalCenter: capsule.midY)
        case .leading, .trailing:
            return RecordingHubLayout.cells(
                mode: mode,
                anchoredAt: mirrored ? capsule.maxX : capsule.minX,
                verticalCenter: capsule.midY,
                mirrored: mirrored
            )
        }
    }

    /// The control a press at `point` (view coordinates) fires. Cells never move while the
    /// capsule opens — it only uncovers them — and a control answers only once it is fully
    /// uncovered, so a click can only land on something that was already at rest under
    /// the pointer.
    func control(at point: CGPoint) -> RecordingHubItem? {
        guard progress > 0.001 else {
            return mode.isArmed ? .start : nil
        }
        let visible = capsuleRect.insetBy(dx: -0.5, dy: -0.5)
        return cells.first { $0.item.isControl && visible.contains($0.rect) && $0.rect.contains(point) }?.item
    }

    private func refresh() {
        layoutGlass()
        content.needsDisplay = true
        rebuildAccessibility()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutGlass()
    }

    /// The glass IS the capsule: same rect, fully round ends, redrawn with every spring step.
    private func layoutGlass() {
        let capsule = capsuleRect
        glass.isHidden = capsule.width < 1 || capsule.height < 1
        glass.frame = capsule
        glass.cornerRadius = capsule.height / 2
        content.frame = CGRect(origin: .zero, size: capsule.size)
    }

    // MARK: - Drawing

    /// Draws the cells in this view's coordinates; `HubContentView` translates into them.
    fileprivate func drawCells() {
        let capsule = capsuleRect
        guard capsule.width > 1, capsule.height > 1 else { return }
        let radius = capsule.height / 2
        let outline = NSBezierPath(roundedRect: capsule, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        let identity = RecordingHubLayout.identity(mode: mode)
        for cell in cells {
            draw(cell.item, in: cell.rect, alpha: cell.item == identity ? 1 : progress)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func draw(_ item: RecordingHubItem, in rect: CGRect, alpha: CGFloat) {
        guard alpha > 0.01 else { return }
        switch item {
        case .elapsed:
            drawElapsed(in: rect, alpha: alpha)
        case .start:
            let glyphZone = mirrored
                ? CGRect(x: rect.maxX - RecordingHubLayout.disc, y: rect.minY,
                         width: RecordingHubLayout.disc, height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY,
                         width: RecordingHubLayout.disc, height: rect.height)
            drawSymbol("play.fill", tint: Self.recordingTint, in: glyphZone, alpha: alpha)
            let labelZone = mirrored
                ? CGRect(x: rect.minX, y: rect.minY, width: RecordingHubLayout.startLabelZone, height: rect.height)
                : CGRect(x: glyphZone.maxX, y: rect.minY,
                         width: RecordingHubLayout.startLabelZone, height: rect.height)
            drawText("Başlat", font: .systemFont(ofSize: 12, weight: .semibold),
                     color: NSColor.labelColor, in: labelZone, alpha: progress)
        case .divider:
            Self.hairline.withAlphaComponent(0.09 * alpha).setStroke()
            let line = NSBezierPath()
            line.move(to: CGPoint(x: rect.midX, y: rect.minY + 11))
            line.line(to: CGPoint(x: rect.midX, y: rect.maxY - 11))
            line.lineWidth = 1
            line.stroke()
        case .pause:
            drawSymbol(mode == .paused ? "play.fill" : "pause.fill",
                       tint: NSColor.labelColor, in: rect, alpha: alpha)
        case .stop:
            drawSymbol("stop.fill", tint: Self.recordingTint, in: rect, alpha: alpha)
        case .preview:
            drawSymbol(previewVisible ? "eye.fill" : "eye.slash",
                       tint: previewVisible ? Self.accentTint : NSColor.secondaryLabelColor,
                       in: rect, alpha: alpha)
        case .micLevel:
            drawMicLevel(in: rect, alpha: alpha)
        case .cancel:
            drawSymbol("xmark", tint: NSColor.secondaryLabelColor, in: rect, alpha: alpha)
        }
    }

    /// One steady dot over the monospaced time. Recording fills the dot, paused hollows
    /// it — a shape difference, so the state does not rest on colour alone, and nothing
    /// pulses at any point.
    private func drawElapsed(in rect: CGRect, alpha: CGFloat) {
        let size = RecordingHubLayout.dot
        let dot = CGRect(x: rect.midX - size / 2, y: rect.midY + 5, width: size, height: size)
        let path = NSBezierPath(ovalIn: mode == .paused ? dot.insetBy(dx: 0.75, dy: 0.75) : dot)
        Self.recordingTint.withAlphaComponent(alpha).set()
        if mode == .paused {
            path.lineWidth = 1.5
            path.stroke()
        } else {
            path.fill()
        }
        let text = elapsed ?? "0:00"
        drawText(text, font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                 color: NSColor.labelColor,
                 in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.midY + 2 - rect.minY),
                 alpha: alpha)
    }

    /// A dot that grows with the microphone's level — the mic's own readout, so a dead
    /// input is visible without opening anything.
    private func drawMicLevel(in rect: CGRect, alpha: CGFloat) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let ring = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
        let outline = NSBezierPath(ovalIn: ring)
        Self.hairline.withAlphaComponent(0.22 * alpha).setStroke()
        outline.lineWidth = 1
        outline.stroke()
        let diameter = 3 + 5 * min(max(micLevel, 0), 1)
        let core = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                          width: diameter, height: diameter)
        Self.accentTint.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: core).fill()
    }

    private func drawSymbol(_ name: String, tint: NSColor, in rect: CGRect, alpha: CGFloat) {
        guard let image = symbol(name, tint: tint) else { return }
        let size = image.size
        let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                            width: size.width, height: size.height)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: alpha)
    }

    private func symbol(_ name: String, tint: NSColor) -> NSImage? {
        let key = "\(name)|\(tint.description)"
        if let cached = symbolCache[key] { return cached }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        let resolved = image.withSymbolConfiguration(configuration)
        symbolCache[key] = resolved
        return resolved
    }

    private func drawText(_ text: String, font: NSFont, color: NSColor, in rect: CGRect, alpha: CGFloat) {
        guard alpha > 0.01 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color.withAlphaComponent(alpha),
            .paragraphStyle: paragraph
        ])
        let height = attributed.size().height
        attributed.draw(in: CGRect(x: rect.minX, y: rect.midY - height / 2,
                                   width: rect.width, height: height))
    }

    // MARK: - Hit testing, hover and gestures

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return capsuleRect.contains(convert(point, from: superview)) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: capsuleRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self
        ))
    }

    override func layout() {
        super.layout()
        rebuildAccessibility()
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }

    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func resetCursorRects() { addCursorRect(capsuleRect, cursor: .pointingHand) }

    private var pressedItem: RecordingHubItem?
    private var downPoint: CGPoint?
    private var draggedBeyondSlop = false

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressedItem = control(at: point)
        downPoint = NSEvent.mouseLocation
        draggedBeyondSlop = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downPoint else { return }
        let now = NSEvent.mouseLocation
        if !draggedBeyondSlop {
            guard abs(now.x - downPoint.x) > 3 || abs(now.y - downPoint.y) > 3 else { return }
            draggedBeyondSlop = true
            onDrag?(.began, downPoint)
        }
        onDrag?(.changed, now)
    }

    override func mouseUp(with event: NSEvent) {
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
        case .start: "Başlat"
        case .pause: mode == .paused ? "Sürdür" : "Duraklat"
        case .stop: "Kaydı durdur"
        case .preview: previewVisible ? "Kamerayı kapat" : "Kamerayı göster"
        case .cancel: "İptal"
        case .elapsed: "Geçen süre"
        case .micLevel: "Mikrofon seviyesi"
        case .divider: ""
        }
    }
}

/// A pressable element for one hub cell, so VoiceOver reaches the controls the hub draws
/// itself.
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

/// The glass's content: a transparent layer the hub's cells are drawn into. It takes no
/// events — the hub view above it owns hit testing — and draws in the hub view's
/// coordinates so the cell maths stays in one place.
private final class HubContentView: NSView {
    weak var owner: RecordingHubView?

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }
        let offset = owner.capsuleRect.origin
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: -offset.x, yBy: -offset.y)
        transform.concat()
        owner.drawCells()
        NSGraphicsContext.restoreGraphicsState()
    }
}
