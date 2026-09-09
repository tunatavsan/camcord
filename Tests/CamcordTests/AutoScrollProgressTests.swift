import Testing

@testable import Camcord

@Suite("AutoScrollProgress")
struct AutoScrollProgressTests {

    @Test("advancing keeps scrolling and never ends")
    func advancingKeepsGoing() {
        var p = AutoScrollProgress()
        for _ in 0..<10 {
            #expect(p.record(.down(20, score: 0)) == .keepScrolling)
        }
    }

    @Test("three no-motion frames after advancing mean the bottom was reached")
    func stallAfterAdvanceEnds() {
        var p = AutoScrollProgress()
        #expect(p.record(.down(20, score: 0)) == .keepScrolling)
        #expect(p.record(.down(20, score: 0)) == .keepScrolling)
        #expect(p.record(.none) == .keepScrolling)
        #expect(p.record(.none) == .keepScrolling)
        #expect(p.record(.none) == .reachedEnd)
    }

    @Test("no-motion streak resets once the page advances again")
    func stallResetsOnAdvance() {
        var p = AutoScrollProgress()
        _ = p.record(.down(20, score: 0))
        #expect(p.record(.none) == .keepScrolling)
        #expect(p.record(.none) == .keepScrolling)
        #expect(p.record(.down(20, score: 0)) == .keepScrolling)
        #expect(p.record(.none) == .keepScrolling)
        #expect(p.record(.none) == .keepScrolling)
        #expect(p.record(.none) == .reachedEnd)
    }

    @Test("three no-motion frames before any advance flip the direction")
    func stallBeforeAdvanceFlips() {
        var p = AutoScrollProgress()
        #expect(p.record(.none) == .keepScrolling)
        #expect(p.record(.none) == .keepScrolling)
        #expect(p.record(.none) == .flipDirection)
    }

    @Test("if both directions remain still, give up")
    func bothDirectionsFailGiveUp() {
        var p = AutoScrollProgress()
        for _ in 0..<2 { #expect(p.record(.none) == .keepScrolling) }
        #expect(p.record(.none) == .flipDirection)
        for _ in 0..<2 { #expect(p.record(.none) == .keepScrolling) }
        #expect(p.record(.none) == .reachedEnd)
    }

    @Test("upward motion flips once, then ends")
    func advanceAfterFlip() {
        var p = AutoScrollProgress()
        #expect(p.record(.up(20)) == .flipDirection)
        #expect(p.record(.up(20)) == .reachedEnd)
    }
}
