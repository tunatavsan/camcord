import AppKit
import QuartzCore

/// One of the camera tile's buttons: the screenshot card's glass chip with a white symbol.
/// It only draws; the tile resolves every hover and press from its own geometry.
@MainActor final class CameraGlassChip: ScreenshotCardChip {
    private let lift = CALayer()
    private let icon = CALayer()
    private(set) var glowing = false

    init(symbol: String, pointSize: CGFloat, weight: NSFont.Weight) {
        super.init(frame: .zero)
        layer?.opacity = 0
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        icon.contents = ScreenshotCardActionButton.symbol(symbol, scale: scale, pointSize: pointSize, weight: weight)
        icon.contentsScale = scale
        icon.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        icon.shadowColor = NSColor.white.cgColor
        icon.shadowOpacity = 0
        icon.shadowRadius = 6
        icon.shadowOffset = .zero
        lift.addSublayer(icon)
        clip.addSublayer(lift)
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        lift.bounds = bounds
        lift.position = CGPoint(x: bounds.midX, y: bounds.midY)
        icon.position = lift.position
        CATransaction.commit()
    }

    /// Under the pointer the symbol swells a little and glows in its own shape, like the
    /// card's buttons.
    func setGlowing(_ glowing: Bool, reduceMotion: Bool) {
        guard glowing != self.glowing else { return }
        self.glowing = glowing
        let screen = window?.screen
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let fromGlow = icon.presentation()?.shadowOpacity ?? icon.shadowOpacity
        icon.shadowOpacity = glowing ? 0.9 : 0
        let glow = CABasicAnimation(keyPath: "shadowOpacity")
        glow.fromValue = fromGlow; glow.toValue = icon.shadowOpacity; glow.duration = glowing ? 0.16 : 0.22
        glow.preferFullRefreshRate(on: screen)
        icon.add(glow, forKey: "chip-glow")
        let fromScale = lift.presentation()?.transform ?? lift.transform
        lift.transform = glowing && !reduceMotion ? CATransform3DMakeScale(1.16, 1.16, 1) : CATransform3DIdentity
        if !reduceMotion {
            let swell = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: fromScale),
                                               to: NSValue(caTransform3D: lift.transform), response: 0.3,
                                               dampingRatio: glowing ? 0.6 : 0.85)
            swell.preferFullRefreshRate(on: screen)
            lift.add(swell, forKey: "chip-swell")
        }
        CATransaction.commit()
    }

    /// Back to rest at once: the tile is leaving the screen.
    func reset() {
        glowing = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.removeAllAnimations(); layer?.opacity = 0
        icon.removeAllAnimations(); icon.shadowOpacity = 0
        lift.removeAllAnimations(); lift.transform = CATransform3DIdentity
        CATransaction.commit()
    }
}

/// Live content blurring toward one edge or corner, heavier at the edge — the screenshot
/// card's band, on a moving image (the camera behind its buttons, a scroll capture's older
/// rows). One variable blur in the render server, so the blur keeps the content's own quality
/// and never re-renders anything on the main thread.
@MainActor final class ProgressiveBlurView: NSView {
    enum Edge: Equatable { case top, corner(CameraCorner) }
    var edge: Edge = .top { didSet { if edge != oldValue { refreshMask() } } }
    /// The surface's own outline in this view's coordinates, so the blur never spills past it.
    var outline: CGPath? { didSet { clipper.path = outline } }
    private let backdrop: CALayer?
    private let scrim = CAGradientLayer()
    private let clipper = CAShapeLayer()
    private(set) var shown = false
    /// The heaviest blur, at the edge; it falls to none across the veil.
    static let radius: CGFloat = 14

    override init(frame frameRect: NSRect) {
        backdrop = Self.makeBackdrop()
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.opacity = 0
        layer?.mask = clipper
        if let backdrop { layer?.addSublayer(backdrop) }
        scrim.colors = [NSColor.black.withAlphaComponent(0.22).cgColor, NSColor.clear.cgColor]
        layer?.addSublayer(scrim)
        setAccessibilityHidden(true)
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backdrop?.frame = bounds
        scrim.frame = bounds
        clipper.frame = bounds
        CATransaction.commit()
        refreshMask()
    }

    func setShown(_ shown: Bool, reduceMotion: Bool) {
        guard shown != self.shown, let layer else { return }
        self.shown = shown
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = shown ? 1 : 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = layer.opacity
        fade.duration = reduceMotion ? Theme.Motion.Duration.reduced : (shown ? 0.24 : 0.18)
        fade.timingFunction = CAMediaTimingFunction(name: shown ? .easeOut : .easeIn)
        fade.preferFullRefreshRate(on: window?.screen)
        layer.add(fade, forKey: "veil-fade")
        CATransaction.commit()
    }

    func reset() {
        shown = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.removeAllAnimations(); layer?.opacity = 0
        CATransaction.commit()
    }

    /// The blur and the scrim fall off from the edge the buttons sit on.
    private func refreshMask() {
        let (start, end, radial) = Self.direction(of: edge)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        scrim.type = radial ? .radial : .axial
        scrim.startPoint = start
        scrim.endPoint = end
        if let blur = backdrop?.filters?.first as? NSObject {
            blur.setValue(Self.mask(start: start, end: end, radial: radial), forKey: "inputMaskImage")
            backdrop?.filters = [blur]
        }
        CATransaction.commit()
    }

    /// Unit points, y up: where the veil is heaviest and where it has faded out.
    private static func direction(of edge: Edge) -> (start: CGPoint, end: CGPoint, radial: Bool) {
        switch edge {
        case .top: return (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0), false)
        case .corner(let corner):
            let x: CGFloat = corner == .topRight || corner == .bottomRight ? 1 : 0
            let y: CGFloat = corner == .topLeft || corner == .topRight ? 1 : 0
            // A radial gradient's end point sets its radius: the full side of the square veil.
            return (CGPoint(x: x, y: y), CGPoint(x: x == 1 ? 0 : 1, y: y == 1 ? 0 : 1), true)
        }
    }

    /// The blur's strength across the veil, as an alpha mask the render server stretches over it.
    private static func mask(start: CGPoint, end: CGPoint, radial: Bool) -> CGImage? {
        let side = 64
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        // Eased, so the blur gathers near the edge and thins out softly instead of in a ramp.
        let stops = 8
        let alphas = (0...stops).map { step -> CGFloat in
            let t = CGFloat(step) / CGFloat(stops)
            return pow(1 - t, 1.6)
        }
        let colors = alphas.map { CGColor(gray: 0, alpha: $0) } as CFArray
        let locations = (0...stops).map { CGFloat($0) / CGFloat(stops) }
        guard let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: locations) else { return nil }
        let size = CGFloat(side)
        let from = CGPoint(x: start.x * size, y: start.y * size)
        if radial {
            context.drawRadialGradient(gradient, startCenter: from, startRadius: 0, endCenter: from,
                                       endRadius: size * hypot(end.x - start.x, end.y - start.y) / sqrt(2) * 1.05,
                                       options: [.drawsAfterEndLocation])
        } else {
            context.drawLinearGradient(gradient, start: from, end: CGPoint(x: end.x * size, y: end.y * size),
                                       options: [.drawsAfterEndLocation])
        }
        return context.makeImage()
    }

    /// A backdrop layer with the system's variable blur, the one behind the toolbar's
    /// progressive edge. Without it the veil is the scrim alone.
    private static func makeBackdrop() -> CALayer? {
        guard let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              filterClass.responds(to: NSSelectorFromString("filterWithType:")),
              let blur = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?
                .takeUnretainedValue() as? NSObject
        else { return nil }
        blur.setValue(radius, forKey: "inputRadius")
        blur.setValue(true, forKey: "inputNormalizeEdges")
        let backdrop = layerClass.init()
        backdrop.filters = [blur]
        return backdrop
    }
}
