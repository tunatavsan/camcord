import Foundation
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

    @Test("two no-motion frames after advancing mean the bottom was reached")
    func stallAfterAdvanceEnds() {
        var p = AutoScrollProgress()
        #expect(p.record(.down(20, score: 0)) == .keepScrolling)
        #expect(p.record(.down(20, score: 0)) == .keepScrolling)
        #expect(p.record(.none) == .keepScrolling)
        #expect(p.record(.none) == .reachedEnd)
    }

    @Test("no-motion streak resets once the page advances again")
    func stallResetsOnAdvance() {
        var p = AutoScrollProgress()
        _ = p.record(.down(20, score: 0))
        #expect(p.record(.none) == .keepScrolling)
        #expect(p.record(.down(20, score: 0)) == .keepScrolling)
        #expect(p.record(.none) == .keepScrolling)
        #expect(p.record(.none) == .reachedEnd)
    }

    @Test("a spring-back after the run advanced is the page end, not a wrong direction")
    func springBackAfterAdvanceEnds() {
        var p = AutoScrollProgress()
        #expect(p.record(.down(20, score: 0)) == .keepScrolling)
        #expect(p.record(.up(12)) == .reachedEnd)
    }

    @Test("two no-motion frames before any advance flip the direction")
    func stallBeforeAdvanceFlips() {
        var p = AutoScrollProgress()
        #expect(p.record(.none) == .keepScrolling)
        #expect(p.record(.none) == .flipDirection)
    }

    @Test("if both directions remain still, give up")
    func bothDirectionsFailGiveUp() {
        var p = AutoScrollProgress()
        #expect(p.record(.none) == .keepScrolling)
        #expect(p.record(.none) == .flipDirection)
        #expect(p.record(.none) == .keepScrolling)
        #expect(p.record(.none) == .reachedEnd)
    }

    @Test("upward motion before any advance flips once, then ends")
    func advanceAfterFlip() {
        var p = AutoScrollProgress()
        #expect(p.record(.up(20)) == .flipDirection)
        #expect(p.record(.up(20)) == .reachedEnd)
    }
}

@Suite("AutoScroller direction", .serialized)
struct AutoScrollerDirectionTests {

    @Test("a proven direction is written once per sign and re-armed by a flip")
    @MainActor func directionPersistsOncePerSign() {
        let defaults = UserDefaults.standard
        let key = AutoScroller.directionDefaultsKey
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        let scroller = AutoScroller()
        scroller.confirmDirection()
        let first = defaults.integer(forKey: key)
        #expect(first != 0)

        // Every stitched frame confirms; the identical value must not be rewritten.
        defaults.removeObject(forKey: key)
        scroller.confirmDirection()
        #expect(defaults.object(forKey: key) == nil)

        scroller.flipDirection()
        scroller.confirmDirection()
        #expect(defaults.integer(forKey: key) == -first)
    }
}
