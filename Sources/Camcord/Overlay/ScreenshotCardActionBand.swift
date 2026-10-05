import AppKit
import CoreImage
import QuartzCore

/// The well's backdrop and the action band's blur levels, rendered once per capture off the main actor.
enum ScreenshotCardBlur {
    struct Rendered: Sendable {
        let fill: CGImage?
        let levels: [CGImage]
    }
    /// Gaussian sigmas, in points, of the band's stacked levels, lightest first: six small
    /// steps read as one continuous, progressive blur.
    static let levelSigmas: [CGFloat] = [1.5, 3, 5, 8, 12, 18]
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func render(_ image: CGImage, imageRect: CGRect, wellSize: CGSize, scale: CGFloat) async -> Rendered {
        await Task.detached(priority: .userInitiated) {
            renderNow(image, imageRect: imageRect, wellSize: wellSize, scale: scale)
        }.value
    }

    static func renderNow(_ image: CGImage, imageRect: CGRect, wellSize: CGSize, scale: CGFloat) -> Rendered {
        let source = CIImage(cgImage: image)
        let well = CGRect(x: 0, y: 0, width: (wellSize.width * scale).rounded(), height: (wellSize.height * scale).rounded())
        guard source.extent.width > 0, source.extent.height > 0, imageRect.width > 0, imageRect.height > 0,
              well.width > 0, well.height > 0 else {
            return Rendered(fill: nil, levels: [])
        }
        // Aspect-fill the well and blur it heavily: the letterbox reads as the capture's own colour.
        let fillScale = max(well.width / source.extent.width, well.height / source.extent.height)
        let fill = source
            .transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
            .transformed(by: CGAffineTransform(translationX: (well.width - source.extent.width * fillScale) / 2,
                                               y: (well.height - source.extent.height * fillScale) / 2))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 14 * scale)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.75])
            .cropped(to: well)
        // What the well shows: the sharp capture over its fill.
        let sharp = source
            .transformed(by: CGAffineTransform(scaleX: imageRect.width * scale / source.extent.width,
                                               y: imageRect.height * scale / source.extent.height))
            .transformed(by: CGAffineTransform(translationX: imageRect.minX * scale, y: imageRect.minY * scale))
        let composite = sharp.composited(over: fill).clampedToExtent()
        let band = CGRect(x: 0, y: 0, width: well.width, height: ScreenshotCardGeometry.band * scale)
        // Like the system's materials, the blur lifts the colour a little instead of greying it.
        let levels = levelSigmas.compactMap { sigma in
            context.createCGImage(composite.applyingGaussianBlur(sigma: sigma * scale)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + 0.02 * sigma])
                .cropped(to: band), from: band)
        }
        return Rendered(fill: context.createCGImage(fill, from: well), levels: levels)
    }
}

/// Hover actions over the capture's lower edge. A progressive blur rises from the bottom,
/// then the buttons follow one after another.
@MainActor final class ScreenshotCardActionBand: NSView {
    struct Action {
        let title: String
        let symbol: String
        var enabled = true
        let perform: @MainActor (NSView) -> Void
    }
    var actions: [Action] = [] { didSet { rebuild() } }
    var isEnabled = true { didSet { for button in buttons { button.isEnabled = isEnabled && button.action.enabled } } }
    /// The buttons gather in the middle instead of starting from the left: a pin keeps its
    /// corners free to resize.
    var centersButtons = false { didSet { needsLayout = true } }
    private(set) var revealed = false
    private var reduceMotion = false
    private let veil = ScreenshotCardVeil()
    private(set) var buttons: [ScreenshotCardActionButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(veil)
    }
    required init?(coder: NSCoder) { nil }

    func setBlurLevels(_ images: [CGImage]) { veil.setLevels(images) }

    func setRevealed(_ revealed: Bool, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        guard revealed != self.revealed else { return }
        self.revealed = revealed
        let screen = window?.screen
        veil.reveal(revealed, reduceMotion: reduceMotion, screen: screen)
        if !revealed { for button in buttons { button.setHovered(false) } }
        for (index, button) in buttons.enumerated() {
            let delay = revealed && !reduceMotion ? 0.05 + Double(index) * 0.028 : 0
            button.reveal(revealed, delay: delay, reduceMotion: reduceMotion, screen: screen)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard revealed else { return nil }
        // The band swallows clicks between its buttons: they never open the preview by accident.
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        veil.frame = bounds
        // From the left, one even step apart, however many buttons there are.
        let side: CGFloat = 38, step: CGFloat = 46
        let span = CGFloat(max(0, buttons.count - 1)) * step + side
        let first = centersButtons ? ((bounds.width - span) / 2).rounded() : 8
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: first + CGFloat(index) * step, y: 7, width: side, height: side)
        }
    }

    private func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = actions.map { ScreenshotCardActionButton(action: $0) }
        for button in buttons {
            button.isEnabled = isEnabled && button.action.enabled
            // One button in focus: the others step back.
            button.onHover = { [weak self, weak button] hovered in
                guard let self else { return }
                for other in self.buttons { other.setDimmed(hovered && other !== button) }
            }
            addSubview(button)
            if revealed { button.reveal(true, delay: 0, reduceMotion: reduceMotion, screen: window?.screen) }
        }
        needsLayout = true
    }
}

/// The band's backdrop: stacked blur levels and a scrim, revealed by a mask that rises from the bottom.
private final class ScreenshotCardVeil: NSView {
    private let veil = CALayer()
    private let rise = CAGradientLayer()
    private let scrim = CAGradientLayer()
    private var levels: [CALayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        veil.opacity = 0
        veil.mask = rise
        // macOS layers run bottom to top: (0.5, 0) is the band's lower edge.
        rise.startPoint = CGPoint(x: 0.5, y: 0); rise.endPoint = CGPoint(x: 0.5, y: 1)
        rise.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        rise.locations = [0, 0.5, 1]
        scrim.startPoint = CGPoint(x: 0.5, y: 0); scrim.endPoint = CGPoint(x: 0.5, y: 1)
        scrim.colors = [NSColor.black.withAlphaComponent(0.3).cgColor, NSColor.black.withAlphaComponent(0.12).cgColor,
                        NSColor.clear.cgColor]
        scrim.locations = [0, 0.4, 0.9]
        veil.addSublayer(scrim)
        layer?.addSublayer(veil)
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Heavier blur toward the bottom: each level fades out higher than the one above it.
    func setLevels(_ images: [CGImage]) {
        levels.forEach { $0.removeFromSuperlayer() }
        let stops: [(solid: Double, clear: Double)] = [(0.7, 1), (0.58, 0.88), (0.46, 0.76), (0.34, 0.64), (0.22, 0.52), (0.1, 0.4)]
        levels = zip(images, stops).map { image, stop in
            let level = CALayer()
            level.contents = image
            level.contentsGravity = .resize
            let mask = CAGradientLayer()
            mask.startPoint = CGPoint(x: 0.5, y: 0); mask.endPoint = CGPoint(x: 0.5, y: 1)
            mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            mask.locations = [0, NSNumber(value: stop.solid), NSNumber(value: stop.clear)]
            level.mask = mask
            return level
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for level in levels { veil.insertSublayer(level, below: scrim) }
        CATransaction.commit()
        needsLayout = true
    }

    func reveal(_ revealed: Bool, reduceMotion: Bool, screen: NSScreen?) {
        let height = bounds.height
        let fromY = rise.presentation()?.position.y ?? rise.position.y
        let fromOpacity = veil.presentation()?.opacity ?? veil.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rise.position.y = revealed ? height : -height
        veil.opacity = revealed ? 1 : 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = veil.opacity
        fade.duration = reduceMotion ? Theme.Motion.Duration.reduced : (revealed ? 0.22 : 0.2)
        fade.timingFunction = CAMediaTimingFunction(name: revealed ? .easeOut : .easeIn)
        fade.preferFullRefreshRate(on: screen)
        veil.add(fade, forKey: "veil-fade")
        if !reduceMotion {
            let travel: CAAnimation
            if revealed {
                travel = CASpringAnimation.card(keyPath: "position.y", from: fromY, to: height, response: 0.45, dampingRatio: 0.9)
            } else {
                let fall = CABasicAnimation(keyPath: "position.y")
                fall.fromValue = fromY; fall.toValue = -height; fall.duration = 0.2
                fall.timingFunction = CAMediaTimingFunction(name: .easeIn)
                travel = fall
            }
            travel.preferFullRefreshRate(on: screen)
            rise.add(travel, forKey: "veil-rise")
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        veil.frame = bounds
        scrim.frame = bounds
        for level in levels { level.frame = bounds; level.mask?.frame = bounds }
        // Twice the band's height: solid below, fading above. Hidden, it sits wholly beneath the band.
        rise.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 2)
        rise.position = CGPoint(x: bounds.midX, y: veil.opacity > 0 ? bounds.height : -bounds.height)
        CATransaction.commit()
    }
}

/// One action: a white symbol over the blur. Hovered, the symbol rises, grows and glows and
/// its name appears above it while the others step back; pressed, it gives.
@MainActor final class ScreenshotCardActionButton: NSView {
    let action: ScreenshotCardActionBand.Action
    var isEnabled = true {
        didSet {
            if !isEnabled { setHovered(false) }
            settleOpacity(animated: false)
        }
    }
    var onHover: ((Bool) -> Void)?
    /// Reveal motion; `press` inside it owns the press and `lift` the hover, so they never fight.
    private let stage = CALayer()
    private let press = CALayer()
    private let lift = CALayer()
    private let icon = CALayer()
    private let caption = CATextLayer()
    private var tracking: NSTrackingArea?
    private var pressed = false
    private var hovered = false
    private var dimmed = false
    private static let canvas: CGFloat = 24
    private static let hidden = CATransform3DConcat(CATransform3DMakeScale(0.8, 0.8, 1), CATransform3DMakeTranslation(0, -10, 0))
    private static let leaving = CATransform3DConcat(CATransform3DMakeScale(0.92, 0.92, 1), CATransform3DMakeTranslation(0, -6, 0))
    private static let raised = CATransform3DConcat(CATransform3DMakeScale(1.16, 1.16, 1), CATransform3DMakeTranslation(0, 3, 0))

    init(action: ScreenshotCardActionBand.Action) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        stage.opacity = 0
        stage.transform = Self.hidden
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        icon.contents = Self.symbol(action.symbol, scale: scale)
        icon.contentsScale = scale
        icon.bounds = CGRect(x: 0, y: 0, width: Self.canvas, height: Self.canvas)
        icon.shadowColor = NSColor.white.cgColor
        icon.shadowOpacity = 0
        icon.shadowRadius = 7
        icon.shadowOffset = .zero
        caption.string = action.title
        caption.font = Theme.Font.ns.text(11, weight: .semibold)
        caption.fontSize = 11
        caption.foregroundColor = NSColor.white.cgColor
        caption.alignmentMode = .center
        caption.contentsScale = scale
        caption.opacity = 0
        caption.shadowColor = NSColor.black.cgColor
        caption.shadowOpacity = 0.6
        caption.shadowRadius = 2
        caption.shadowOffset = .zero
        lift.addSublayer(icon)
        press.addSublayer(lift)
        stage.addSublayer(press)
        stage.addSublayer(caption)
        layer?.addSublayer(stage)
        toolTip = action.title
    }
    required init?(coder: NSCoder) { nil }

    func reveal(_ revealed: Bool, delay: CFTimeInterval, reduceMotion: Bool, screen: NSScreen?) {
        let fromOpacity = stage.presentation()?.opacity ?? stage.opacity
        // From rest the buttons rise from further below; mid-motion they turn from where they are.
        let fromTransform = fromOpacity < 0.05 && revealed ? Self.hidden : (stage.presentation()?.transform ?? stage.transform)
        let toTransform = revealed || reduceMotion ? CATransform3DIdentity : Self.leaving
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stage.removeAllAnimations()
        stage.opacity = revealed ? 1 : 0
        stage.transform = toTransform
        let begin = CACurrentMediaTime() + delay
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = stage.opacity
        fade.duration = reduceMotion ? Theme.Motion.Duration.reduced : (revealed ? 0.18 : 0.12)
        fade.timingFunction = CAMediaTimingFunction(name: revealed ? .easeOut : .easeIn)
        fade.beginTime = begin
        fade.fillMode = .backwards
        fade.preferFullRefreshRate(on: screen)
        stage.add(fade, forKey: "button-fade")
        if !reduceMotion {
            let motion: CAAnimation
            if revealed {
                motion = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: fromTransform),
                                                to: NSValue(caTransform3D: toTransform), response: 0.42, dampingRatio: 0.66)
            } else {
                let leave = CABasicAnimation(keyPath: "transform")
                leave.fromValue = NSValue(caTransform3D: fromTransform)
                leave.toValue = NSValue(caTransform3D: toTransform)
                leave.duration = 0.14
                leave.timingFunction = CAMediaTimingFunction(name: .easeIn)
                motion = leave
            }
            motion.beginTime = begin
            motion.fillMode = .backwards
            motion.preferFullRefreshRate(on: screen)
            stage.add(motion, forKey: "button-motion")
        }
        CATransaction.commit()
    }

    /// Hover: the symbol rises, grows and glows; its name fades in above it.
    func setHovered(_ hovered: Bool) {
        guard hovered != self.hovered else { return }
        self.hovered = hovered
        let screen = window?.screen
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let fromLift = lift.presentation()?.transform ?? lift.transform
        lift.transform = hovered ? Self.raised : CATransform3DIdentity
        let rise = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: fromLift),
                                          to: NSValue(caTransform3D: lift.transform), response: 0.34, dampingRatio: hovered ? 0.6 : 0.85)
        rise.preferFullRefreshRate(on: screen)
        lift.add(rise, forKey: "button-lift")
        let fromGlow = icon.presentation()?.shadowOpacity ?? icon.shadowOpacity
        icon.shadowOpacity = hovered ? 0.8 : 0
        let glow = CABasicAnimation(keyPath: "shadowOpacity")
        glow.fromValue = fromGlow; glow.toValue = icon.shadowOpacity; glow.duration = 0.2
        glow.preferFullRefreshRate(on: screen)
        icon.add(glow, forKey: "button-glow")
        let fromCaption = caption.presentation()?.opacity ?? caption.opacity
        caption.opacity = hovered ? 1 : 0
        let label = CABasicAnimation(keyPath: "opacity")
        label.fromValue = fromCaption; label.toValue = caption.opacity; label.duration = hovered ? 0.16 : 0.1
        label.preferFullRefreshRate(on: screen)
        caption.add(label, forKey: "caption-fade")
        if hovered {
            let drift = CASpringAnimation.card(keyPath: "transform.translation.y", from: -4, to: 0, response: 0.3, dampingRatio: 0.8)
            drift.preferFullRefreshRate(on: screen)
            caption.add(drift, forKey: "caption-drift")
        }
        CATransaction.commit()
        onHover?(hovered)
    }

    /// Another button is in focus: this one steps back.
    func setDimmed(_ dimmed: Bool) {
        guard dimmed != self.dimmed else { return }
        self.dimmed = dimmed
        settleOpacity(animated: true)
    }

    private func settleOpacity(animated: Bool) {
        let target: Float = !isEnabled ? 0.35 : (dimmed ? 0.5 : 1)
        let from = lift.presentation()?.opacity ?? lift.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        lift.opacity = target
        if animated {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from; fade.toValue = target; fade.duration = 0.18
            fade.preferFullRefreshRate(on: window?.screen)
            lift.add(fade, forKey: "button-dim")
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for layer in [stage, press, lift] { layer.bounds = bounds; layer.position = center }
        icon.position = center
        caption.frame = CGRect(x: bounds.midX - 50, y: bounds.maxY + 1, width: 100, height: 15)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        tracking = area; addTrackingArea(area)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { if isEnabled { setHovered(true) } }
    override func mouseExited(with event: NSEvent) {
        setHovered(false)
        if pressed { pressed = false; setPressed(false) }
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true; setPressed(true)
    }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false; setPressed(false)
        if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { action.perform(self) }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { action.title }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action.perform(self); return true
    }

    private func setPressed(_ down: Bool) {
        let from = press.presentation()?.transform ?? press.transform
        let to = down ? CATransform3DMakeScale(0.86, 0.86, 1) : CATransform3DIdentity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        press.transform = to
        let motion = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: to),
                                            response: down ? 0.16 : 0.32, dampingRatio: down ? 1 : 0.6)
        motion.preferFullRefreshRate(on: window?.screen)
        press.add(motion, forKey: "button-press")
        CATransaction.commit()
    }

    /// The symbol drawn white on a fixed square, centred on its ink (see `InkCenteredSymbol`).
    static func symbol(_ name: String, scale: CGFloat, pointSize: CGFloat = 16, weight: NSFont.Weight = .medium) -> CGImage? {
        InkCenteredSymbol.render(name, pointSize: pointSize, weight: weight, canvas: canvas, scale: scale, color: .white)
    }
}

/// A small Liquid Glass chip over the capture: the image shows through and bends at its rim.
@MainActor class ScreenshotCardChip: NSView {
    private let glass = NSGlassEffectView()
    private let face = NSView()
    /// The chip's own drawing (symbol, label) sits on the glass.
    let clip = CALayer()
    private static let veil: CGFloat = 0.16
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glass.style = .clear
        glass.tintColor = NSColor.black.withAlphaComponent(Self.veil)
        face.wantsLayer = true
        face.layer?.addSublayer(clip)
        glass.contentView = face
        addSubview(glass)
    }
    required init?(coder: NSCoder) { nil }
    /// Hover darkens the glass a little.
    func setVeil(active: Bool) {
        glass.tintColor = NSColor.black.withAlphaComponent(active ? Self.veil + 0.18 : Self.veil)
    }
    override func layout() {
        super.layout()
        glass.frame = bounds
        glass.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clip.frame = bounds
        CATransaction.commit()
    }
    /// Fades in and settles from just above; hidden chips ignore the mouse.
    func setShown(_ shown: Bool, delay: CFTimeInterval = 0, reduceMotion: Bool) {
        guard let layer else { return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = shown ? 1 : 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = layer.opacity
        fade.duration = reduceMotion ? Theme.Motion.Duration.reduced : (shown ? 0.2 : 0.14)
        fade.beginTime = CACurrentMediaTime() + delay; fade.fillMode = .backwards
        fade.preferFullRefreshRate(on: window?.screen)
        layer.add(fade, forKey: "chip-fade")
        if shown, !reduceMotion {
            let settle = CASpringAnimation.card(keyPath: "transform.translation.y", from: 5, to: 0, response: 0.38, dampingRatio: 0.7)
            settle.beginTime = CACurrentMediaTime() + delay; settle.fillMode = .backwards
            settle.preferFullRefreshRate(on: window?.screen)
            layer.add(settle, forKey: "chip-settle")
        }
        CATransaction.commit()
    }
    var isShown: Bool { (layer?.opacity ?? 0) > 0 }
    override func hitTest(_ point: NSPoint) -> NSView? { isShown ? super.hitTest(point) : nil }
}

/// What the capture already did ("Copied", "In Library"), or what went wrong, over its top-left corner.
/// "Copied" is celebrated once: a glass circle arrives, a check draws itself in it and nods, the
/// circle opens into the word, and a moment later it folds back to the quiet check.
@MainActor final class ScreenshotCardBadge: ScreenshotCardChip {
    private let icon = CALayer()
    private let check = CAShapeLayer()
    private let label = CATextLayer()
    private var popped = false
    private var content: (text: String, symbol: String, spinning: Bool)?
    /// Folded to the circle: the word is hidden.
    private var folded = false
    private var celebration = 0
    private static let font = Theme.Font.ns.text(12, weight: .semibold)
    private static let height: CGFloat = 22
    private static let maximumWidth: CGFloat = 220
    /// The symbol's centre and the word's start, from the left edge: the circle's centre, so
    /// folding changes only the width.
    private static let iconCentre: CGFloat = height / 2
    private static let textStart: CGFloat = height + 1
    private var isCopied: Bool { content?.text == String(localized: "Copied") && content?.symbol == "checkmark" }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.opacity = 0
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        icon.contentsScale = scale
        label.font = Self.font
        label.fontSize = 12
        label.foregroundColor = NSColor.white.cgColor
        label.contentsScale = scale
        label.truncationMode = .end
        check.fillColor = nil
        check.strokeColor = NSColor.white.cgColor
        check.lineWidth = 1.9
        check.lineCap = .round
        check.lineJoin = .round
        check.bounds = CGRect(x: 0, y: 0, width: 13, height: 13)
        let mark = CGMutablePath()
        mark.move(to: CGPoint(x: 1.8, y: 6.6))
        mark.addLine(to: CGPoint(x: 5.1, y: 3.2))
        mark.addLine(to: CGPoint(x: 11.3, y: 9.9))
        check.path = mark
        check.opacity = 0
        clip.addSublayer(icon)
        clip.addSublayer(check)
        clip.addSublayer(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var preferredSize: CGSize {
        guard let content else { return CGSize(width: 0, height: Self.height) }
        if folded { return CGSize(width: Self.height, height: Self.height) }
        let text = ceil(NSAttributedString(string: content.text, attributes: [.font: Self.font]).size().width)
        return CGSize(width: min(Self.maximumWidth, Self.textStart + text + 10), height: Self.height)
    }
    func show(status: String?, busy: Bool, error: String?) {
        let next: (text: String, symbol: String, spinning: Bool)?
        if let error { next = (error, "exclamationmark.triangle.fill", false) }
        else if busy { next = (status ?? "", "arrow.trianglehead.2.clockwise", true) }
        else if let status { next = (status, status == String(localized: "Copied") ? "checkmark" : "tray.fill", false) }
        else { next = nil }
        let changed = next?.text != content?.text || next?.symbol != content?.symbol
        content = next
        guard changed else { return }
        let scale = icon.contentsScale
        // The check is drawn, not a symbol, so it can draw itself.
        icon.contents = isCopied ? nil : next.flatMap { ScreenshotCardActionButton.symbol($0.symbol, scale: scale, pointSize: 11, weight: .bold) }
        label.string = next?.text
        setAccessibilityLabel(next?.text)
        toolTip = error
        icon.removeAnimation(forKey: "badge-spin")
        if next?.spinning == true {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0; spin.toValue = -2 * Double.pi; spin.duration = 0.9; spin.repeatCount = .infinity
            icon.add(spin, forKey: "badge-spin")
        }
        celebration += 1
        setFolded(false, animated: false)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        check.removeAllAnimations()
        check.opacity = isCopied ? 1 : 0
        check.strokeEnd = 1
        label.opacity = 1
        CATransaction.commit()
        superview?.needsLayout = true
        needsLayout = true
        if popped {
            if isCopied { celebrate(after: 0) } else { setShown(next != nil, reduceMotion: false) }
        }
    }
    /// The badge arrives just after the card does.
    func pop(after delay: CFTimeInterval, reduceMotion: Bool) {
        popped = true
        guard content != nil else { return }
        if isCopied && !reduceMotion { celebrate(after: delay) } else { setShown(true, delay: delay, reduceMotion: reduceMotion) }
    }

    private func celebrate(after delay: CFTimeInterval) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setShown(true, delay: delay, reduceMotion: true); return
        }
        celebration += 1
        let token = celebration
        setFolded(true, animated: false)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        label.opacity = 0
        check.opacity = 1
        check.strokeEnd = 1
        let start = CACurrentMediaTime() + delay
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0; draw.toValue = 1
        draw.beginTime = start + 0.1; draw.duration = 0.3
        draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
        draw.fillMode = .backwards
        check.add(draw, forKey: "check-draw")
        let nod = CAKeyframeAnimation(keyPath: "transform.scale")
        nod.values = [1, 1.2, 1]
        nod.keyTimes = [0, 0.4, 1]
        nod.beginTime = start + 0.36; nod.duration = 0.32
        nod.timingFunction = CAMediaTimingFunction(name: .easeOut)
        check.add(nod, forKey: "check-nod")
        CATransaction.commit()
        setShown(true, delay: delay, reduceMotion: false)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.62))
            guard let self, self.celebration == token else { return }
            self.setFolded(false, animated: true)
            try? await Task.sleep(for: .seconds(2.2))
            guard self.celebration == token else { return }
            self.setFolded(true, animated: true)
        }
    }

    /// Opens to the word or folds to the circle; the glass reshapes with it.
    private func setFolded(_ folded: Bool, animated: Bool) {
        guard folded != self.folded else { return }
        self.folded = folded
        guard animated, let well = superview else { superview?.needsLayout = true; return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = label.presentation()?.opacity ?? label.opacity
        fade.toValue = folded ? 0 : 1
        fade.duration = folded ? 0.16 : 0.26
        fade.beginTime = CACurrentMediaTime() + (folded ? 0 : 0.08)
        fade.fillMode = .backwards
        CATransaction.begin(); CATransaction.setDisableActions(true)
        label.opacity = folded ? 0 : 1
        label.add(fade, forKey: "badge-word")
        CATransaction.commit()
        well.needsLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = folded ? 0.34 : 0.42
            context.timingFunction = folded ? CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
                                            : CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.06)
            context.allowsImplicitAnimation = true
            well.layoutSubtreeIfNeeded()
        }
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        icon.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        icon.transform = CATransform3DMakeScale(13.0 / 24, 13.0 / 24, 1)
        icon.position = CGPoint(x: Self.iconCentre, y: bounds.midY)
        check.position = icon.position
        let textHeight = ceil(Self.font.ascender - Self.font.descender)
        let fullWidth = content.map { ceil(NSAttributedString(string: $0.text, attributes: [.font: Self.font]).size().width) } ?? 0
        label.frame = CGRect(x: Self.textStart, y: (bounds.height - textHeight) / 2,
                             width: min(fullWidth, Self.maximumWidth - Self.textStart - 10), height: textHeight)
        CATransaction.commit()
    }
}

/// Closes the card from its top-right corner; it appears with the hover actions.
@MainActor final class ScreenshotCardCloseButton: ScreenshotCardChip {
    static let side: CGFloat = 24
    var action: (() -> Void)?
    private let icon = CALayer()
    private var tracking: NSTrackingArea?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.opacity = 0
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        icon.contents = ScreenshotCardActionButton.symbol("xmark", scale: scale, pointSize: 10, weight: .bold)
        icon.contentsScale = scale
        clip.addSublayer(icon)
        toolTip = String(localized: "Dismiss screenshot")
    }
    required init?(coder: NSCoder) { nil }
    func setRevealed(_ revealed: Bool, reduceMotion: Bool) {
        guard revealed != isShown else { return }
        setShown(revealed, reduceMotion: reduceMotion)
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        icon.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        icon.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        tracking = area; addTrackingArea(area)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { setVeil(active: true) }
    override func mouseExited(with event: NSEvent) { setVeil(active: false) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { String(localized: "Dismiss screenshot") }
    override func accessibilityPerformPress() -> Bool { action?(); return action != nil }
}

extension CASpringAnimation {
    /// A spring described the way designers tune it: response (seconds) and damping ratio.
    static func card(keyPath: String, from: Any, to: Any, response: Double, dampingRatio: Double) -> CASpringAnimation {
        let angularFrequency = 2 * Double.pi / response
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = angularFrequency * angularFrequency
        animation.damping = 2 * dampingRatio * angularFrequency
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        return animation
    }
}
