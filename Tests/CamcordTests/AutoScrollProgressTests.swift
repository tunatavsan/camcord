import Testing

@testable import Camcord

@Suite("AutoScrollProgress")
struct AutoScrollProgressTests {

    @Test("warm-up frames are progress, never stall")
    func warmupIsProgress() {
        var p = AutoScrollProgress(flipThreshold: 3, endThreshold: 3)
        for _ in 0..<10 {
            #expect(p.record(advanced: false, warmup: true) == .keepScrolling)
        }
    }

    @Test("advancing keeps scrolling and never ends")
    func advancingKeepsGoing() {
        var p = AutoScrollProgress(flipThreshold: 3, endThreshold: 3)
        for _ in 0..<10 {
            #expect(p.record(advanced: true, warmup: false) == .keepScrolling)
        }
    }

    @Test("a sustained stall AFTER advancing means the bottom was reached")
    func stallAfterAdvanceEnds() {
        var p = AutoScrollProgress(flipThreshold: 4, endThreshold: 3)
        #expect(p.record(advanced: true, warmup: false) == .keepScrolling)
        #expect(p.record(advanced: false, warmup: false) == .keepScrolling)   // 1
        #expect(p.record(advanced: false, warmup: false) == .keepScrolling)   // 2
        #expect(p.record(advanced: false, warmup: false) == .reachedEnd)      // 3
    }

    @Test("stalls reset once the page advances again")
    func stallResetsOnAdvance() {
        var p = AutoScrollProgress(flipThreshold: 4, endThreshold: 3)
        _ = p.record(advanced: true, warmup: false)
        #expect(p.record(advanced: false, warmup: false) == .keepScrolling)   // 1
        #expect(p.record(advanced: false, warmup: false) == .keepScrolling)   // 2
        #expect(p.record(advanced: true, warmup: false) == .keepScrolling)    // reset
        #expect(p.record(advanced: false, warmup: false) == .keepScrolling)   // 1 again
        #expect(p.record(advanced: false, warmup: false) == .keepScrolling)   // 2
        #expect(p.record(advanced: false, warmup: false) == .reachedEnd)      // 3
    }

    @Test("stalls BEFORE any advance flip the direction once")
    func stallBeforeAdvanceFlips() {
        var p = AutoScrollProgress(flipThreshold: 3, endThreshold: 4)
        #expect(p.record(advanced: false, warmup: false) == .keepScrolling)   // 1
        #expect(p.record(advanced: false, warmup: false) == .keepScrolling)   // 2
        #expect(p.record(advanced: false, warmup: false) == .flipDirection)   // 3 → flip
    }

    @Test("if both directions fail, give up (reachedEnd)")
    func bothDirectionsFailGiveUp() {
        var p = AutoScrollProgress(flipThreshold: 2, endThreshold: 4)
        #expect(p.record(advanced: false, warmup: false) == .keepScrolling)
        #expect(p.record(advanced: false, warmup: false) == .flipDirection)   // flip
        #expect(p.record(advanced: false, warmup: false) == .keepScrolling)   // streak resets after flip
        #expect(p.record(advanced: false, warmup: false) == .reachedEnd)      // still nothing → give up
    }

    @Test("a static baseline (warm-up frames) does not block the wrong-direction flip")
    func warmupBaselineThenStallsStillFlips() {
        // Mirrors the real sequence when auto picks the wrong direction: the stitcher buffers
        // and force-commits a baseline (all reported warmup:true), then every frame stalls —
        // the flip must still fire (advancedEver must NOT be set by the baseline).
        var p = AutoScrollProgress(flipThreshold: 3, endThreshold: 4)
        for _ in 0..<7 { #expect(p.record(advanced: false, warmup: true) == .keepScrolling) }
        #expect(p.record(advanced: false, warmup: false) == .keepScrolling)   // stall 1
        #expect(p.record(advanced: false, warmup: false) == .keepScrolling)   // stall 2
        #expect(p.record(advanced: false, warmup: false) == .flipDirection)   // stall 3 → flip
    }

    @Test("advancing after a flip switches to end-detection, not another flip")
    func advanceAfterFlip() {
        var p = AutoScrollProgress(flipThreshold: 2, endThreshold: 2)
        _ = p.record(advanced: false, warmup: false)
        #expect(p.record(advanced: false, warmup: false) == .flipDirection)
        #expect(p.record(advanced: true, warmup: false) == .keepScrolling)    // right way now
        #expect(p.record(advanced: false, warmup: false) == .keepScrolling)   // 1
        #expect(p.record(advanced: false, warmup: false) == .reachedEnd)      // 2 → end
    }
}
