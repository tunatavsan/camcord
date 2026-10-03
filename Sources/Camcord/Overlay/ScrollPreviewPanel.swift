import AppKit
import CoreGraphics
import CoreImage
import QuartzCore

/// The floating HUD beside the scroll region during a scrolling capture: the stitched image
/// growing in real time (tailing the newest rows at the bottom), its state, an auto-scroll
/// toggle and Done / Cancel. It stands on the app's tray like the recording hub. Living in
/// its own nonactivating panel OUTSIDE the captured region, it never appears in the capture
/// and never steals scroll focus from the target.
@MainActor
final class ScrollPreviewPanel {
    private var panel: NSPanel?
    private var content: ScrollPreviewView?

    /// The tray itself; the window adds room around it for its shadow.
    static let traySize = CGSize(width: 236, height: 392)
    static let margin: CGFloat = 26

    func show(
        near region: CGRect,
        onDone: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onToggleAuto: @escaping () -> Void
    ) {
        hide(animated: false)
        let frame = Self.placement(near: region).insetBy(dx: -Self.margin, dy: -Self.margin)
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
        // Like the recording hub: white controls on a tinted tray, whatever is behind it.
        panel.appearance = NSAppearance(named: .darkAqua)

        let view = ScrollPreviewView(frame: CGRect(origin: .zero, size: frame.size), margin: Self.margin)
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

    /// Shows a transient message in the status chip (e.g. a missing-permission hint).
    func flashHint(_ message: String) {
        content?.flashHint(message)
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

    /// Places the tray OUTSIDE the region — right, else left, else below, else above —
    /// choosing the first spot that fits fully on the region's screen without overlapping
    /// it. Coordinates are AppKit (bottom-left origin). For a near-full-screen region no
    /// spot is clean, so we clamp on-screen; the capture filter excludes our own windows,
    /// so even an overlap can't corrupt the shot.
    private static func placement(near region: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? region.height
        let regionAK = Geometry.cgToAppKit(region, primaryScreenHeight: primaryH)
        let bounds = (NSScreen.screens.first { $0.frame.intersects(regionAK) } ?? NSScreen.main)?.frame ?? regionAK
        let gap: CGFloat = 18
        let w = traySize.width, h = traySize.height

        let candidates: [CGRect] = [
            CGRect(x: regionAK.maxX + gap, y: regionAK.maxY - h, width: w, height: h),        // right, tops aligned
            CGRect(x: regionAK.minX - gap - w, y: regionAK.maxY - h, width: w, height: h),    // left
            CGRect(x: regionAK.midX - w / 2, y: regionAK.minY - gap - h, width: w, height: h), // below
            CGRect(x: regionAK.midX - w / 2, y: regionAK.maxY + gap, width: w, height: h),     // above
        ]
        for c in candidates where bounds.contains(c) && !c.intersects(regionAK) { return c }

        var fallback = candidates[0]
        fallback.origin.x = min(max(fallback.minX, bounds.minX + 8), bounds.maxX - w - 8)
        fallback.origin.y = min(max(fallback.minY, bounds.minY + 8), bounds.maxY - h - 8)
        return fallback
    }
}

/// The HUD: the tray, the growing capture on it, and a glass cell of controls below.
private final class ScrollPreviewView: NSView {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggleAuto: (() -> Void)?

    private let margin: CGFloat
    private let well = ScrollHUDWell()
    private let controls = NSGlassEffectView()
    private let controlsContent = ScrollHUDControls()
    private let cancelButton = ScrollHUDIconButton(symbol: "xmark", title: String(localized: "Cancel"))
    private let autoButton = ScrollHUDIconButton(symbol: "arrow.down.circle", title: String(localized: "Scroll for me"))
    private let doneButton = ScrollHUDPill(title: String(localized: "Done"), symbol: "checkmark")
    private lazy var surface = TraySurface(content: ScrollHUDLayout(well: well, controls: controls), shadowRadius: 10,
                                           cornerRadius: Theme.Radius.floating, tint: NSColor.black.withAlphaComponent(0.16))

    // Status state (precedence: transient hint > hovered control > auto-running > end-reached > sections).
    private var sections = 0
    private var autoRunning = false
    private var endReached = false
    private var hint: String?
    private var hintGeneration = 0
    private var hoverTitle: String?
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(frame frameRect: NSRect, margin: CGFloat) {
        self.margin = margin
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(surface)
        controls.style = .clear
        controls.tintColor = NSColor.black.withAlphaComponent(0.16)
        controls.cornerRadius = Theme.Radius.well
        controls.contentView = controlsContent
        controlsContent.place(leading: [cancelButton, autoButton], trailing: doneButton)
        cancelButton.action = { [weak self] in self?.onCancel?() }
        autoButton.action = { [weak self] in self?.onToggleAuto?() }
        doneButton.action = { [weak self] in self?.onDone?() }
        // One control in focus at a time: the others step back, and the chip names it.
        let all: [ScrollHUDFocusable] = [cancelButton, autoButton, doneButton]
        for control in all {
            control.onHover = { [weak self, weak control] inside in
                guard let self, let control else { return }
                for other in all { other.setFocus(inside ? other === control : nil, reduceMotion: self.reduceMotion) }
                self.hoverTitle = inside && control !== self.doneButton ? control.title : nil
                self.refreshStatus()
            }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Scroll capture"))
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
        let grow = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: centeredScale(0.96, for: layer)),
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
            shrink.toValue = NSValue(caTransform3D: centeredScale(0.97, for: layer))
            shrink.duration = 0.16
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "hud-shrink")
        }
        CATransaction.commit()
    }

    /// A scale about the layer's centre, whatever its anchor point.
    private func centeredScale(_ scale: CGFloat, for layer: CALayer) -> CATransform3D {
        let x = layer.bounds.width * (0.5 - layer.anchorPoint.x), y = layer.bounds.height * (0.5 - layer.anchorPoint.y)
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-x, -y, 0), CATransform3DMakeScale(scale, scale, 1)),
                                   CATransform3DMakeTranslation(x, y, 0))
    }

    // MARK: State

    func update(image: CGImage?, sections: Int) {
        well.setImage(image)
        // Continued manual scrolling after a (possibly premature) "reached end" clears the
        // stale end message so the live section count shows again.
        if sections > self.sections { endReached = false }
        self.sections = sections
        refreshStatus()
    }

    func setAuto(running: Bool, reachedEnd: Bool) {
        autoRunning = running
        endReached = reachedEnd
        hint = nil   // a real state change clears any stale hint
        autoButton.setRunning(running, reduceMotion: reduceMotion)
        autoButton.title = running ? String(localized: "Stop auto scroll") : String(localized: "Scroll for me")
        if hoverTitle != nil, autoButton.isFocused { hoverTitle = autoButton.title }
        refreshStatus()
    }

    func flashHint(_ message: String) {
        hint = message
        hintGeneration &+= 1
        let generation = hintGeneration
        refreshStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self, self.hintGeneration == generation else { return }
            self.hint = nil
            self.refreshStatus()
        }
    }

    private func refreshStatus() {
        let status: String?
        if let hint {
            status = hint
        } else if let hoverTitle {
            status = hoverTitle
        } else if autoRunning {
            status = String(localized: "Scrolling automatically…")
        } else if endReached {
            status = String(localized: "End of page · Press Done")
        } else {
            switch sections {
            case 0: status = nil
            case 1: status = String(localized: "1 section · Scroll down")
            default: status = String(localized: "\(sections) sections · Esc to cancel")
            }
        }
        // Before the first section the well itself says what to do.
        well.setPrompt(sections == 0 && !autoRunning, reduceMotion: reduceMotion)
        well.setStatus(status, reduceMotion: reduceMotion)
        doneButton.setInviting(endReached && !autoRunning, reduceMotion: reduceMotion)
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

/// The tray's two parts, a ring in from its edge: the capture above, the controls below.
private final class ScrollHUDLayout: NSView {
    static let ring: CGFloat = 8
    static let controlsHeight: CGFloat = 52
    private let well: NSView
    private let controls: NSView
    init(well: NSView, controls: NSView) {
        self.well = well
        self.controls = controls
        super.init(frame: .zero)
        addSubview(well)
        addSubview(controls)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let inner = bounds.insetBy(dx: Self.ring, dy: Self.ring)
        controls.frame = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: Self.controlsHeight)
        well.frame = CGRect(x: inner.minX, y: inner.minY + Self.controlsHeight + Self.ring,
                            width: inner.width, height: inner.height - Self.controlsHeight - Self.ring)
    }
}

// MARK: - The capture

/// The stitched capture, scaled to the width and pinned to the BOTTOM so the newest rows are
/// always in view. Its older rows blur away toward the top; while it is still shorter than the
/// well, a blur of itself fills the rest, as the screenshot card fills its letterbox.
private final class ScrollHUDWell: NSView {
    private let fill = CALayer()
    private let scrim = CALayer()
    private let image = CALayer()
    private let veil = ProgressiveBlurView()
    private let status = ScrollHUDStatusChip()
    private let prompt = ScrollHUDPrompt()
    private var pixelSize: CGSize?
    private var fillGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        addSubview(veil)
        addSubview(prompt)
        addSubview(status)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds
        scrim.frame = bounds
        placeImage()
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
    func setImage(_ cgImage: CGImage?) {
        guard let cgImage, cgImage.width > 0, cgImage.height > 0, bounds.width > 0 else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            image.contents = nil; fill.opacity = 0
            CATransaction.commit()
            pixelSize = nil
            veil.setShown(false, reduceMotion: true)
            return
        }
        let visibleRows = min(cgImage.height, Int(ceil(bounds.height * CGFloat(cgImage.width) / bounds.width)))
        let tail = cgImage.cropping(to: CGRect(x: 0, y: cgImage.height - visibleRows,
                                               width: cgImage.width, height: visibleRows)) ?? cgImage
        CATransaction.begin(); CATransaction.setDisableActions(true)
        image.contents = tail
        pixelSize = CGSize(width: tail.width, height: tail.height)
        placeImage()
        CATransaction.commit()
        let overflows = cgImage.height > visibleRows
        veil.setShown(overflows, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        refreshFill(from: tail, needed: !overflows)
    }

    private func placeImage() {
        guard let pixelSize else { image.frame = .zero; return }
        let height = (bounds.width * pixelSize.height / pixelSize.width).rounded()
        image.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
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

    func setStatus(_ text: String?, reduceMotion: Bool) { status.show(text, reduceMotion: reduceMotion) }
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

/// What the capture is doing, on glass over its top-left corner, like the card's "Copied".
private final class ScrollHUDStatusChip: ScreenshotCardChip {
    var maxWidth: CGFloat = 200
    var anchor: CGPoint = .zero { didSet { if text != nil { frame = targetFrame } } }
    private let label = CATextLayer()
    private(set) var text: String?
    private static let font = Theme.Font.ns.text(11.5, weight: .semibold)
    private static let height: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.opacity = 0
        label.font = Self.font
        label.fontSize = Self.font.pointSize
        label.foregroundColor = NSColor.white.cgColor
        label.contentsScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        label.truncationMode = .end
        label.alignmentMode = .left
        clip.addSublayer(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var textWidth: CGFloat {
        guard let text else { return 0 }
        return ceil(NSAttributedString(string: text, attributes: [.font: Self.font]).size().width)
    }
    private var targetFrame: CGRect {
        let width = min(maxWidth, textWidth + 22)
        return CGRect(x: anchor.x, y: anchor.y - Self.height, width: width, height: Self.height)
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        label.frame = CGRect(x: 11, y: (bounds.height - 15) / 2 - 0.5, width: bounds.width - 22, height: 15)
        CATransaction.commit()
    }

    /// New words roll in from below; the chip's width follows them.
    func show(_ text: String?, reduceMotion: Bool) {
        guard text != self.text else { return }
        let was = self.text
        self.text = text
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
        CATransaction.commit()
        if was == nil || reduceMotion {
            frame = targetFrame
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

/// Before the first section: what to do, on glass in the middle of the empty well, with an
/// arrow that keeps pointing the way.
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
        glass.tintColor = NSColor.black.withAlphaComponent(0.16)
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
        label.textColor = NSColor.white.withAlphaComponent(0.88)
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
        fade.duration = reduceMotion ? Theme.Motion.Duration.reduced : (shown ? 0.22 : 0.16)
        fade.preferFullRefreshRate(on: window?.screen)
        layer.add(fade, forKey: "prompt-fade")
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

/// A bare control on the glass, like the recording hub's: hovered, its symbol rises and glows
/// in its own shape and its siblings step back. A small green light says it is running.
private final class ScrollHUDIconButton: NSView, ScrollHUDFocusable {
    var action: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var title: String { didSet { toolTip = title; setAccessibilityLabel(title) } }
    private(set) var isFocused = false
    private let symbol: String
    private let press = CALayer()
    private let lift = CALayer()
    private let icon = CALayer()
    private let light = CALayer()
    private var running = false
    private var pressed = false
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
        light.backgroundColor = Theme.Palette.ok.ns.cgColor
        light.shadowColor = Theme.Palette.ok.ns.cgColor
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
        let lifted = focus == true
        isFocused = lifted
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
        let fromOpacity = lift.presentation()?.opacity ?? lift.opacity
        lift.opacity = focus == false ? 0.5 : 1
        let dim = CABasicAnimation(keyPath: "opacity")
        dim.fromValue = fromOpacity; dim.toValue = lift.opacity; dim.duration = 0.18
        dim.preferFullRefreshRate(on: screen)
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
    override func mouseDown(with event: NSEvent) { pressed = true; setPressed(true) }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false; setPressed(false)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func accessibilityPerformPress() -> Bool { action?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

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
/// panel's Record. At the end of the page it breathes, inviting the press.
private final class ScrollHUDPill: NSView, ScrollHUDFocusable {
    var action: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    let title: String
    private let press = CALayer()
    private let body = CALayer()
    private let icon = CALayer()
    private let label = CATextLayer()
    private var pressed = false
    private var inviting = false
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
        label.string = title
        label.font = Self.font
        label.fontSize = Self.font.pointSize
        label.foregroundColor = Self.ink.cgColor
        label.contentsScale = scale
        label.alignmentMode = .left
        body.addSublayer(icon)
        body.addSublayer(label)
        press.addSublayer(body)
        layer?.addSublayer(press)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }

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
        label.frame = CGRect(x: start + 21, y: (bounds.height - 17) / 2 - 0.5, width: text + 2, height: 17)
        CATransaction.commit()
    }

    /// The bloom: a little larger, and a soft light around it.
    func setFocus(_ focus: Bool?, reduceMotion: Bool) {
        let bloom = focus == true
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
    override func mouseDown(with event: NSEvent) { pressed = true; setPressed(true) }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false; setPressed(false)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func accessibilityPerformPress() -> Bool { action?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

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
