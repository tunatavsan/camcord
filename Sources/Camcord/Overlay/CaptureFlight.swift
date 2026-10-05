import AppKit
import QuartzCore

/// The moment a screenshot is taken. The capture appears over the very place it was taken, that
/// place flashes once, and the capture flies down into its card, which slides in to meet it.
/// It lives in its own click-through panel above the card and is gone in under a second.
@MainActor enum CaptureFlight {
    private static var panels: [NSPanel] = []

    /// How long the flash holds the capture in place before it leaves.
    static let hold: CFTimeInterval = 0.12
    /// The spring that carries it into the card.
    static let response: Double = 0.44
    static let dampingRatio: Double = 0.88

    /// - Parameters: source and target in global AppKit points; target is where the card shows
    ///   the capture.
    static func fly(_ image: CGImage, from source: CGRect, to target: CGRect) {
        guard source.width >= 8, source.height >= 8, target.width >= 1, target.height >= 1,
              image.width > 0, image.height > 0 else { return }
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
        guard let root = view.layer else { return }

        let landing = target.offsetBy(dx: -area.minX, dy: -area.minY)
        let leaving = start.offsetBy(dx: -area.minX, dy: -area.minY)
        let carrier = CALayer()
        carrier.frame = landing
        carrier.shadowColor = NSColor.black.cgColor
        carrier.shadowOffset = CGSize(width: 0, height: -2)
        carrier.shadowRadius = 10
        carrier.shadowOpacity = 0.35
        carrier.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: landing.size),
                                    cornerWidth: Theme.Radius.well, cornerHeight: Theme.Radius.well, transform: nil)
        let photo = CALayer()
        photo.frame = carrier.bounds
        photo.contents = image
        photo.contentsGravity = .resize
        photo.minificationFilter = .trilinear
        photo.masksToBounds = true
        photo.cornerCurve = .continuous
        photo.cornerRadius = Theme.Radius.well
        photo.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        photo.borderWidth = 0
        let flash = CALayer()
        flash.frame = photo.bounds
        flash.backgroundColor = NSColor.white.cgColor
        flash.opacity = 0
        photo.addSublayer(flash)
        carrier.addSublayer(photo)
        root.addSublayer(carrier)

        let now = CACurrentMediaTime()
        let scale = leaving.width / landing.width
        let from = CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
                                       CATransform3DMakeTranslation(leaving.midX - landing.midX, leaving.midY - landing.midY, 0))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Over the place it was taken, square-cornered and without a shadow, as the screen was.
        let travel = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: from),
                                            to: NSValue(caTransform3D: CATransform3DIdentity),
                                            response: response, dampingRatio: dampingRatio)
        travel.beginTime = now + hold
        travel.fillMode = .backwards
        travel.preferFullRefreshRate(on: panel.screen)
        carrier.add(travel, forKey: "travel")
        let lands = travel.settlingDuration * 0.8
        let rounding = CABasicAnimation(keyPath: "cornerRadius")
        rounding.fromValue = 0
        rounding.toValue = Theme.Radius.well
        rounding.beginTime = now + hold
        rounding.duration = lands * 0.6
        rounding.fillMode = .backwards
        photo.add(rounding, forKey: "rounding")
        let lift = CABasicAnimation(keyPath: "shadowOpacity")
        lift.fromValue = 0
        lift.toValue = 0.35
        lift.beginTime = now + hold
        lift.duration = lands * 0.5
        lift.fillMode = .backwards
        carrier.add(lift, forKey: "lift")
        // The flash: a breath of light over the capture, gone before it moves far.
        let light = CAKeyframeAnimation(keyPath: "opacity")
        light.values = [0, 0.42, 0]
        light.keyTimes = [0, 0.25, 1]
        light.duration = 0.3
        flash.add(light, forKey: "flash")
        // Held at the place it was taken, the capture is scaled by `scale`: its rim is not.
        let rim = CAKeyframeAnimation(keyPath: "borderWidth")
        rim.values = [0, 2.5 / scale, 0]
        rim.keyTimes = [0, 0.3, 1]
        rim.duration = 0.34
        photo.add(rim, forKey: "rim")
        // The card is under it by now, showing the same capture: it hands over and leaves.
        let handover = CABasicAnimation(keyPath: "opacity")
        handover.fromValue = 1
        handover.toValue = 0
        handover.beginTime = now + hold + lands
        handover.duration = 0.14
        handover.fillMode = .forwards
        handover.isRemovedOnCompletion = false
        carrier.add(handover, forKey: "handover")
        CATransaction.commit()

        panels.append(panel)
        panel.orderFrontRegardless()
        let total = hold + lands + 0.2
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(total))
            panel.orderOut(nil)
            panels.removeAll { $0 === panel }
        }
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }
}
