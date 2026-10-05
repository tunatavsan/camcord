import AppKit
import QuartzCore

/// Moves windows the way a hand would: each toward its target on a spring, from wherever it is
/// and however fast it is going. A new target mid-flight bends the motion instead of restarting
/// it, so a window never jumps, however often its place changes.
@MainActor final class WindowSpring {
    private struct Motion {
        weak var window: NSWindow?
        var frame: CGRect
        var velocity: (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) = (0, 0, 0, 0)
        var target: CGRect
        var response: Double
        var dampingRatio: Double
    }
    private var motions: [ObjectIdentifier: Motion] = [:]
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    /// Told after each step, with the window that moved.
    var onStep: ((NSWindow) -> Void)?

    /// Where `window` is going, or nil when it is at rest.
    func target(of window: NSWindow) -> CGRect? { motions[ObjectIdentifier(window)]?.target }

    /// Sends `window` toward `target`; a window already moving keeps its speed.
    /// - Parameters: response, the spring's period in seconds; dampingRatio, 1 for no overshoot.
    func move(_ window: NSWindow, to target: CGRect, response: Double = 0.55, dampingRatio: Double = 0.9) {
        let id = ObjectIdentifier(window)
        if var motion = motions[id] {
            motion.target = target
            motion.response = response
            motion.dampingRatio = dampingRatio
            motions[id] = motion
        } else {
            guard window.frame != target else { return }
            motions[id] = Motion(window: window, frame: window.frame, target: target, response: response, dampingRatio: dampingRatio)
        }
        start()
    }

    /// Puts `window` at `frame` at once and forgets any motion it had.
    func place(_ window: NSWindow, at frame: CGRect) {
        motions[ObjectIdentifier(window)] = nil
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    /// Leaves `window` where it is now.
    func stop(_ window: NSWindow) { motions[ObjectIdentifier(window)] = nil }

    private func start() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = min(max(now - lastTick, 0), 1.0 / 30)
        lastTick = now
        for (id, var motion) in motions {
            guard let window = motion.window else { motions[id] = nil; continue }
            let next = Self.step(&motion, seconds: elapsed)
            motion.frame = next
            if Self.settled(motion) {
                motions[id] = nil
                window.setFrame(motion.target, display: true)
            } else {
                motions[id] = motion
                window.setFrame(next, display: true)
            }
            onStep?(window)
        }
        if motions.isEmpty { timer?.invalidate(); timer = nil }
    }

    /// One step of the spring on each of the frame's four numbers, in small sub-steps so a stiff
    /// spring stays stable whatever the frame rate.
    private static func step(_ motion: inout Motion, seconds: Double) -> CGRect {
        let omega = 2 * Double.pi / max(motion.response, 0.05)
        let stiffness = omega * omega, damping = 2 * motion.dampingRatio * omega
        let steps = max(1, Int(ceil(seconds * 480)))
        let dt = seconds / Double(steps)
        var f = motion.frame, v = motion.velocity
        let t = motion.target
        func advance(_ x: inout CGFloat, _ velocity: inout CGFloat, _ goal: CGFloat) {
            let acceleration = -stiffness * Double(x - goal) - damping * Double(velocity)
            velocity += CGFloat(acceleration * dt)
            x += velocity * CGFloat(dt)
        }
        for _ in 0..<steps {
            var x = f.origin.x, y = f.origin.y, w = f.size.width, h = f.size.height
            advance(&x, &v.x, t.origin.x); advance(&y, &v.y, t.origin.y)
            advance(&w, &v.w, t.size.width); advance(&h, &v.h, t.size.height)
            f = CGRect(x: x, y: y, width: max(1, w), height: max(1, h))
        }
        motion.velocity = v
        return f
    }

    private static func settled(_ motion: Motion) -> Bool {
        let f = motion.frame, t = motion.target, v = motion.velocity
        let near = abs(f.minX - t.minX) < 0.3 && abs(f.minY - t.minY) < 0.3
            && abs(f.width - t.width) < 0.3 && abs(f.height - t.height) < 0.3
        let still = abs(v.x) < 2 && abs(v.y) < 2 && abs(v.w) < 2 && abs(v.h) < 2
        return near && still
    }
}
