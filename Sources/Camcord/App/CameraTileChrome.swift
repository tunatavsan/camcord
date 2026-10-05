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
    /// Where the blur is heaviest: along the top edge, in a corner, or around a point (unit
    /// coordinates, y up) out to `reach` of the veil's side. A round falloff always reaches
    /// nothing inside the veil, so its square never shows.
    /// `band` is the top edge's blur kept to the middle: heaviest along the edge, fading down, and
    /// fading out toward both sides over `sideFade` of the width.
    enum Edge: Equatable { case top, corner(CameraCorner), spot(CGPoint, reach: CGFloat), band(sideFade: CGFloat) }
    var edge: Edge = .top { didSet { if edge != oldValue { refreshMask() } } }
    /// The surface's own outline in this view's coordinates, so the blur never spills past it.
    var outline: CGPath? { didSet { clipper.path = outline } }
    private let backdrop: CALayer?
    private let scrim = CAGradientLayer()
    private let clipper = CAShapeLayer()
    /// Fades the scrim toward both sides, for a band.
    private let scrimSides = CAGradientLayer()
    private(set) var shown = false
    /// The heaviest blur, at the edge; it falls to none across the veil.
    static let radius: CGFloat = 8

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
        scrimSides.frame = scrim.bounds
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
        // A round gradient takes its radius on each axis from the end point's offset on that axis.
        let radius = hypot(end.x - start.x, end.y - start.y)
        scrim.endPoint = radial ? CGPoint(x: start.x + radius, y: start.y + radius) : end
        let sideFade: CGFloat
        if case .band(let fade) = edge { sideFade = min(max(fade, 0.01), 0.5) } else { sideFade = 0 }
        if sideFade > 0 {
            scrimSides.startPoint = CGPoint(x: 0, y: 0.5); scrimSides.endPoint = CGPoint(x: 1, y: 0.5)
            scrimSides.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            scrimSides.locations = [0, NSNumber(value: Double(sideFade)), NSNumber(value: Double(1 - sideFade)), 1]
            scrim.mask = scrimSides
        } else {
            scrim.mask = nil
        }
        if let blur = backdrop?.filters?.first as? NSObject {
            blur.setValue(Self.mask(start: start, end: end, radial: radial, sideFade: sideFade), forKey: "inputMaskImage")
            backdrop?.filters = [blur]
        }
        CATransaction.commit()
    }

    /// Unit points, y up: where the veil is heaviest and where it has faded out; a round falloff's
    /// radius is the distance between them.
    private static func direction(of edge: Edge) -> (start: CGPoint, end: CGPoint, radial: Bool) {
        switch edge {
        case .top, .band: return (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0), false)
        case .corner(let corner):
            let x: CGFloat = corner == .topRight || corner == .bottomRight ? 1 : 0
            let y: CGFloat = corner == .topLeft || corner == .topRight ? 1 : 0
            // Faded out by 0.8 of the side: the veil's other corners and far edges stay clear.
            return (CGPoint(x: x, y: y), CGPoint(x: x == 1 ? 0.2 : 0.8, y: y), true)
        case .spot(let centre, let reach):
            return (centre, CGPoint(x: centre.x, y: centre.y - reach), true)
        }
    }

    /// The blur's strength across the veil, as an alpha mask the render server stretches over it.
    private static func mask(start: CGPoint, end: CGPoint, radial: Bool, sideFade: CGFloat = 0) -> CGImage? {
        let side = 64
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        // Eased at both ends (smoothstep): the blur holds near its heart and thins out ever more
        // slowly toward nothing, so text passes from soft to sharp without a line between them.
        let stops = 16
        let alphas = (0...stops).map { step -> CGFloat in
            let t = CGFloat(step) / CGFloat(stops)
            return 1 - t * t * (3 - 2 * t)
        }
        let colors = alphas.map { CGColor(gray: 0, alpha: $0) } as CFArray
        let locations = (0...stops).map { CGFloat($0) / CGFloat(stops) }
        guard let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: locations) else { return nil }
        let size = CGFloat(side)
        let from = CGPoint(x: start.x * size, y: start.y * size)
        if radial {
            context.drawRadialGradient(gradient, startCenter: from, startRadius: 0, endCenter: from,
                                       endRadius: size * hypot(end.x - start.x, end.y - start.y),
                                       options: [.drawsAfterEndLocation])
        } else {
            context.drawLinearGradient(gradient, start: from, end: CGPoint(x: end.x * size, y: end.y * size),
                                       options: [.drawsAfterEndLocation])
        }
        if sideFade > 0 {
            // Toward both sides it thins out the same eased way: kept, multiplied by the side fade.
            let sides = (0...stops).map { step -> CGFloat in
                let t = CGFloat(step) / CGFloat(stops)
                return t * t * (3 - 2 * t)
            }
            let colors = sides.map { CGColor(gray: 0, alpha: $0) } as CFArray
            if let rise = CGGradient(colorsSpace: nil, colors: colors, locations: locations) {
                context.setBlendMode(.destinationIn)
                let reach = size * sideFade
                context.saveGState()
                context.clip(to: CGRect(x: 0, y: 0, width: reach, height: size))
                context.drawLinearGradient(rise, start: .zero, end: CGPoint(x: reach, y: 0), options: [])
                context.restoreGState()
                context.saveGState()
                context.clip(to: CGRect(x: size - reach, y: 0, width: reach, height: size))
                context.drawLinearGradient(rise, start: CGPoint(x: size, y: 0), end: CGPoint(x: size - reach, y: 0), options: [])
                context.restoreGState()
            }
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
