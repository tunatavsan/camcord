import AppKit
import QuartzCore

/// The main window's tray as a floating surface: its light frost, a window rim and a shadow
/// cast only outside. The screenshot card and the screenshot preview stand on it.
@MainActor final class TraySurface: NSView {
    init(content: NSView, shadowRadius: CGFloat = 6) {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(TrayShadow(radius: shadowRadius))
        addSubview(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? TraySolid() : TrayBlurView(cornerRadius: Theme.Radius.floating))
        addSubview(content)
        addSubview(TrayRim())
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        for view in subviews where view.frame != bounds { view.frame = bounds }
    }
}

/// The window's rim: a light inner line and a dark outer hairline, the same in light and dark.
private final class TrayRim: NSView {
    private let inner = CALayer()
    private let outer = CALayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for (line, colour, width) in [(inner, NSColor.white.withAlphaComponent(0.16), 1.0),
                                      (outer, NSColor.black.withAlphaComponent(0.28), 0.5)] {
            line.borderColor = colour.cgColor
            line.borderWidth = width
            line.cornerCurve = .continuous
            layer?.addSublayer(line)
        }
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        inner.frame = bounds; inner.cornerRadius = Theme.Radius.floating
        outer.frame = bounds.insetBy(dx: -0.5, dy: -0.5); outer.cornerRadius = Theme.Radius.floating + 0.5
        CATransaction.commit()
    }
}

/// A shadow cast only outside the surface, so the frost never samples its own shadow.
private final class TrayShadow: NSView {
    private let caster = CALayer()
    private let cutout = CAShapeLayer()
    private let radius: CGFloat
    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        caster.shadowColor = NSColor.black.cgColor
        caster.shadowOpacity = 0.32
        caster.shadowRadius = radius
        caster.shadowOffset = CGSize(width: 0, height: -radius / 3)
        cutout.fillRule = .evenOdd
        caster.mask = cutout
        layer?.addSublayer(caster)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        let shape = CGPath(roundedRect: bounds, cornerWidth: Theme.Radius.floating, cornerHeight: Theme.Radius.floating, transform: nil)
        let margin = radius * 3
        CATransaction.begin(); CATransaction.setDisableActions(true)
        caster.frame = bounds
        caster.shadowPath = shape
        cutout.frame = bounds.insetBy(dx: -margin, dy: -margin)
        let path = CGMutablePath()
        path.addRect(cutout.bounds)
        path.addPath(shape, transform: CGAffineTransform(translationX: margin, y: margin))
        cutout.path = path
        CATransaction.commit()
    }
}

/// Reduce Transparency: the tray becomes the app's opaque panel colour.
private final class TraySolid: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.Palette.glassSolidSidebar.ns.cgColor
        layer?.cornerRadius = Theme.Radius.floating
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
