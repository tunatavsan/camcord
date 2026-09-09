import Foundation

/// One spring carries pointer following, magnetic resistance, breakaway and docking.
/// Changing the target never resets the visible position or its velocity.
struct CameraDragMotion {
    private(set) var frame: CGRect
    private(set) var velocity: CGPoint = .zero
    private(set) var target: CGPoint
    private(set) var magnetCorner: CameraCorner?
    private(set) var released = false
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

    mutating func follow(_ origin: CGPoint, released: Bool = false) {
        self.released = released
        if released {
            let projected = CGRect(x: origin.x + velocity.x * Self.flingProjection,
                                   y: origin.y + velocity.y * Self.flingProjection,
                                   width: frame.width, height: frame.height)
            let dock = CameraOptions.magnet(for: projected, in: area, latched: nil, reach: .infinity)
            magnetCorner = dock?.corner
            target = constrained(dock?.rect.origin ?? origin)
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
        let stiffness: CGFloat = magnetCorner == nil ? 14400 : (released ? 1800 : 1100)
        let damping: CGFloat = magnetCorner == nil ? 240 : (released ? 62 : 55)
        for _ in 0..<steps {
            velocity.x += ((target.x - frame.minX) * stiffness - velocity.x * damping) * dt
            velocity.y += ((target.y - frame.minY) * stiffness - velocity.y * damping) * dt
            let next = CGPoint(x: frame.minX + velocity.x * dt, y: frame.minY + velocity.y * dt)
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

enum CameraResizeGeometry {
    /// The indicator, cursor and mouse-down all share these generous corner zones.
    static func hitRect(_ corner: CameraCorner, in bounds: CGRect) -> CGRect {
        let extent = min(max(44, CameraOptions.cornerRadius(for: bounds.size) * 0.48 + 16),
                         bounds.width * 0.32, bounds.height * 0.46)
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topLeft || corner == .topRight
        return CGRect(x: right ? bounds.maxX - extent : bounds.minX,
                      y: top ? bounds.maxY - extent : bounds.minY, width: extent, height: extent)
    }

    static func corner(at point: CGPoint, in bounds: CGRect) -> CameraCorner? {
        CameraCorner.allCases.first { hitRect($0, in: bounds).contains(point) }
    }

    /// The sizes people actually pick, and the half-window around each where a resize
    /// latches on. Anything further away stays free.
    static let widthStops: [Double] = [0.15, 0.20, 0.25, 0.33]
    static let widthSnapWindow = 0.015

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
