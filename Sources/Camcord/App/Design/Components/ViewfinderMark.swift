import AppKit
import SwiftUI

/// Camcord's mark: four viewfinder brackets, optionally around a tally dot. The one custom
/// glyph in the app; it appears on the status item, the sidebar, empty states, first
/// run and the capture moment.
struct ViewfinderMark: Shape {
    /// The bracket arm length as a fraction of the side.
    var armFraction: CGFloat = 0.3
    /// The corner radius of each bracket as a fraction of the side.
    var cornerFraction: CGFloat = 0.14

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        return Self.brackets(in: square, arm: side * armFraction, corner: side * cornerFraction)
    }

    /// Four corner brackets on `rect`, each arm `arm` long, rounded by `corner`.
    static func brackets(in rect: CGRect, arm: CGFloat, corner: CGFloat) -> Path {
        let corner = min(corner, arm)
        var path = Path()
        // Each bracket runs from the end of one arm, round the corner, to the end of the other.
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
        ]
        for (point, dx, dy) in corners {
            path.move(to: CGPoint(x: point.x, y: point.y + dy * arm))
            path.addLine(to: CGPoint(x: point.x, y: point.y + dy * corner))
            path.addQuadCurve(to: CGPoint(x: point.x + dx * corner, y: point.y), control: point)
            path.addLine(to: CGPoint(x: point.x + dx * arm, y: point.y))
        }
        return path
    }
}

/// The mark as a view: brackets in the current foreground style and an optional dot, red while
/// recording.
struct ViewfinderMarkView: View {
    enum Dot { case none, plain, recording }
    var dot: Dot = .plain
    /// Stroke width as a fraction of the side (the mark scales from 14 pt to 72 pt).
    var lineFraction: CGFloat = 0.085

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let line = max(1, side * lineFraction)
            ZStack {
                ViewfinderMark()
                    .stroke(style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                    .padding(line / 2)
                if dot != .none {
                    Circle()
                        .fill(dot == .recording ? AnyShapeStyle(Theme.Palette.record.color) : AnyShapeStyle(.foreground))
                        .frame(width: side * 0.26, height: side * 0.26)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "Camcord"))
        .accessibilityAddTraits(.isImage)
    }

    /// A template image of the mark for AppKit (the status item), drawn at `size` points.
    @MainActor static func templateImage(size: CGFloat, dot: Bool = true) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let line = max(1.25, size * 0.09)
            let inset = rect.insetBy(dx: line / 2 + 0.5, dy: line / 2 + 0.5)
            let path = NSBezierPath(cgPath: ViewfinderMark().path(in: inset).cgPath)
            path.lineWidth = line
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            Theme.Palette.ink.ns.setStroke()   // a template: only the alpha counts
            path.stroke()
            if dot {
                let d = size * 0.26
                Theme.Palette.ink.ns.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Camcord"
        return image
    }
}
