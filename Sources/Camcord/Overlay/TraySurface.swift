import AppKit
import QuartzCore

/// The main window's tray as a floating surface: its light frost, a window rim and a shadow
/// cast only outside. The screenshot card and the screenshot preview stand on it.
@MainActor final class TraySurface: NSView {
    /// nil follows the height: a capsule with fully round ends.
    /// `tint` darkens the frost a little, for a tray that floats over anything (the hub).
    init(content: NSView, shadowRadius: CGFloat = 6, cornerRadius: CGFloat? = Theme.Radius.floating, tint: NSColor? = nil) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(TrayShadow(radius: shadowRadius, cornerRadius: cornerRadius))
        // A capsule's frost starts clipped and takes its real radius from its height in layout.
        addSubview(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? TraySolid(cornerRadius: cornerRadius) : TrayBlurView(cornerRadius: cornerRadius ?? 1))
        if let tint { addSubview(TraySolid(cornerRadius: cornerRadius, color: tint)) }
        addSubview(content)
        addSubview(TrayRim(cornerRadius: cornerRadius))
    }
    private let cornerRadius: CGFloat?
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        for view in subviews where view.frame != bounds { view.frame = bounds }
        // A capsule's frost follows its height as it grows and shrinks.
        if cornerRadius == nil, let frost = subviews.first(where: { $0 is TrayBlurView }) {
            frost.layer?.cornerRadius = bounds.height / 2
            frost.layer?.masksToBounds = true
        }
    }
}

private extension Optional where Wrapped == CGFloat {
    func resolved(for bounds: CGRect) -> CGFloat { self ?? bounds.height / 2 }
}

/// The window's rim: a light inner line and a dark outer hairline, the same in light and dark.
private final class TrayRim: NSView {
    private let inner = CALayer()
    private let outer = CALayer()
    private let cornerRadius: CGFloat?
    init(cornerRadius: CGFloat?) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
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
        let radius = cornerRadius.resolved(for: bounds)
        inner.frame = bounds; inner.cornerRadius = radius
        outer.frame = bounds.insetBy(dx: -0.5, dy: -0.5); outer.cornerRadius = radius + 0.5
        CATransaction.commit()
    }
}

/// A shadow cast only outside the surface, so the frost never samples its own shadow.
private final class TrayShadow: NSView {
    private let caster = CALayer()
    private let cutout = CAShapeLayer()
    private let radius: CGFloat
    private let cornerRadius: CGFloat?
    init(radius: CGFloat, cornerRadius: CGFloat?) {
        self.radius = radius
        self.cornerRadius = cornerRadius
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
        let corner = min(cornerRadius.resolved(for: bounds), bounds.width / 2, bounds.height / 2)
        let shape = CGPath(roundedRect: bounds, cornerWidth: corner, cornerHeight: corner, transform: nil)
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
    private let cornerRadius: CGFloat?
    init(cornerRadius: CGFloat?, color: NSColor = Theme.Palette.glassSolidSidebar.ns) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        layer?.cornerRadius = cornerRadius.resolved(for: bounds)
    }
}
