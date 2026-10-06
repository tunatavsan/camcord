import AppKit
import ApplicationServices
import CoreGraphics
import CoreImage
import QuartzCore

/// The floating HUD beside the scroll region during a scrolling capture: the stitched image
/// growing in real time (tailing the newest rows at the bottom), its state, an auto-scroll
/// toggle and Done / Cancel. It stands on the app's tray like the recording hub. Living in
/// its own nonactivating panel, excluded from the capture, it never steals scroll focus from
/// the target. Where there is no room beside the region it becomes a compact capsule.
@MainActor
final class ScrollPreviewPanel {
    struct Placement: Equatable {
        let tray: CGRect
        let compact: Bool
    }

    private var panel: NSPanel?
    private var content: ScrollPreviewView?

    /// The tray itself; the window adds room around it for its shadow.
    static let traySize = CGSize(width: 236, height: 392)
    /// Without room beside the region: the controls and the state, no preview.
    static let compactSize = CGSize(width: 440, height: 56)
    static let margin: CGFloat = 26

    func show(
        near region: CGRect,
        onDone: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onToggleAuto: @escaping () -> Void
    ) {
        hide(animated: false)
        let primaryH = NSScreen.screens.first?.frame.height ?? region.height
        let regionAK = Geometry.cgToAppKit(region, primaryScreenHeight: primaryH)
        let screen = NSScreen.screens.first { $0.frame.intersects(regionAK) } ?? NSScreen.main
        let placement = Self.placement(near: regionAK, visible: screen?.visibleFrame ?? regionAK)
        let frame = placement.tray.insetBy(dx: -Self.margin, dy: -Self.margin)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the tray casts its own, only outside itself
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Wherever it landed, the user can carry it aside by its tray.
        panel.isMovableByWindowBackground = true
        // Like the recording hub: white controls on a tinted tray, whatever is behind it.
        panel.appearance = NSAppearance(named: .darkAqua)

        let view = ScrollPreviewView(frame: CGRect(origin: .zero, size: frame.size), margin: Self.margin,
                                     compact: placement.compact)
        view.onDone = onDone
        view.onCancel = onCancel
        view.onToggleAuto = onToggleAuto
        panel.contentView = view
        panel.orderFrontRegardless()
        view.arrive()
        self.panel = panel
        self.content = view
    }

    func update(image: CGImage?, sections: Int) {
        content?.update(image: image, sections: sections)
    }

    /// Reflects the auto-scroll state in the toggle and the status chip.
    func setAuto(running: Bool, reachedEnd: Bool) {
        content?.setAuto(running: running, reachedEnd: reachedEnd)
    }

    /// Auto-scroll is on its way up to the top of the page before it captures down.
    func setClimbing(_ climbing: Bool) {
        content?.setClimbing(climbing)
    }

    /// Done was pressed: the last frame and the final image are on their way.
    func setFinishing() {
        content?.setFinishing()
    }

    /// Shows a transient message in the status chip; a warning carries the warning mark.
    func flashHint(_ message: String, warning: Bool = true) {
        content?.flashHint(message, warning: warning)
    }

    /// Leaves the way it arrived, unless it is being replaced at once.
    func hide(animated: Bool = true) {
        guard let panel else { return }
        let view = content
        self.panel = nil
        content = nil
        guard animated, let view else { panel.orderOut(nil); return }
        view.leave { panel.orderOut(nil) }
    }

    /// Where the HUD stands, in AppKit coordinates. The full tray goes OUTSIDE the region —
    /// right, else left, else below, else above — fully inside the screen's visible frame
    /// (clear of the menu bar and the Dock). Without room for it, the compact capsule goes
    /// below or above the region; failing that, inside its lower edge — the capture filter
    /// excludes our own windows, so even an overlap can't reach the shot.
    static func placement(near region: CGRect, visible: CGRect) -> Placement {
        let gap: CGFloat = 18
        let w = traySize.width, h = traySize.height
        // Beside the region the tray only has to stay on screen vertically: tops aligned
        // where possible, slid up or down where the region sits near an edge.
        let besideY = min(max(region.maxY - h, visible.minY + 8), visible.maxY - h - 8)
        let candidates: [CGRect] = [
            CGRect(x: region.maxX + gap, y: besideY, width: w, height: h),
            CGRect(x: region.minX - gap - w, y: besideY, width: w, height: h),
            CGRect(x: region.midX - w / 2, y: region.minY - gap - h, width: w, height: h),
            CGRect(x: region.midX - w / 2, y: region.maxY + gap, width: w, height: h),
        ]
        for c in candidates where visible.contains(c) && !c.intersects(region) { return Placement(tray: c, compact: false) }

        let cw = min(compactSize.width, visible.width - 16), ch = compactSize.height
        func centred(_ y: CGFloat) -> CGRect {
            let x = min(max(region.midX - cw / 2, visible.minX + 8), visible.maxX - cw - 8)
            return CGRect(x: x, y: y, width: cw, height: ch)
        }
        for c in [centred(region.minY - gap - ch), centred(region.maxY + gap)]
        where visible.contains(c) && !c.intersects(region) {
            return Placement(tray: c, compact: true)
        }
        let floor = max(region.minY, visible.minY) + 24
        return Placement(tray: centred(min(floor, visible.maxY - ch - 8)), compact: true)
    }
}

/// The HUD: the tray, the growing capture on it and a glass cell of controls below; or, in
/// the compact capsule, the controls and the state alone.
private final class ScrollPreviewView: NSView {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggleAuto: (() -> Void)?

    private let margin: CGFloat
    private let compact: Bool
    /// The full tray's capture; the compact capsule has none.
    private let well: ScrollHUDWell?
    private let status = ScrollHUDStatusChip()
    private let cancelButton = ScrollHUDIconButton(symbol: "xmark", title: String(localized: "Cancel"))
    private let autoButton = ScrollHUDIconButton(symbol: "arrow.down.circle", title: String(localized: "Scroll for me"))
    private let doneButton = ScrollHUDPill(title: String(localized: "Done"), symbol: "checkmark")
    private let surface: TraySurface

    // Status state (precedence: finishing > transient hint > hovered control > auto-running >
    // end-reached > the prompt > sections).
    private var sections = 0
    /// Images received. The first is the page as it stands; any later one means it moved.
    private var updates = 0
    private var autoRunning = false
    private var climbing = false
    private var endReached = false
    /// Once the page end was reached, auto never runs again in this session.
    private var autoEnded = false
    private var finishing = false
    private var hint: (text: String, warning: Bool)?
    private var hintGeneration = 0
    private var hoverControl: ScrollHUDFocusable?
    /// Leaving a control waits a beat before the HUD lets go of it, so moving from one control
    /// to the next goes straight across instead of flashing the state in between.
    private var hoverRelease = 0
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Esc and synthesized scrolling both need the app to be trusted for Accessibility.
    private var trusted: Bool { AXIsProcessTrusted() }

    init(frame frameRect: NSRect, margin: CGFloat, compact: Bool) {
        self.margin = margin
        self.compact = compact
        let tint = NSColor.black.withAlphaComponent(0.16)
        let controls: [NSView] = [cancelButton, autoButton]
        // The tray is a ring; on it stand cards of Liquid Glass, the Dock's own material, so
        // what lies behind the HUD stays behind it: the capture in one, the controls with a
        // full-size Done in another.
        if compact {
            well = nil
            let body = ScrollHUDCard()
            body.contentView = ScrollHUDCompactLayout(leading: controls, status: status, trailing: doneButton)
            surface = TraySurface(content: ScrollHUDTray(cards: [body], capsule: true), shadowRadius: 10, cornerRadius: nil, tint: tint)
        } else {
            let well = ScrollHUDWell(status: status)
            self.well = well
            let capture = ScrollHUDCard()
            capture.contentView = ScrollHUDWellHolder(well: well)
            let row = ScrollHUDControls()
            row.place(leading: controls, trailing: doneButton)
            let controlsCard = ScrollHUDCard()
            controlsCard.contentView = row
            surface = TraySurface(content: ScrollHUDTray(cards: [capture, controlsCard], capsule: false), shadowRadius: 10,
                                  cornerRadius: ScrollHUDTray.radius, tint: tint)
        }
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(surface)
        cancelButton.action = { [weak self] in self?.onCancel?() }
        autoButton.action = { [weak self] in self?.onToggleAuto?() }
        doneButton.action = { [weak self] in
            guard let self, !self.finishing else { return }
            self.onDone?()
        }
        // One control in focus at a time: the others step back, and the chip names it.
        let all: [ScrollHUDFocusable] = [cancelButton, autoButton, doneButton]
        for control in all {
            control.onHover = { [weak self, weak control] inside in
                guard let self, let control else { return }
                self.hoverRelease &+= 1
                if inside {
                    for other in all { other.setFocus(other === control, reduceMotion: self.reduceMotion) }
                    self.hoverControl = control === self.doneButton ? nil : control
                    self.refreshStatus()
                    return
                }
                let release = self.hoverRelease
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    guard let self, self.hoverRelease == release else { return }
                    for other in all { other.setFocus(nil, reduceMotion: self.reduceMotion) }
                    self.hoverControl = nil
                    self.refreshStatus()
                }
            }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Scroll capture"))
        refreshAuto()
        refreshStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        surface.frame = bounds.insetBy(dx: margin, dy: margin)
    }

    // MARK: Arrival and leaving — quiet, and the same path both ways.

    func arrive() {
        layoutSubtreeIfNeeded()
        guard let layer = surface.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        fade.duration = reduceMotion ? Theme.Motion.Duration.reduced : 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.preferFullRefreshRate(on: window?.screen)
        layer.add(fade, forKey: "hud-fade")
        guard !reduceMotion else { return }
        let grow = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: centredScale(0.96, for: layer)),
                                          to: NSValue(caTransform3D: CATransform3DIdentity), response: 0.4, dampingRatio: 0.86)
        grow.preferFullRefreshRate(on: window?.screen)
        layer.add(grow, forKey: "hud-grow")
    }

    func leave(completion: @escaping @MainActor () -> Void) {
        guard let layer = surface.layer else { completion(); return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = 0
        fade.duration = reduceMotion ? Theme.Motion.Duration.reduced : 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.preferFullRefreshRate(on: window?.screen)
        layer.add(fade, forKey: "hud-fade")
        if !reduceMotion {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: centredScale(0.97, for: layer))
            shrink.duration = 0.16
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "hud-shrink")
        }
        CATransaction.commit()
    }

    /// A scale about the layer's centre, whatever its anchor point.
    private func centredScale(_ scale: CGFloat, for layer: CALayer) -> CATransform3D {
        let x = layer.bounds.width * (0.5 - layer.anchorPoint.x), y = layer.bounds.height * (0.5 - layer.anchorPoint.y)
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-x, -y, 0), CATransform3DMakeScale(scale, scale, 1)),
                                   CATransform3DMakeTranslation(x, y, 0))
    }

    // MARK: State

    func update(image: CGImage?, sections: Int) {
        guard !finishing else { return }
        // A frame that failed to compose keeps the last good one on screen.
        if let image {
            well?.setImage(image, reduceMotion: reduceMotion)
            updates += 1
        }
        // Continued manual scrolling after a (possibly premature) "reached end" clears the
        // stale end message so the live section count shows again.
        if sections > self.sections { endReached = false }
        self.sections = sections
        refreshStatus()
    }

    func setAuto(running: Bool, reachedEnd: Bool) {
        autoRunning = running
        endReached = reachedEnd
        if reachedEnd { autoEnded = true }
        hint = nil   // a real state change clears any stale hint
        autoButton.setRunning(running, reduceMotion: reduceMotion)
        refreshAuto()
        refreshStatus()
    }

    func setClimbing(_ climbing: Bool) {
        self.climbing = climbing
        refreshStatus()
    }

    func setFinishing() {
        guard !finishing else { return }
        finishing = true
        hint = nil
        autoButton.setRunning(false, reduceMotion: reduceMotion)
        autoButton.isEnabled = false
        doneButton.setBusy(true, reduceMotion: reduceMotion)
        refreshStatus()
    }

    func flashHint(_ message: String, warning: Bool) {
        guard !finishing else { return }
        hint = (message, warning)
        hintGeneration &+= 1
        let generation = hintGeneration
        refreshStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
            guard let self, self.hintGeneration == generation else { return }
            self.hint = nil
            self.refreshStatus()
        }
    }

    /// Auto is offered only while it can run: never again after the page end, never without
    /// the permission synthesized scrolling needs. Disabled, it still says why on hover.
    private func refreshAuto() {
        let title: String
        if autoRunning {
            title = String(localized: "Stop auto scroll")
        } else if autoEnded {
            title = String(localized: "End of page")
        } else if !trusted {
            title = String(localized: "Needs Accessibility permission")
        } else {
            title = String(localized: "Scroll for me")
        }
        autoButton.title = title
        autoButton.isEnabled = !finishing && (autoRunning || (!autoEnded && trusted))
    }

    private func refreshStatus() {
        refreshAuto()
        // Until the page first moves, the well says what to do.
        let prompting = !finishing && !autoRunning && !endReached && updates <= 1 && sections <= 1
        var text: String?
        var warning = false
        if finishing {
            text = String(localized: "Finishing…")
        } else if let hint {
            text = hint.text
            warning = hint.warning
        } else if let hoverControl {
            text = hoverControl.title
        } else if autoRunning {
            text = climbing ? String(localized: "Scrolling to the top…") : String(localized: "Scrolling automatically…")
        } else if endReached {
            text = String(localized: "End of page · Press Done")
        } else if prompting {
            // The full tray shows it on a card in the well; the capsule has only the chip.
            text = well == nil ? String(localized: "Scroll down or choose Scroll for me") : nil
        } else if sections == 1 {
            text = String(localized: "1 section · Scroll down")
        } else {
            // Esc only reaches us with the Accessibility permission; without it, no promise.
            text = trusted ? String(localized: "\(sections) sections · Esc to cancel")
                           : String(localized: "\(sections) sections")
        }
        well?.setPrompt(prompting, reduceMotion: reduceMotion)
        status.show(text, warning: warning, reduceMotion: reduceMotion)
        doneButton.setInviting(endReached && !autoRunning && !finishing, reduceMotion: reduceMotion)
    }
}

/// One card of Liquid Glass on the tray: plain glass, as the Dock wears it.
private final class ScrollHUDCard: NSGlassEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        style = .regular
    }
    required init?(coder: NSCoder) { nil }
}

/// The tray and its cards, a ring in from its edge and a ring apart. In the full tray the
/// capture card takes the height the controls card leaves; corners nest: tray, card, well.
private final class ScrollHUDTray: NSView {
    static let ring: CGFloat = 8
    static let radius: CGFloat = 24
    static let controlsHeight: CGFloat = 52
    private let cards: [NSGlassEffectView]
    private let capsule: Bool
    init(cards: [NSGlassEffectView], capsule: Bool) {
        self.cards = cards
        self.capsule = capsule
        super.init(frame: .zero)
        for card in cards { addSubview(card) }
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let ring = capsule ? 5 : Self.ring
        let inner = bounds.insetBy(dx: ring, dy: ring)
        if capsule, let body = cards.first {
            body.frame = inner
            body.cornerRadius = inner.height / 2
            return
        }
        guard cards.count == 2 else { return }
        cards[1].frame = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: Self.controlsHeight)
        cards[0].frame = CGRect(x: inner.minX, y: inner.minY + Self.controlsHeight + ring,
                                width: inner.width, height: inner.height - Self.controlsHeight - ring)
        for card in cards { card.cornerRadius = Self.radius - ring }
    }
}

/// The capture card's content: the well a ring in from the glass.
private final class ScrollHUDWellHolder: NSView {
    static let inset: CGFloat = 6
    private let well: NSView
    init(well: NSView) {
        self.well = well
        super.init(frame: .zero)
        addSubview(well)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        well.frame = bounds.insetBy(dx: Self.inset, dy: Self.inset)
    }
}

/// The controls cell's row: bare controls from the leading edge, the call to action trailing.
private final class ScrollHUDControls: NSView {
    private var leading: [NSView] = []
    private var trailing: NSView?
    func place(leading: [NSView], trailing: NSView) {
        self.leading = leading
        self.trailing = trailing
        for view in leading + [trailing] { addSubview(view) }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let side: CGFloat = 36
        for (index, view) in leading.enumerated() {
            view.frame = CGRect(x: 8 + CGFloat(index) * (side + 2), y: (bounds.height - side) / 2, width: side, height: side)
        }
        let pill = CGSize(width: 96, height: 34)
        trailing?.frame = CGRect(x: bounds.width - 9 - pill.width, y: (bounds.height - pill.height) / 2,
                                 width: pill.width, height: pill.height)
    }
}

/// The capsule: bare controls on its glass body like the recording hub's, the state on a
/// chip between them and Done.
private final class ScrollHUDCompactLayout: NSView {
    private let leading: [NSView]
    private let status: ScrollHUDStatusChip
    private let trailing: NSView
    init(leading: [NSView], status: ScrollHUDStatusChip, trailing: NSView) {
        self.leading = leading
        self.status = status
        self.trailing = trailing
        super.init(frame: .zero)
        for view in leading { addSubview(view) }
        addSubview(status)
        addSubview(trailing)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let side: CGFloat = 36
        for (index, view) in leading.enumerated() {
            view.frame = CGRect(x: 8 + CGFloat(index) * (side + 2), y: (bounds.height - side) / 2, width: side, height: side)
        }
        let pill = CGSize(width: 96, height: 34)
        trailing.frame = CGRect(x: bounds.width - 6 - pill.width, y: (bounds.height - pill.height) / 2,
                                width: pill.width, height: pill.height)
        let start = 8 + CGFloat(leading.count) * (side + 2) + 6
        status.maxWidth = trailing.frame.minX - 10 - start
        status.anchor = CGPoint(x: start, y: bounds.midY + ScrollHUDStatusChip.height / 2)
    }
}

// MARK: - The capture

/// The stitched capture, scaled to the width and pinned to the BOTTOM so the newest rows are
/// always in view. New rows slide in from below as the page did; older rows blur away toward
/// the top, and a thin rail on the edge tells how long the capture has grown. While it is
/// still shorter than the well, a blur of itself fills the rest, as the screenshot card
/// fills its letterbox.
private final class ScrollHUDWell: NSView {
    private let fill = CALayer()
    private let scrim = CALayer()
    private let image = CALayer()
    private let veil = ProgressiveBlurView()
    private let rail = CALayer()
    private let thumb = CALayer()
    private let status: ScrollHUDStatusChip
    private let prompt = ScrollHUDPrompt()
    /// The tail on screen, and the whole capture it was cut from, in pixels.
    private var tailSize: CGSize?
    private var fullSize: CGSize?
    private var fillGeneration = 0

    init(status: ScrollHUDStatusChip) {
        self.status = status
        super.init(frame: .zero)
        wantsLayer = true
        // Empty, the well is a darker pane of the tray, its frost still showing through.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        layer?.cornerRadius = Theme.Radius.well
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        fill.contentsGravity = .resizeAspectFill
        fill.opacity = 0
        scrim.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        image.contentsGravity = .resize
        image.minificationFilter = .trilinear
        for part in [fill, scrim, image] { layer?.addSublayer(part) }
        rail.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        rail.opacity = 0
        thumb.backgroundColor = NSColor.white.withAlphaComponent(0.75).cgColor
        thumb.shadowColor = NSColor.black.cgColor
        thumb.shadowOpacity = 0.35
        thumb.shadowRadius = 2
        thumb.shadowOffset = .zero
        rail.addSublayer(thumb)
        addSubview(veil)
        addSubview(prompt)
        addSubview(status)
        layer?.addSublayer(rail)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds
        scrim.frame = bounds
        placeImage()
        placeRail()
        CATransaction.commit()
        let band = (bounds.height * 0.34).rounded()
        veil.frame = CGRect(x: 0, y: bounds.height - band, width: bounds.width, height: band)
        veil.edge = .top
        let path = CGPath(roundedRect: bounds, cornerWidth: Theme.Radius.well, cornerHeight: Theme.Radius.well, transform: nil)
        var shift = CGAffineTransform(translationX: 0, y: -(bounds.height - band))
        veil.outline = path.copy(using: &shift)
        let card = CGSize(width: bounds.width - 32, height: 112)
        prompt.frame = CGRect(x: (bounds.width - card.width) / 2, y: (bounds.height - card.height) / 2,
                              width: card.width, height: card.height)
        status.maxWidth = bounds.width - 16
        status.anchor = CGPoint(x: 8, y: bounds.height - 8)
    }

    /// The newest rows only: the visible tail is cut from the stitched image before it becomes
    /// a layer's contents, so a long page never asks for a texture past the GPU's limit.
    func setImage(_ cgImage: CGImage, reduceMotion: Bool) {
        guard cgImage.width > 0, cgImage.height > 0, bounds.width > 0 else { return }
        let visibleRows = min(cgImage.height, Int(ceil(bounds.height * CGFloat(cgImage.width) / bounds.width)))
        let tail = cgImage.cropping(to: CGRect(x: 0, y: cgImage.height - visibleRows,
                                               width: cgImage.width, height: visibleRows)) ?? cgImage
        // How far the page moved since the last image, in the well's points.
        let previous = fullSize
        let full = CGSize(width: cgImage.width, height: cgImage.height)
        let grown = previous.map { old -> CGFloat in
            guard old.width == full.width else { return 0 }
            return (full.height - old.height) * bounds.width / full.width
        } ?? 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        image.contents = tail
        tailSize = CGSize(width: tail.width, height: tail.height)
        fullSize = full
        placeImage()
        CATransaction.commit()
        // The new rows come up from below, the way the page itself just scrolled.
        if grown > 0.5, !reduceMotion {
            let rise = CASpringAnimation.card(keyPath: "transform.translation.y", from: -min(grown, bounds.height), to: 0,
                                              response: 0.42, dampingRatio: 0.92)
            rise.preferFullRefreshRate(on: window?.screen)
            image.add(rise, forKey: "rows-rise")
        }
        let overflows = cgImage.height > visibleRows
        veil.setShown(overflows, reduceMotion: reduceMotion)
        setRail(shown: overflows, reduceMotion: reduceMotion)
        refreshFill(from: tail, needed: !overflows)
    }

    private func placeImage() {
        guard let tailSize else { image.frame = .zero; return }
        let height = (bounds.width * tailSize.height / tailSize.width).rounded()
        image.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
    }

    /// The rail's thumb is the share of the capture the well shows, at the bottom: it thins as
    /// the page grows.
    private func placeRail() {
        let track = CGRect(x: bounds.width - 7, y: 10, width: 3, height: max(0, bounds.height - 20))
        rail.frame = track
        rail.cornerRadius = 1.5
        guard let tailSize, let fullSize, fullSize.height > 0 else { thumb.frame = .zero; return }
        let share = min(1, tailSize.height / fullSize.height)
        let height = max(14, track.height * share)
        thumb.frame = CGRect(x: 0, y: 0, width: track.width, height: height)
        thumb.cornerRadius = 1.5
    }

    private func setRail(shown: Bool, reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduceMotion ? 0 : 0.3)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
        placeRail()
        rail.opacity = shown ? 1 : 0
        CATransaction.commit()
    }

    /// A small, soft copy of the newest rows behind the image, only while it does not fill
    /// the well. Made off the main actor; a newer image supersedes an older one.
    private func refreshFill(from tail: CGImage, needed: Bool) {
        fillGeneration &+= 1
        guard needed else {
            CATransaction.begin(); CATransaction.setDisableActions(true); fill.opacity = 0; CATransaction.commit()
            return
        }
        let generation = fillGeneration
        Task { @MainActor [weak self] in
            let soft = await Task.detached(priority: .userInitiated) { ScrollHUDFill.softened(tail) }.value
            guard let self, self.fillGeneration == generation, let soft else { return }
            let first = self.fill.opacity == 0
            CATransaction.begin(); CATransaction.setDisableActions(!first)
            self.fill.contents = soft
            self.fill.opacity = 1
            CATransaction.commit()
        }
    }

    func setPrompt(_ shown: Bool, reduceMotion: Bool) { prompt.setShown(shown, reduceMotion: reduceMotion) }
}

/// The well's soft fill, made off the main actor from a small copy of the newest rows.
private enum ScrollHUDFill {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func softened(_ image: CGImage) -> CGImage? {
        let width = 64, height = max(1, Int((CGFloat(image.height) * 64 / CGFloat(image.width)).rounded()))
        guard let small = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        small.interpolationQuality = .medium
        small.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let reduced = small.makeImage() else { return nil }
        let source = CIImage(cgImage: reduced)
        let blurred = source.clampedToExtent().applyingGaussianBlur(sigma: 5)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.8])
            .cropped(to: source.extent)
        return context.createCGImage(blurred, from: source.extent)
    }
}

/// What the capture is doing, on glass, like the card's "Copied": over the capture's top-left
/// corner on the tray, between the controls in the capsule. A warning carries its mark.
private final class ScrollHUDStatusChip: ScreenshotCardChip {
    static let height: CGFloat = 24
    var maxWidth: CGFloat = 200 { didSet { if text != nil { frame = targetFrame } } }
    var anchor: CGPoint = .zero { didSet { if text != nil { frame = targetFrame } } }
    private let label = CATextLayer()
    private let mark = CALayer()
    private(set) var text: String?
    private var warning = false
    private static let font = Theme.Font.ns.text(11.5, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.opacity = 0
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        label.font = Self.font
        label.fontSize = Self.font.pointSize
        label.foregroundColor = NSColor.white.cgColor
        label.contentsScale = scale
        label.truncationMode = .end
        label.alignmentMode = .left
        mark.contents = InkCenteredSymbol.render("exclamationmark.triangle.fill", pointSize: 10, weight: .bold, canvas: 14,
                                                 scale: scale, color: Theme.Palette.warn.dark.nsColor)
        mark.contentsScale = scale
        mark.opacity = 0
        clip.addSublayer(mark)
        clip.addSublayer(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var lead: CGFloat { warning ? 27 : 11 }
    private var targetFrame: CGRect {
        let words = ceil(NSAttributedString(string: text ?? "", attributes: [.font: Self.font]).size().width)
        let width = min(maxWidth, words + lead + 11)
        return CGRect(x: anchor.x, y: anchor.y - Self.height, width: width, height: Self.height)
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mark.frame = CGRect(x: 9, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = CGRect(x: lead, y: (bounds.height - 15) / 2 - 0.5, width: max(0, bounds.width - lead - 11), height: 15)
        CATransaction.commit()
    }

    /// New words roll in from below; the chip's width follows them.
    func show(_ text: String?, warning: Bool, reduceMotion: Bool) {
        guard text != self.text || warning != self.warning else { return }
        let was = self.text
        self.text = text
        self.warning = warning
        setAccessibilityValue(text)
        guard let text else { setShown(false, reduceMotion: reduceMotion); return }
        if was != nil, !reduceMotion {
            let roll = CATransition()
            roll.type = .push
            roll.subtype = .fromBottom
            roll.duration = 0.22
            roll.timingFunction = CAMediaTimingFunction(name: .easeOut)
            label.add(roll, forKey: "status-roll")
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        label.string = text
        mark.opacity = warning ? 1 : 0
        CATransaction.commit()
        if was == nil || reduceMotion {
            frame = targetFrame
            needsLayout = true
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                context.allowsImplicitAnimation = true
                animator().frame = targetFrame
            }
        }
        if !isShown { setShown(true, reduceMotion: reduceMotion) }
    }
}

/// Until the page first moves: what to do, on glass in the middle of the well, over the page
/// as it stands, with an arrow that keeps pointing the way.
private final class ScrollHUDPrompt: NSView {
    private let glass = NSGlassEffectView()
    private let face = NSView()
    private let arrow = CALayer()
    private let label = NSTextField(wrappingLabelWithString: String(localized: "Scroll down or choose Scroll for me"))
    private(set) var shown = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glass.style = .clear
        glass.tintColor = NSColor.black.withAlphaComponent(0.22)
        glass.cornerRadius = 14
        face.wantsLayer = true
        glass.contentView = face
        addSubview(glass)
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        arrow.contents = InkCenteredSymbol.render("arrow.down", pointSize: 20, weight: .semibold, canvas: 28, scale: scale, color: .white)
        arrow.contentsScale = scale
        arrow.shadowColor = NSColor.white.cgColor
        arrow.shadowOpacity = 0.55
        arrow.shadowRadius = 6
        arrow.shadowOffset = .zero
        face.layer?.addSublayer(arrow)
        label.font = Theme.Font.ns.text(12, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.alignment = .center
        label.isSelectable = false
        face.addSubview(label)
        bob()
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        glass.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arrow.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        arrow.position = CGPoint(x: bounds.midX, y: bounds.height - 34)
        CATransaction.commit()
        label.frame = CGRect(x: 14, y: 14, width: bounds.width - 28, height: 40)
    }

    /// A slow nod downward, the direction to scroll.
    private func bob() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let nod = CABasicAnimation(keyPath: "transform.translation.y")
        nod.fromValue = 2; nod.toValue = -4
        nod.duration = 0.9
        nod.autoreverses = true
        nod.repeatCount = .infinity
        nod.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        arrow.add(nod, forKey: "prompt-nod")
    }

    func setShown(_ shown: Bool, reduceMotion: Bool) {
        guard shown != self.shown, let layer else { return }
        self.shown = shown
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = shown ? 1 : 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = layer.opacity
        fade.duration = reduceMotion ? Theme.Motion.Duration.reduced : (shown ? 0.22 : 0.18)
        fade.preferFullRefreshRate(on: window?.screen)
        layer.add(fade, forKey: "prompt-fade")
        if !shown, !reduceMotion {
            // It steps back into the page as the page starts to move.
            let sink = CABasicAnimation(keyPath: "transform.scale")
            sink.fromValue = 1; sink.toValue = 0.94; sink.duration = 0.18
            sink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.add(sink, forKey: "prompt-sink")
        }
        CATransaction.commit()
    }
}

// MARK: - The controls

/// A control that takes part in the cell's one-in-focus hover.
@MainActor private protocol ScrollHUDFocusable: AnyObject {
    var title: String { get }
    var onHover: ((Bool) -> Void)? { get set }
    func setFocus(_ focus: Bool?, reduceMotion: Bool)
}

/// A bare control, like the recording hub's: hovered, its symbol rises and glows in its own
/// shape and its siblings step back. A small green light says it is running. Unavailable, it
/// stays quiet but still answers the hover with why.
private final class ScrollHUDIconButton: NSView, ScrollHUDFocusable {
    var action: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var title: String { didSet { if title != oldValue { toolTip = title; setAccessibilityLabel(title) } } }
    var isEnabled = true { didSet { if isEnabled != oldValue { settle() } } }
    private let symbol: String
    private let press = CALayer()
    private let lift = CALayer()
    private let icon = CALayer()
    private let light = CALayer()
    private var running = false
    private var pressed = false
    private var focus: Bool?
    private var tracking: NSTrackingArea?
    private let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
    private static let raised = CATransform3DConcat(CATransform3DMakeScale(1.16, 1.16, 1), CATransform3DMakeTranslation(0, 1.5, 0))

    init(symbol: String, title: String) {
        self.symbol = symbol
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        icon.contents = Self.render(symbol, scale: scale)
        icon.contentsScale = scale
        icon.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        icon.shadowColor = NSColor.white.cgColor
        icon.shadowOpacity = 0
        icon.shadowRadius = 6
        icon.shadowOffset = .zero
        light.backgroundColor = Theme.Palette.ok.dark.nsColor.cgColor
        light.shadowColor = Theme.Palette.ok.dark.nsColor.cgColor
        light.shadowOpacity = 0.85
        light.shadowRadius = 3
        light.shadowOffset = .zero
        light.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
        light.cornerRadius = 2.5
        light.opacity = 0
        lift.addSublayer(icon)
        lift.addSublayer(light)
        press.addSublayer(lift)
        layer?.addSublayer(press)
        toolTip = title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }

    private static func render(_ name: String, scale: CGFloat) -> CGImage? {
        InkCenteredSymbol.render(name, pointSize: 15, weight: .semibold, canvas: 24, scale: scale, color: .white)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func isAccessibilityEnabled() -> Bool { isEnabled }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for part in [press, lift] { part.bounds = bounds; part.position = center }
        icon.position = center
        light.position = CGPoint(x: center.x + 10, y: center.y + 10)
        CATransaction.commit()
    }

    /// Running, the symbol turns to pause and the green light comes on, breathing.
    func setRunning(_ running: Bool, reduceMotion: Bool) {
        guard running != self.running else { return }
        self.running = running
        if !reduceMotion {
            let turn = CATransition()
            turn.type = .fade
            turn.duration = 0.18
            icon.add(turn, forKey: "symbol-turn")
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        icon.contents = Self.render(running ? "pause.circle" : symbol, scale: scale)
        light.opacity = running ? 1 : 0
        light.removeAnimation(forKey: "light-breathe")
        if running && !reduceMotion {
            let breathe = CABasicAnimation(keyPath: "shadowRadius")
            breathe.fromValue = 2; breathe.toValue = 5
            breathe.duration = 0.8; breathe.autoreverses = true; breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            light.add(breathe, forKey: "light-breathe")
        }
        CATransaction.commit()
        setAccessibilityValue(running ? String(localized: "On") : String(localized: "Off"))
    }

    func setFocus(_ focus: Bool?, reduceMotion: Bool) {
        self.focus = focus
        let lifted = focus == true && isEnabled
        let screen = window?.screen
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let fromLift = lift.presentation()?.transform ?? lift.transform
        lift.transform = lifted && !reduceMotion ? Self.raised : CATransform3DIdentity
        if !reduceMotion {
            let rise = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: fromLift),
                                              to: NSValue(caTransform3D: lift.transform), response: 0.32, dampingRatio: lifted ? 0.62 : 0.85)
            rise.preferFullRefreshRate(on: screen)
            lift.add(rise, forKey: "icon-rise")
        }
        let fromGlow = icon.presentation()?.shadowOpacity ?? icon.shadowOpacity
        icon.shadowOpacity = lifted ? 0.85 : 0
        let glow = CABasicAnimation(keyPath: "shadowOpacity")
        glow.fromValue = fromGlow; glow.toValue = icon.shadowOpacity; glow.duration = lifted ? 0.16 : 0.22
        glow.preferFullRefreshRate(on: screen)
        icon.add(glow, forKey: "icon-glow")
        CATransaction.commit()
        settle()
    }

    /// Quiet when unavailable, stepped back when a sibling is in focus, full otherwise.
    private func settle() {
        let target: Float = !isEnabled ? 0.32 : (focus == false ? 0.5 : 1)
        let from = lift.presentation()?.opacity ?? lift.opacity
        guard from != target else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        lift.opacity = target
        let dim = CABasicAnimation(keyPath: "opacity")
        dim.fromValue = from; dim.toValue = target; dim.duration = 0.18
        dim.preferFullRefreshRate(on: window?.screen)
        lift.add(dim, forKey: "icon-dim")
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) {
        onHover?(false)
        if pressed { pressed = false; setPressed(false) }
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true; setPressed(true)
    }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false; setPressed(false)
        if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action?(); return true
    }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }

    private func setPressed(_ down: Bool) {
        let from = press.presentation()?.transform ?? press.transform
        let to = down ? CATransform3DMakeScale(0.86, 0.86, 1) : CATransform3DIdentity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        press.transform = to
        let motion = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: to),
                                            response: down ? 0.16 : 0.32, dampingRatio: down ? 1 : 0.6)
        motion.preferFullRefreshRate(on: window?.screen)
        press.add(motion, forKey: "icon-press")
        CATransaction.commit()
    }
}

/// Done: the HUD's call to action, a light capsule that blooms under the pointer, like the
/// panel's Record. At the end of the page it breathes, inviting the press; pressed, its mark
/// turns into a spinner until the capture is ready.
private final class ScrollHUDPill: NSView, ScrollHUDFocusable {
    var action: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    let title: String
    private let press = CALayer()
    private let body = CALayer()
    private let icon = CALayer()
    private let spinner = CAShapeLayer()
    private let label = CATextLayer()
    private var pressed = false
    private var inviting = false
    private var busy = false
    private var tracking: NSTrackingArea?
    private static let font = Theme.Font.ns.text(13, weight: .semibold)
    private static let ink = NSColor(white: 0.08, alpha: 1)

    init(title: String, symbol: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        body.backgroundColor = NSColor.white.withAlphaComponent(0.94).cgColor
        body.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        body.borderWidth = 1
        body.shadowColor = NSColor.white.cgColor
        body.shadowOpacity = 0
        body.shadowRadius = 10
        body.shadowOffset = .zero
        icon.contents = InkCenteredSymbol.render(symbol, pointSize: 12, weight: .bold, canvas: 16, scale: scale, color: Self.ink)
        icon.contentsScale = scale
        icon.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        spinner.fillColor = nil
        spinner.strokeColor = Self.ink.cgColor
        spinner.lineWidth = 1.8
        spinner.lineCap = .round
        spinner.strokeEnd = 0.72
        spinner.bounds = CGRect(x: 0, y: 0, width: 13, height: 13)
        spinner.path = CGPath(ellipseIn: spinner.bounds.insetBy(dx: 0.9, dy: 0.9), transform: nil)
        spinner.opacity = 0
        label.string = title
        label.font = Self.font
        label.fontSize = Self.font.pointSize
        label.foregroundColor = Self.ink.cgColor
        label.contentsScale = scale
        label.alignmentMode = .left
        body.addSublayer(icon)
        body.addSublayer(spinner)
        body.addSublayer(label)
        press.addSublayer(body)
        layer?.addSublayer(press)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func isAccessibilityEnabled() -> Bool { !busy }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        press.bounds = bounds; press.position = center
        body.bounds = bounds; body.position = center
        body.cornerRadius = bounds.height / 2
        let text = ceil(NSAttributedString(string: title, attributes: [.font: Self.font]).size().width)
        let start = (bounds.width - (16 + 5 + text)) / 2
        icon.position = CGPoint(x: start + 8, y: bounds.midY)
        spinner.position = icon.position
        label.frame = CGRect(x: start + 21, y: (bounds.height - 17) / 2 - 0.5, width: text + 2, height: 17)
        CATransaction.commit()
    }

    /// The bloom: a little larger, and a soft light around it.
    func setFocus(_ focus: Bool?, reduceMotion: Bool) {
        let bloom = focus == true && !busy
        let screen = window?.screen
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let from = body.presentation()?.transform ?? body.transform
        body.transform = bloom && !reduceMotion ? CATransform3DMakeScale(1.05, 1.05, 1) : CATransform3DIdentity
        if !reduceMotion {
            let swell = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: from),
                                               to: NSValue(caTransform3D: body.transform), response: 0.32, dampingRatio: bloom ? 0.62 : 0.85)
            swell.preferFullRefreshRate(on: screen)
            body.add(swell, forKey: "pill-swell")
        }
        if !inviting {
            let fromGlow = body.presentation()?.shadowOpacity ?? body.shadowOpacity
            body.shadowOpacity = bloom ? 0.55 : 0
            let glow = CABasicAnimation(keyPath: "shadowOpacity")
            glow.fromValue = fromGlow; glow.toValue = body.shadowOpacity; glow.duration = bloom ? 0.16 : 0.24
            glow.preferFullRefreshRate(on: screen)
            body.add(glow, forKey: "pill-glow")
        }
        let fromOpacity = press.presentation()?.opacity ?? press.opacity
        press.opacity = focus == false ? 0.6 : 1
        let dim = CABasicAnimation(keyPath: "opacity")
        dim.fromValue = fromOpacity; dim.toValue = press.opacity; dim.duration = 0.18
        press.add(dim, forKey: "pill-dim")
        CATransaction.commit()
    }

    /// The page has ended: the light around Done breathes until something else happens.
    func setInviting(_ inviting: Bool, reduceMotion: Bool) {
        guard inviting != self.inviting else { return }
        self.inviting = inviting
        CATransaction.begin(); CATransaction.setDisableActions(true)
        body.removeAnimation(forKey: "pill-invite")
        body.shadowOpacity = inviting ? 0.45 : 0
        if inviting && !reduceMotion {
            let breathe = CABasicAnimation(keyPath: "shadowOpacity")
            breathe.fromValue = 0.15; breathe.toValue = 0.7
            breathe.duration = 1.1; breathe.autoreverses = true; breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            body.add(breathe, forKey: "pill-invite")
        }
        CATransaction.commit()
    }

    /// Pressed: the check turns into a spinner and the pill takes no second press.
    func setBusy(_ busy: Bool, reduceMotion: Bool) {
        guard busy != self.busy else { return }
        self.busy = busy
        if busy { setInviting(false, reduceMotion: reduceMotion); setFocus(nil, reduceMotion: reduceMotion) }
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduceMotion ? 0 : 0.18)
        icon.opacity = busy ? 0 : 1
        spinner.opacity = busy ? 1 : 0
        CATransaction.commit()
        spinner.removeAnimation(forKey: "spin")
        if busy {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0; spin.toValue = -2 * Double.pi
            spin.duration = 0.8; spin.repeatCount = .infinity
            spinner.add(spin, forKey: "spin")
        }
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) {
        onHover?(false)
        if pressed { pressed = false; setPressed(false) }
    }
    override func mouseDown(with event: NSEvent) {
        guard !busy else { return }
        pressed = true; setPressed(true)
    }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false; setPressed(false)
        if !busy, bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func accessibilityPerformPress() -> Bool {
        guard !busy else { return false }
        action?(); return true
    }
    override func resetCursorRects() { if !busy { addCursorRect(bounds, cursor: .pointingHand) } }

    private func setPressed(_ down: Bool) {
        let from = press.presentation()?.transform ?? press.transform
        let to = down ? CATransform3DMakeScale(0.94, 0.94, 1) : CATransform3DIdentity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        press.transform = to
        let motion = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: to),
                                            response: down ? 0.16 : 0.32, dampingRatio: down ? 1 : 0.6)
        motion.preferFullRefreshRate(on: window?.screen)
        press.add(motion, forKey: "pill-press")
        CATransaction.commit()
    }
}
