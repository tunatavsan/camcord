import AppKit
import CoreImage
import QuartzCore

/// The well's backdrop and the action band's blur levels, rendered once per capture off the main actor.
enum ScreenshotCardBlur {
    struct Rendered: Sendable {
        let fill: CGImage?
        let levels: [CGImage]
    }
    /// Gaussian sigmas, in points, of the band's stacked levels, lightest first.
    static let levelSigmas: [CGFloat] = [3, 8, 18]
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func render(_ image: CGImage, imageRect: CGRect, scale: CGFloat) async -> Rendered {
        await Task.detached(priority: .userInitiated) { renderNow(image, imageRect: imageRect, scale: scale) }.value
    }

    static func renderNow(_ image: CGImage, imageRect: CGRect, scale: CGFloat) -> Rendered {
        let source = CIImage(cgImage: image)
        let well = CGRect(x: 0, y: 0, width: ScreenshotCardGeometry.well.width * scale,
                          height: ScreenshotCardGeometry.well.height * scale)
        guard source.extent.width > 0, source.extent.height > 0, imageRect.width > 0, imageRect.height > 0 else {
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
        // The band blurs exactly what the well shows: the sharp capture over its fill.
        let sharp = source
            .transformed(by: CGAffineTransform(scaleX: imageRect.width * scale / source.extent.width,
                                               y: imageRect.height * scale / source.extent.height))
            .transformed(by: CGAffineTransform(translationX: imageRect.minX * scale, y: imageRect.minY * scale))
        let composite = sharp.composited(over: fill).clampedToExtent()
        let band = CGRect(x: 0, y: 0, width: well.width, height: ScreenshotCardGeometry.band * scale)
        let levels = levelSigmas.compactMap { sigma in
            context.createCGImage(composite.applyingGaussianBlur(sigma: sigma * scale).cropped(to: band), from: band)
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
    private(set) var revealed = false
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
        guard revealed != self.revealed else { return }
        self.revealed = revealed
        let screen = window?.screen
        veil.reveal(revealed, reduceMotion: reduceMotion, screen: screen)
        for (index, button) in buttons.enumerated() {
            let delay = revealed && !reduceMotion ? 0.05 + Double(index) * 0.028 : 0
            button.reveal(revealed, delay: delay, reduceMotion: reduceMotion, screen: screen)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard revealed else { return nil }
        // The band swallows clicks between its buttons: they never open the editor by accident.
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        veil.frame = bounds
        let slot = bounds.width / CGFloat(max(1, buttons.count))
        let side: CGFloat = 38
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: (CGFloat(index) * slot + (slot - side) / 2).rounded(), y: 7, width: side, height: side)
        }
    }

    private func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = actions.map { ScreenshotCardActionButton(action: $0) }
        for button in buttons {
            button.isEnabled = isEnabled && button.action.enabled
            addSubview(button)
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
        scrim.colors = [NSColor.black.withAlphaComponent(0.36).cgColor, NSColor.black.withAlphaComponent(0.14).cgColor,
                        NSColor.clear.cgColor]
        scrim.locations = [0, 0.45, 1]
        veil.addSublayer(scrim)
        layer?.addSublayer(veil)
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Heavier blur toward the bottom: each level fades out higher than the one above it.
    func setLevels(_ images: [CGImage]) {
        levels.forEach { $0.removeFromSuperlayer() }
        let stops: [(solid: Double, clear: Double)] = [(0.45, 0.95), (0.3, 0.75), (0.12, 0.55)]
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

/// One round action: a white symbol over the blur, a soft disc on hover, a press that gives.
@MainActor final class ScreenshotCardActionButton: NSView {
    let action: ScreenshotCardActionBand.Action
    var isEnabled = true {
        didSet {
            icon.opacity = isEnabled ? 1 : 0.35
            if !isEnabled { setHighlighted(false) }
        }
    }
    /// Reveal motion; `press` inside it owns the press, so the two never fight.
    private let stage = CALayer()
    private let press = CALayer()
    private let disc = CALayer()
    private let icon = CALayer()
    private var tracking: NSTrackingArea?
    private var pressed = false
    private static let hidden = CATransform3DConcat(CATransform3DMakeScale(0.8, 0.8, 1), CATransform3DMakeTranslation(0, -10, 0))
    private static let leaving = CATransform3DConcat(CATransform3DMakeScale(0.92, 0.92, 1), CATransform3DMakeTranslation(0, -6, 0))

    init(action: ScreenshotCardActionBand.Action) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        stage.opacity = 0
        stage.transform = Self.hidden
        disc.backgroundColor = NSColor.white.withAlphaComponent(0.24).cgColor
        disc.opacity = 0
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        if let symbol = Self.symbol(action.symbol, scale: scale) {
            icon.contents = symbol.image
            icon.contentsScale = scale
            icon.bounds = CGRect(origin: .zero, size: symbol.size)
        }
        icon.shadowColor = NSColor.black.cgColor
        icon.shadowOpacity = 0.35
        icon.shadowRadius = 2
        icon.shadowOffset = CGSize(width: 0, height: -0.5)
        press.addSublayer(disc)
        press.addSublayer(icon)
        stage.addSublayer(press)
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

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stage.bounds = bounds; stage.position = CGPoint(x: bounds.midX, y: bounds.midY)
        press.bounds = bounds; press.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let side = min(bounds.width, bounds.height) - 4
        disc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        disc.cornerRadius = side / 2
        disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
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
    override func mouseEntered(with event: NSEvent) { if isEnabled { setHighlighted(true) } }
    override func mouseExited(with event: NSEvent) {
        setHighlighted(false)
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

    private func setHighlighted(_ highlighted: Bool) {
        let from = disc.presentation()?.opacity ?? disc.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        disc.opacity = highlighted ? 1 : 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = disc.opacity
        fade.duration = highlighted ? 0.12 : 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.preferFullRefreshRate(on: window?.screen)
        disc.add(fade, forKey: "disc-fade")
        CATransaction.commit()
    }

    private func setPressed(_ down: Bool) {
        let from = press.presentation()?.transform ?? press.transform
        let to = down ? CATransform3DMakeScale(0.88, 0.88, 1) : CATransform3DIdentity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        press.transform = to
        let motion = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: to),
                                            response: down ? 0.16 : 0.32, dampingRatio: down ? 1 : 0.6)
        motion.preferFullRefreshRate(on: window?.screen)
        press.add(motion, forKey: "button-press")
        CATransaction.commit()
    }

    private static func symbol(_ name: String, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        else { return nil }
        let size = image.size
        guard let context = CGContext(data: nil, width: Int((size.width * scale).rounded(.up)), height: Int((size.height * scale).rounded(.up)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage().map { ($0, size) }
    }
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
