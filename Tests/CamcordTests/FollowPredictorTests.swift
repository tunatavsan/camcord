import CoreGraphics
import Testing

@testable import Camcord

@Suite("FollowPredictor")
struct FollowPredictorTests {

    @Test("the first sample has no velocity, so it's returned unchanged")
    func firstSampleUnchanged() {
        var p = FollowPredictor()
        let out = p.predict(origin: CGPoint(x: 100, y: 200))
        #expect(out == CGPoint(x: 100, y: 200))
    }

    @Test("under constant velocity it leads by ~leadFrames × velocity, cancelling follow lag")
    func steadyVelocityLeads() {
        let lead: CGFloat = 1.35
        var p = FollowPredictor(leadFrames: lead, smoothing: 0.65)
        let v: CGFloat = 10   // 10 pt/frame to the right
        var x: CGFloat = 0
        var out = CGPoint.zero
        // Feed many frames so the velocity EMA converges to v.
        for _ in 0..<40 {
            out = p.predict(origin: CGPoint(x: x, y: 0))
            x += v
        }
        // The prediction should sit ~lead frames ahead of the last raw x (x - v is the last
        // origin fed, since x was advanced after the call).
        let lastFedX = x - v
        #expect(abs((out.x - lastFedX) - v * lead) < 0.5)
        #expect(abs(out.y) < 0.001)
    }

    @Test("velocity decays to ~0 at a standstill, so there's no lingering overshoot")
    func standstillConverges() {
        var p = FollowPredictor(leadFrames: 1.35, smoothing: 0.65)
        for _ in 0..<20 { _ = p.predict(origin: CGPoint(x: 500, y: 500)) }
        let out = p.predict(origin: CGPoint(x: 500, y: 500))
        #expect(abs(out.x - 500) < 0.01)
        #expect(abs(out.y - 500) < 0.01)
    }

    @Test("a huge jump in the read is clamped so the border can't be flung far")
    func clampsHugeJump() {
        var p = FollowPredictor(leadFrames: 1, maxLead: 100, smoothing: 1)
        _ = p.predict(origin: .zero)
        let out = p.predict(origin: CGPoint(x: 100_000, y: 0))
        // velocity = 100000 (smoothing 1), lead 1 → clamped to +100.
        #expect(out.x == 100_100)
    }

    @Test("reset clears velocity so the next sample starts fresh")
    func resetClears() {
        var p = FollowPredictor(leadFrames: 1.35, smoothing: 0.65)
        for i in 0..<10 { _ = p.predict(origin: CGPoint(x: CGFloat(i) * 12, y: 0)) }
        p.reset()
        let out = p.predict(origin: CGPoint(x: 999, y: 0))
        #expect(out == CGPoint(x: 999, y: 0))
    }
}
