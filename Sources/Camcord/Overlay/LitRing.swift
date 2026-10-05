import AppKit
import QuartzCore

/// The app's glass light. A crisp light line over a dark halo, so it reads on a white page and
/// on a black one, with a soft glow. Lit, it draws itself from the top centre down both sides,
/// brighter than white on a display that can show it, with a faint bloom; where the ends meet at
/// the bottom a small point of light blinks once, and the line cools to its resting white. The
/// scroll capture's frame, a screenshot's moment and a pin's arrival all wear it. Its layer is
/// placed by its owner; everything is drawn in that layer's coordinates.
@MainActor final class LitRing {
    let layer = CALayer()
    private let halo = CAShapeLayer()
    private let line = CAShapeLayer()
    private let glow = CAShapeLayer()
    /// The line while it draws: above white, with a bloom of its own.
    private let bloom = CAShapeLayer()
    /// The point of light where the ends meet.
    private let spark = CAShapeLayer()
    /// The glow at the moment the ends meet.
    private let flarePeak: Float

    static let lineWidth: CGFloat = 2
    /// The glow's opacity at rest.
    static let restingGlow: Float = 0.5
    /// How long the line takes to draw.
    static let drawDuration: CFTimeInterval = 0.36
    /// How far above white the drawing line goes, where the display has the headroom.
    static let brightness: CGFloat = 1.8

    init(flarePeak: Float = 0.85) {
        self.flarePeak = flarePeak
        for shape in [halo, line, glow, bloom] {
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
        glow.shadowRadius = 7
        glow.shadowOpacity = 0.8
        glow.opacity = Self.restingGlow
        let bright = Self.extendedWhite(Self.brightness)
        bloom.strokeColor = bright
        bloom.lineWidth = Self.lineWidth
        bloom.shadowColor = bright
        bloom.shadowOffset = .zero
        bloom.shadowRadius = 3
        bloom.shadowOpacity = 0.7
        bloom.opacity = 0
        spark.fillColor = Self.extendedWhite(Self.brightness + 0.4)
        spark.shadowColor = spark.fillColor
        spark.shadowOffset = .zero
        spark.shadowRadius = 5
        spark.shadowOpacity = 0.9
        spark.opacity = 0
        for bright in [bloom, spark] { bright.preferredDynamicRange = .constrainedHigh }
        for sublayer in [halo, glow, line, bloom, spark] { layer.addSublayer(sublayer) }
    }

    /// White `level` times as bright as the display's white, where it has the headroom; plain
    /// white where it has none.
    static func extendedWhite(_ level: CGFloat) -> CGColor {
        guard let space = CGColorSpace(name: CGColorSpace.extendedSRGB),
              let color = CGColor(headroom: Float(level), colorSpace: space, red: level, green: level, blue: level, alpha: 1)
        else { return NSColor.white.cgColor }
        return color
    }

    /// The line along `ring` with corners of `radius`.
    func set(ring: CGRect, radius: CGFloat) {
        let path = Self.ringPath(ring, radius: radius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [halo, line, glow, bloom] {
            shape.frame = layer.bounds
            shape.path = path
        }
        let stroked = path.copy(strokingWithWidth: Self.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 1)
        glow.shadowPath = stroked
        bloom.shadowPath = stroked
        let point: CGFloat = 2.5
        spark.frame = CGRect(x: ring.midX - point, y: ring.minY - point, width: point * 2, height: point * 2)
        spark.path = CGPath(ellipseIn: spark.bounds, transform: nil)
        spark.shadowPath = spark.path
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
        for shape in [halo, line, bloom] {
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
        // Bright while it draws, cooling to the resting white once the ends have met.
        let cool = CAKeyframeAnimation(keyPath: "opacity")
        cool.values = [1, 1, 0]
        cool.keyTimes = [0, 0.55, 1]
        cool.beginTime = now
        cool.duration = Self.drawDuration + 0.3
        cool.fillMode = .backwards
        bloom.add(cool, forKey: "cool")
        // The glow lifts as the ends meet, then settles.
        let flare = CAKeyframeAnimation(keyPath: "opacity")
        flare.values = [0, 0, NSNumber(value: flarePeak), NSNumber(value: min(Self.restingGlow, flarePeak))]
        flare.keyTimes = [0, 0.35, 0.55, 1]
        flare.beginTime = now
        flare.duration = 0.6
        flare.fillMode = .backwards
        glow.add(flare, forKey: "flare")
        // A small point of light where they meet: it blinks and is gone.
        let meet = now + Self.drawDuration * 0.62
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [0, 1, 0]
        blink.keyTimes = [0, 0.25, 1]
        blink.beginTime = meet
        blink.duration = 0.34
        spark.add(blink, forKey: "blink")
        let bud = CAKeyframeAnimation(keyPath: "transform.scale")
        bud.values = [0.3, 1.2, 0.7]
        bud.keyTimes = [0, 0.3, 1]
        bud.beginTime = meet
        bud.duration = 0.34
        bud.timingFunction = CAMediaTimingFunction(name: .easeOut)
        spark.add(bud, forKey: "bud")
    }
}
