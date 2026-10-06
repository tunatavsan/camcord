import Testing

@testable import Camcord

/// Pure state-machine tests for the double-tap Right-⌘ gesture detector. No CGEventTap/AX
/// calls here -- the detector takes synthetic timestamps.
@Suite("DoubleTapDetector")
struct DoubleTapDetectorTests {

    @Test("completes a double-tap when the second press starts within 350ms of the first")
    func completesWithinInterval() {
        var detector = DoubleTapDetector()
        #expect(detector.handle(event: .rightCmdDown, at: 0.0) == false)
        #expect(detector.handle(event: .rightCmdUp, at: 0.05) == false)
        #expect(detector.handle(event: .rightCmdDown, at: 0.30) == false)
        #expect(detector.handle(event: .rightCmdUp, at: 0.35) == true)
    }

    @Test("a second press at EXACTLY 350ms still completes (the advertised window is inclusive)")
    func completesAtExactBoundary() {
        var detector = DoubleTapDetector()
        #expect(detector.handle(event: .rightCmdDown, at: 0.0) == false)
        #expect(detector.handle(event: .rightCmdUp, at: 0.05) == false)
        // Press-to-press gap == maxInterval (0.35): the `<=` boundary case.
        #expect(detector.handle(event: .rightCmdDown, at: 0.35) == false)
        #expect(detector.handle(event: .rightCmdUp, at: 0.40) == true)
    }

    @Test("does not complete when the second press starts after the 350ms window")
    func rejectsBeyondInterval() {
        var detector = DoubleTapDetector()
        #expect(detector.handle(event: .rightCmdDown, at: 0.0) == false)
        #expect(detector.handle(event: .rightCmdUp, at: 0.05) == false)
        #expect(detector.handle(event: .rightCmdDown, at: 0.40) == false)
        #expect(detector.handle(event: .rightCmdUp, at: 0.45) == false)
    }

    @Test("resets when another key fires between the two taps")
    func resetsOnKeyBetweenTaps() {
        var detector = DoubleTapDetector()
        #expect(detector.handle(event: .rightCmdDown, at: 0.0) == false)
        #expect(detector.handle(event: .rightCmdUp, at: 0.05) == false)
        #expect(detector.handle(event: .otherKeyDown, at: 0.10) == false)
        #expect(detector.handle(event: .rightCmdDown, at: 0.15) == false)
        #expect(detector.handle(event: .rightCmdUp, at: 0.20) == false)
    }

    @Test("two Cmd+C chords in a row do not falsely trigger a double-tap")
    func cmdCTwiceDoesNotTrigger() {
        var detector = DoubleTapDetector()
        // First Cmd+C: right-cmd down, C down while held, right-cmd up.
        #expect(detector.handle(event: .rightCmdDown, at: 0.0) == false)
        #expect(detector.handle(event: .otherKeyDown, at: 0.01) == false)
        #expect(detector.handle(event: .rightCmdUp, at: 0.05) == false)
        // Second Cmd+C, well within the double-tap window.
        #expect(detector.handle(event: .rightCmdDown, at: 0.10) == false)
        #expect(detector.handle(event: .otherKeyDown, at: 0.11) == false)
        #expect(detector.handle(event: .rightCmdUp, at: 0.15) == false)
    }

    @Test("a second press without an intervening release does not complete a double-tap")
    func requiresReleaseBetweenPresses() {
        var detector = DoubleTapDetector()
        #expect(detector.handle(event: .rightCmdDown, at: 0.0) == false)
        // Key-repeat style extra down with no release yet -- still a single press.
        #expect(detector.handle(event: .rightCmdDown, at: 0.05) == false)
        #expect(detector.handle(event: .rightCmdUp, at: 0.10) == false)
    }

    @Test("after a completed double-tap, a third tap starts a fresh sequence")
    func thirdTapStartsFreshSequence() {
        var detector = DoubleTapDetector()
        #expect(detector.handle(event: .rightCmdDown, at: 0.0) == false)
        #expect(detector.handle(event: .rightCmdUp, at: 0.05) == false)
        #expect(detector.handle(event: .rightCmdDown, at: 0.10) == false)
        #expect(detector.handle(event: .rightCmdUp, at: 0.15) == true)

        // A lone third tap must not immediately re-trigger.
        #expect(detector.handle(event: .rightCmdDown, at: 0.20) == false)
        #expect(detector.handle(event: .rightCmdUp, at: 0.25) == false)
    }
}
