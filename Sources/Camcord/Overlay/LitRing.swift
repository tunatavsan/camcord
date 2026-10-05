import AppKit
import QuartzCore

/// The app's glass light. A crisp light line over a dark halo, so it reads on a white page and
/// on a black one, with a soft glow. Lit, it draws itself from the top centre down both sides
/// to meet at the bottom, flares as the ends meet and settles, while one wash of light crosses
/// the area inside. The scroll capture's frame, a screenshot's moment and a pin's arrival all
/// wear it. Its layer is placed by its owner; everything is drawn in that layer's coordinates.
@MainActor final class LitRing {
    let layer = CALayer()
    private let halo = CAShapeLayer()
    private let line = CAShapeLayer()
    private let glow = CAShapeLayer()
    private let wash = CAGradientLayer()
    private let washClip = CALayer()

    static let lineWidth: CGFloat = 2
    /// The glow's opacity at rest.
    static let restingGlow: Float = 0.55
    /// How long the line takes to draw, and when the wash starts and how long it crosses.
    static let drawDuration: CFTimeInterval = 0.5
    static let washDelay: CFTimeInterval = 0.22
    static let washDuration: CFTimeInterval = 0.6

    init() {
        for shape in [halo, line, glow] {
            shape.fillColor = nil
            shape.lineJoin = .round
            shape.lineCap = .round
        }
        halo.strokeColor = NSColor.black.withAlphaComponent(0.3).cgColor
        halo.lineWidth = Self.lineWidth + 2
        line.strokeColor = NSColor.white.withAlphaComponent(0.96).cgColor
        line.lineWidth = Self.lineWidth
        glow.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        glow.lineWidth = Self.lineWidth
        glow.shadowColor = NSColor.white.cgColor
        glow.shadowOffset = .zero
        glow.shadowRadius = 8
        glow.shadowOpacity = 0.9
        glow.opacity = Self.restingGlow
        washClip.masksToBounds = true
        washClip.cornerCurve = .continuous
        wash.startPoint = CGPoint(x: 0, y: 1)
        wash.endPoint = CGPoint(x: 1, y: 0)
        wash.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.13).cgColor,
                       NSColor.white.withAlphaComponent(0).cgColor]
        wash.locations = [-0.4, -0.2, 0]
        wash.opacity = 0
        washClip.addSublayer(wash)
        for sublayer in [washClip, halo, glow, line] { layer.addSublayer(sublayer) }
    }

    /// The line along `ring` with corners of `radius`; the wash crosses `area`, rounded by `areaRadius`.
    func set(ring: CGRect, radius: CGFloat, area: CGRect, areaRadius: CGFloat) {
        let path = Self.ringPath(ring, radius: radius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [halo, line, glow] {
            shape.frame = layer.bounds
            shape.path = path
        }
        glow.shadowPath = path.copy(strokingWithWidth: Self.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 1)
        washClip.frame = area
        washClip.cornerRadius = areaRadius
        wash.frame = washClip.bounds
        CATransaction.commit()
    }

    /// A rounded rectangle that starts at the bottom centre and runs counterclockwise (up the
    /// right side), so the top centre sits exactly halfway along it.
    static func ringPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.midX, y: rect.minY), radius: r)
        path.closeSubpath()
        return path
    }

    /// Lights the ring from `start` (media time; now when nil).
    func light(at start: CFTimeInterval? = nil) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let now = start ?? CACurrentMediaTime()
        let ease = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        // Drawn from the top centre: both ends leave halfway along the path and meet at its start.
        for shape in [halo, line] {
            let begin = CABasicAnimation(keyPath: "strokeStart")
            begin.fromValue = 0.5
            begin.toValue = 0
            let end = CABasicAnimation(keyPath: "strokeEnd")
            end.fromValue = 0.5
            end.toValue = 1
            let draw = CAAnimationGroup()
            draw.animations = [begin, end]
            draw.beginTime = now
            draw.duration = Self.drawDuration
            draw.timingFunction = ease
            draw.fillMode = .backwards
            shape.add(draw, forKey: "draw")
        }
        // The glow flares as the ends meet, then settles.
        let flare = CAKeyframeAnimation(keyPath: "opacity")
        flare.values = [0, 0, 1, Self.restingGlow]
        flare.keyTimes = [0, 0.4, 0.6, 1]
        flare.beginTime = now
        flare.duration = 0.8
        flare.fillMode = .backwards
        glow.add(flare, forKey: "flare")
        // One wash of light across the area.
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.4, -0.2, 0]
        sweep.toValue = [1, 1.2, 1.4]
        sweep.beginTime = now + Self.washDelay
        sweep.duration = Self.washDuration
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.fillMode = .both
        wash.add(sweep, forKey: "sweep")
        let shown = CAKeyframeAnimation(keyPath: "opacity")
        shown.values = [1, 1]
        shown.beginTime = now + Self.washDelay
        shown.duration = Self.washDuration
        wash.add(shown, forKey: "shown")
    }
}
