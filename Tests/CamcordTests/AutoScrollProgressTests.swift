import Testing

@testable import Camcord

@Suite("AutoScrollProgress")
struct AutoScrollProgressTests {

    @Test("warm-up frames within the grace window are progress, not stalls")
    func warmupWithinGraceIsProgress() {
        var p = AutoScrollProgress(flipThreshold: 3, endThreshold: 3, warmupGrace: 3)
        // Grace-many warm-up frames followed by a commit never flip — the normal start of a
        // correct scroll (the stitcher buffers a couple of frames, then commits).
        #expect(p.record(advanced: false, warmup: true) == .keepScrolling)
        #expect(p.record(advanced: false, warmup: true) == .keepScrolling)
        #expect(p.record(advanced: false, warmup: true) == .keepScrolling)
        #expect(p.record(advanced: true, warmup: false) == .keepScrolling)
    }

    @Test("warm-up beyond the grace window still drives the wrong-direction flip")
    func warmupBeyondGraceFlips() {
        // A wrong direction looks like an endless warm-up (nothing ever moves). Past the
        // grace, warm-up frames must count as stalls so the flip fires promptly instead of
        // hiding behind the stitcher's full buffer.
        var p = AutoScrollProgress(flipThreshold: 3, endThreshold: 4, warmupGrace: 2)
        #expect(p.record(advanced: false, warmup: true) == .keepScrolling)   // grace 1
        #expect(p.record(advanced: false, warmup: true) == .keepScrolling)   // grace 2
        #expect(p.record(advanced: false, warmup: true) == .keepScrolling)   // stall 1
        #expect(p.record(advanced: false, warmup: true) == .keepScrolling)   // stall 2
        #expect(p.record(advanced: false, warmup: true) == .flipDirection)   // stall 3 → flip
    }

    @Test("a corrected direction gets a fresh warm-up grace after a flip")
    func freshGraceAfterFlip() {
        var p = AutoScrollProgress(flipThreshold: 3, endThreshold: 4, warmupGrace: 2)
        // Drive the wrong-direction flip (2 grace + 3 stalls).
        for _ in 0..<4 { #expect(p.record(advanced: false, warmup: true) == .keepScrolling) }
        #expect(p.record(advanced: false, warmup: true) == .flipDirection)
        // The corrected direction buffers a couple of frames of its own before committing —
        // that must NOT be mistaken for "both directions failed" and end the scroll.
        #expect(p.record(advanced: false, warmup: true) == .keepScrolling)
        #expect(p.record(advanced: false, warmup: true) == .keepScrolling)
        #expect(p.record(advanced: true, warmup: false) == .keepScrolling)
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
