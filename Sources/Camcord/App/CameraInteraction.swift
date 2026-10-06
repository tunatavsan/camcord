import Foundation

/// One spring carries pointer following, magnetic resistance, breakaway and docking.
/// Changing the target never resets the visible position or its velocity.
struct CameraDragMotion {
    private(set) var frame: CGRect
    private(set) var velocity: CGPoint = .zero
    private(set) var target: CGPoint
    private(set) var magnetCorner: CameraCorner?
    private(set) var released = false
    /// How far the release has to travel: the dock spring is chosen once, at the throw,
    /// so it cannot stiffen underneath the user as the frame closes in.
    private var throwDistance: CGFloat = 0
    let area: CGSize

    init(frame: CGRect, area: CGSize, velocity: CGPoint = .zero) {
        self.frame = frame
        self.area = area
        self.target = frame.origin
        self.velocity = velocity
        if let magnet = CameraOptions.magnet(for: frame, in: area, latched: nil),
           hypot(frame.minX - magnet.rect.minX, frame.minY - magnet.rect.minY) < 12 {
            magnetCorner = magnet.corner
        }
    }

    /// How far ahead a release is projected: a flick docks where the throw was heading,
    /// not where the pointer happened to stop.
    static let flingProjection: TimeInterval = 0.35
    /// Only a throw docks. A slower release leaves the camera where it was dropped, with
    /// the ordinary magnet still catching a drop made near a corner.
    static let flingSpeed: CGFloat = 600

    /// A released dock softens with the distance it has to cover: 84 pt seats crisply,
    /// while a centre-to-corner throw at the same stiffness feels flung. Damping tracks
    /// stiffness at ζ ≈ 0.73 — one light overshoot, seated well inside 450 ms.
    static func releasedSpring(distance: CGFloat) -> (stiffness: CGFloat, damping: CGFloat) {
        let reach = min(max((distance - 84) / (780 - 84), 0), 1)
        let stiffness = 1800 - reach * 900
        return (stiffness, 2 * 0.73 * sqrt(stiffness))
    }

    /// One unbounded spring step. The live drag runs it inside its own clamp; a test can
    /// run it against a target no bound sits on and see the overshoot the user feels.
    static func integrate(_ position: inout CGPoint, velocity: inout CGPoint, toward target: CGPoint,
                          stiffness: CGFloat, damping: CGFloat, seconds dt: TimeInterval) {
        velocity.x += ((target.x - position.x) * stiffness - velocity.x * damping) * dt
        velocity.y += ((target.y - position.y) * stiffness - velocity.y * damping) * dt
        position.x += velocity.x * dt
        position.y += velocity.y * dt
    }

    mutating func follow(_ origin: CGPoint, released: Bool = false) {
        self.released = released
        if released {
            if hypot(velocity.x, velocity.y) >= Self.flingSpeed {
                let projected = CGRect(x: origin.x + velocity.x * Self.flingProjection,
                                       y: origin.y + velocity.y * Self.flingProjection,
                                       width: frame.width, height: frame.height)
                let dock = CameraOptions.magnet(for: projected, in: area, latched: nil, reach: .infinity)
                magnetCorner = dock?.corner
                target = constrained(dock?.rect.origin ?? origin)
            } else {
                let dropped = CGRect(origin: origin, size: frame.size)
                let dock = CameraOptions.magnet(for: dropped, in: area, latched: magnetCorner)
                magnetCorner = dock?.corner
                target = constrained(dock?.rect.origin ?? origin)
            }
            throwDistance = hypot(target.x - frame.minX, target.y - frame.minY)
            return
        }
        let pointerFrame = CGRect(origin: origin, size: frame.size)
        let magnet = CameraOptions.magnet(for: pointerFrame, in: area, latched: magnetCorner)
        magnetCorner = magnet?.corner
        if let magnet {
            let dx = origin.x - magnet.rect.minX
            let dy = origin.y - magnet.rect.minY
            // Pulling stretches the dock, with increasing resistance. Beyond the
            // release radius the same spring catches up to the untouched pointer.
            let resistance = released ? 0 : 0.28 / (1 + hypot(dx, dy) / 160)
            target = CGPoint(x: magnet.rect.minX + dx * resistance,
                             y: magnet.rect.minY + dy * resistance)
        } else {
            target = origin
        }
        target = constrained(target)
    }

    var isSettled: Bool {
        hypot(target.x - frame.minX, target.y - frame.minY) < 0.12
            && hypot(velocity.x, velocity.y) < 2
    }

    mutating func finishImmediately() {
        frame.origin = target
        velocity = .zero
    }

    mutating func step(seconds: TimeInterval) {
        let elapsed = min(max(seconds, 0), 1.0 / 30)
        let steps = max(1, Int(ceil(elapsed * 480)))
        let dt = elapsed / Double(steps)
        // Free motion trails by about 16 ms (damping/stiffness). The dock feels heavier
        // while held, then springs home lightly underdamped once the button is lifted.
        let stiffness: CGFloat
        let damping: CGFloat
        if magnetCorner == nil {
            (stiffness, damping) = (14400, 240)
        } else if released {
            (stiffness, damping) = Self.releasedSpring(distance: throwDistance)
        } else {
            (stiffness, damping) = (1100, 55)
        }
        for _ in 0..<steps {
            var next = frame.origin
            Self.integrate(&next, velocity: &velocity, toward: target,
                           stiffness: stiffness, damping: damping, seconds: dt)
            frame.origin = constrained(next)
            if frame.minX != next.x { velocity.x = 0 }
            if frame.minY != next.y { velocity.y = 0 }
        }
        if isSettled { finishImmediately() }
    }

    private func constrained(_ point: CGPoint) -> CGPoint {
        let inset = CameraOptions.margin(in: area)
        return CGPoint(x: min(max(point.x, inset), max(inset, area.width - inset - frame.width)),
                       y: min(max(point.y, inset), max(inset, area.height - inset - frame.height)))
    }
}

/// What the pointer is over on the floating camera: a resize corner, or the close button.
enum CameraHotspot: Equatable {
    case resize(CameraCorner)
    case close

    var corner: CameraCorner? {
        if case .resize(let corner) = self { return corner }
        return nil
    }
}

enum CameraResizeGeometry {
    /// The indicator, cursor and mouse-down all share these generous corner zones. The zone
    /// must CONTAIN the chip it reveals: the chip sits in the tile's own corner curve, so it
    /// reaches further in on a large camera, and a zone that stopped short would leave the
    /// visible chip dragging the tile instead of resizing it.
    static func hitRect(_ corner: CameraCorner, in bounds: CGRect) -> CGRect {
        let extent = min(max(44, CameraOptions.cornerRadius(for: bounds.size) + 8),
                         bounds.width * 0.32, bounds.height * 0.46)
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topLeft || corner == .topRight
        return CGRect(x: right ? bounds.maxX - extent : bounds.minX,
                      y: top ? bounds.maxY - extent : bounds.minY, width: extent, height: extent)
    }

    static func corner(at point: CGPoint, in bounds: CGRect) -> CameraCorner? {
        CameraCorner.allCases.first { hitRect($0, in: bounds).contains(point) }
    }

    // MARK: - Button geometry (the resize chips and the close chip)

    /// The glass chips' diameter: the same for the × and the resize chips, a little larger on a
    /// larger tile.
    static func chipDiameter(in bounds: CGRect) -> CGFloat {
        min(max(min(bounds.width, bounds.height) * 0.18, 20), 28)
    }

    /// The resize chip at a corner: seated in the corner's own curve, clear of both straight
    /// edges, and always inside the zone that reveals it — so pressing what you see resizes.
    static func resizeChipFrame(_ corner: CameraCorner, in bounds: CGRect) -> CGRect {
        let extent = hitRect(corner, in: bounds).width
        let gap = min(max(4, min(bounds.width, bounds.height) * 0.035), 10)
        let radius = min(chipDiameter(in: bounds) / 2, (extent - 1 - gap) / 2)
        let curve = CameraOptions.cornerRadius(for: bounds.size)
        // From the corner along each axis: off the straight edges by `gap`, and off the corner's
        // curve by `gap` along its diagonal — whichever sits further in.
        let offset = max(gap + radius, curve - (curve - gap - radius) / 2.squareRoot())
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topLeft || corner == .topRight
        let center = CGPoint(x: right ? bounds.maxX - offset : bounds.minX + offset,
                             y: top ? bounds.maxY - offset : bounds.minY + offset)
        return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    /// The close button's circle, centred on the tile's top edge. `nil` when the tile is too
    /// small to host one without colliding with the resize corners — a cramped × that
    /// overlaps a resize zone is worse than no ×.
    static func closeFrame(in bounds: CGRect) -> CGRect? {
        let diameter = chipDiameter(in: bounds)
        let corners = hitRect(.topLeft, in: bounds).width
        // Two ways a × does not belong: it would crowd the resize corners, or it would be a
        // third of the tile. A camera that small is closed from the chip, the menu or the key.
        guard bounds.width - 2 * corners >= diameter + 8, bounds.height >= diameter * 3 else { return nil }
        let margin = min(max(6, min(bounds.width, bounds.height) * 0.05), 14)
        return CGRect(x: bounds.midX - diameter / 2,
                      y: bounds.maxY - margin - diameter,
                      width: diameter, height: diameter)
    }

    /// What a PRESS on the close button counts as: the drawn circle plus a small slop ring.
    /// Deliberately much smaller than the reveal zone — a mouse-down on bare video near the
    /// top of the tile is a drag, not a dismissal.
    static func closeButtonRect(in bounds: CGRect) -> CGRect? {
        guard let circle = closeFrame(in: bounds) else { return nil }
        let slop = max(4, circle.width * 0.18)
        return circle.insetBy(dx: -slop, dy: -slop)
    }

    /// The zone that REVEALS the close button — the user moves to the top middle, not onto a
    /// 20 pt circle. Grown from the circle itself (two independent formulas drifted apart and
    /// left the drawn × outside the zone that summoned it), extended to the top edge, and
    /// clipped clear of the corner resize zones so it never steals a resize.
    static func closeHitRect(in bounds: CGRect) -> CGRect? {
        guard let circle = closeFrame(in: bounds) else { return nil }
        let pad = max(8, circle.width * 0.3)
        let zone = CGRect(x: circle.minX - pad, y: circle.minY - pad,
                          width: circle.width + pad * 2, height: bounds.maxY - circle.minY + pad)
        let corners = hitRect(.topLeft, in: bounds).width
        let free = CGRect(x: bounds.minX + corners, y: bounds.minY,
                          width: max(0, bounds.width - 2 * corners), height: bounds.height)
        let clipped = zone.intersection(free)
        // If clipping would cut into the button itself, there is no room for a × here.
        guard !clipped.isNull, clipped.contains(circle) else { return nil }
        return clipped
    }

    /// What the pointer HOVERS over. Corners keep priority: `closeHitRect` is already carved
    /// to avoid them, and a resize started from a corner must never be stolen by the ×.
    static func hotspot(at point: CGPoint, in bounds: CGRect) -> CameraHotspot? {
        if let corner = corner(at: point, in: bounds) { return .resize(corner) }
        if let close = closeHitRect(in: bounds), close.contains(point) { return .close }
        return nil
    }

    /// Whether a PRESS at `point` dismisses the preview. Only the button itself does — the
    /// reveal zone is a hover affordance, and closing from anywhere in it would turn a drag
    /// that started near the top of the tile into a dismissal.
    static func pressClosesPreview(at point: CGPoint, in bounds: CGRect) -> Bool {
        guard corner(at: point, in: bounds) == nil, let button = closeButtonRect(in: bounds) else { return false }
        return button.contains(point)
    }

    /// The sizes people actually pick, and the half-window around each where a resize
    /// latches on. Anything further away stays free.
    static let widthStops: [Double] = [0.15, 0.20, 0.25, 0.33]
    static let widthSnapWindow = 0.015

    /// The stop a size is exactly latched onto, if any. A resize ticks its haptic when
    /// this changes — including the seed at mouse-down, so starting on a stop is silent.
    static func latchedStop(of fraction: Double) -> Double? { widthStops.first { $0 == fraction } }

    static func snappedWidthFraction(_ fraction: Double) -> Double {
        widthStops.first { abs($0 - fraction) <= widthSnapWindow } ?? fraction
    }

    static func resize(start: CGRect, translation: CGPoint, corner: CameraCorner,
                       options: CameraOptions, in area: CGSize) -> CameraOptions {
        guard area.width > 0, area.height > 0 else { return options }
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topLeft || corner == .topRight
        let ratio = CameraOptions.aspectRatio
        let dx = right ? translation.x : -translation.x
        let dy = top ? translation.y : -translation.y
        // Project onto the 16:9 diagonal instead of switching dominant axes. A
        // slight change in pointer direction can no longer reverse/jump the size.
        let widthChange = (dx + dy / ratio) / (1 + 1 / (ratio * ratio))
        var result = options
        result.widthFraction = snappedWidthFraction((start.width + widthChange) / area.width)
        result = result.resolved()
        let size = result.rect(in: area).size
        let rect = CGRect(x: right ? start.minX : start.maxX - size.width,
                          y: top ? start.minY : start.maxY - size.height,
                          width: size.width, height: size.height)
        // Preserve the opposite corner until an edge is reached, then keep the
        // whole camera inside the recording. Docked corners can still grow.
        result.place(rect, in: area)
        return result
    }
}
