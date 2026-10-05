import AppKit
import QuartzCore

/// The moment a screenshot is taken. The capture appears over the very place it was taken and
/// the glass light draws around it, as it does around a scroll capture, blinking where its ends
/// meet. Then it glides on a gentle curve into the corner, and on the way its card forms around
/// the place it is heading for, so it arrives as the card's own capture: nothing pops in, and
/// nothing doubles. It lives in its own click-through panel above the card.
@MainActor enum CaptureFlight {
    private static var panels: [NSPanel] = []

    /// How long the light holds the capture in place before it leaves.
    static let hold: CFTimeInterval = 0.36
    /// The glide into the card.
    static let glide: CFTimeInterval = 0.54
    /// When the card starts to form, from now: a little before halfway along the glide.
    static var forming: CFTimeInterval { hold + glide * 0.4 }
    /// When the capture lands in the card, from now.
    static var arrival: CFTimeInterval { hold + glide }

    /// - Parameters: source and target in global AppKit points; target is where the card shows
    ///   the capture.
    /// - Parameters: rounded, whether the card shows the capture with its well's rounded corners
    ///   (it fills the well) or square inside it.
    /// - Returns: when the card starts to form and when the capture lands in it, in media time;
    ///   nil when nothing flies.
    @discardableResult
    static func fly(_ image: CGImage, from source: CGRect, to target: CGRect, rounded: Bool = true)
        -> (forming: CFTimeInterval, arrival: CFTimeInterval)? {
        guard source.width >= 8, source.height >= 8, target.width >= 1, target.height >= 1,
              image.width > 0, image.height > 0 else { return nil }
        // The capture's own shape inside the place it was taken.
        let start = aspectFit(CGSize(width: image.width, height: image.height), in: source)
        let area = start.union(target).insetBy(dx: -40, dy: -40)
        let panel = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(origin: .zero, size: area.size))
        view.wantsLayer = true
        panel.contentView = view
        guard let root = view.layer else { return nil }

        let leaving = start.offsetBy(dx: -area.minX, dy: -area.minY)
        let landing = target.offsetBy(dx: -area.minX, dy: -area.minY)
        // The carrier keeps the capture's own size; the glide scales it down to the card's.
        let scale = landing.width / leaving.width
        let radius = (rounded ? Theme.Radius.well : 0) / scale
        let carrier = CALayer()
        carrier.bounds = CGRect(origin: .zero, size: leaving.size)
        carrier.position = CGPoint(x: landing.midX, y: landing.midY)
        carrier.transform = CATransform3DMakeScale(scale, scale, 1)
        carrier.shadowColor = NSColor.black.cgColor
        carrier.shadowOffset = CGSize(width: 0, height: -2 / scale)
        carrier.shadowRadius = 12 / scale
        carrier.shadowOpacity = 0
        carrier.shadowPath = CGPath(roundedRect: carrier.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let photo = CALayer()
        photo.frame = carrier.bounds
        photo.contents = image
        photo.contentsGravity = .resize
        photo.minificationFilter = .trilinear
        photo.masksToBounds = true
        photo.cornerCurve = .continuous
        photo.cornerRadius = radius
        carrier.addSublayer(photo)
        // The light sits just inside the capture's edge, so a whole screen shows all of it.
        let ring = LitRing(flarePeak: 0.7)
        ring.layer.frame = carrier.bounds
        let inset = LitRing.lineWidth
        ring.set(ring: carrier.bounds.insetBy(dx: inset, dy: inset), radius: Theme.Radius.well)
        carrier.addSublayer(ring.layer)
        root.addSublayer(carrier)

        let now = CACurrentMediaTime()
        let leaves = now + hold
        let glideTiming = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.15, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.light(at: now)
        // A gentle curve: down first, then into the corner, the way a sheet slides into a tray.
        let from = CGPoint(x: leaving.midX, y: leaving.midY), to = CGPoint(x: landing.midX, y: landing.midY)
        let path = CGMutablePath()
        path.move(to: from)
        path.addQuadCurve(to: to, control: CGPoint(x: from.x + (to.x - from.x) * 0.25, y: to.y + (from.y - to.y) * 0.3))
        let travel = CAKeyframeAnimation(keyPath: "position")
        travel.path = path
        travel.calculationMode = .paced
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = scale
        let glideGroup = CAAnimationGroup()
        glideGroup.animations = [travel, shrink]
        glideGroup.beginTime = leaves
        glideGroup.duration = glide
        glideGroup.timingFunction = glideTiming
        glideGroup.fillMode = .backwards
        glideGroup.preferFullRefreshRate(on: panel.screen)
        carrier.add(glideGroup, forKey: "glide")
        // Square and flat where it was taken, as the screen was; rounded and lifted in the card.
        let rounding = CABasicAnimation(keyPath: "cornerRadius")
        rounding.fromValue = 0
        rounding.toValue = radius
        rounding.beginTime = leaves
        rounding.duration = glide * 0.7
        rounding.timingFunction = glideTiming
        rounding.fillMode = .backwards
        photo.add(rounding, forKey: "rounding")
        // Lifted while it travels; the tray's own shadow takes over as it opens.
        let lift = CAKeyframeAnimation(keyPath: "shadowOpacity")
        lift.values = [0, 0.3, 0.2, 0]
        lift.keyTimes = [0, 0.3, 0.7, 1]
        lift.beginTime = leaves
        lift.duration = glide
        carrier.add(lift, forKey: "lift")
        // The light lets go as the capture leaves.
        let dim = CABasicAnimation(keyPath: "opacity")
        dim.fromValue = 1
        dim.toValue = 0
        dim.beginTime = leaves + 0.08
        dim.duration = glide * 0.45
        dim.fillMode = .both
        dim.isRemovedOnCompletion = false
        ring.layer.add(dim, forKey: "dim")
        // The tray has opened under it, showing the same capture: it hands over and leaves.
        let handover = CABasicAnimation(keyPath: "opacity")
        handover.fromValue = 1
        handover.toValue = 0
        handover.beginTime = leaves + glide + 0.03
        handover.duration = 0.1
        handover.fillMode = .forwards
        handover.isRemovedOnCompletion = false
        carrier.add(handover, forKey: "handover")
        CATransaction.commit()

        panels.append(panel)
        panel.orderFrontRegardless()
        let total = hold + glide + 0.25
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(total))
            panel.orderOut(nil)
            panels.removeAll { $0 === panel }
        }
        return (now + forming, now + arrival)
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }
}
