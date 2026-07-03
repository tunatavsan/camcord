import CoreMedia
import Testing

@testable import Camcord

@Suite("PauseClock")
struct PauseClockTests {
    private static let frameDuration = CMTime(value: 1, timescale: 60)

    // MARK: - Session start

    @Test("session starts on the first video buffer; audio arriving before it is dropped")
    func sessionStartsOnFirstVideoBuffer() {
        var clock = PauseClock(frameDuration: Self.frameDuration)

        let audioBeforeVideo = CMTime(value: 5, timescale: 60)
        #expect(clock.shouldAppend(pts: audioBeforeVideo, isVideo: false) == nil)

        let firstVideoPTS = CMTime(value: 0, timescale: 60)
        #expect(clock.shouldAppend(pts: firstVideoPTS, isVideo: true) == firstVideoPTS)
    }

    // MARK: - No-pause identity

    @Test("passes PTS through unchanged when no pause has occurred")
    func identityPassthroughWithoutPause() {
        var clock = PauseClock(frameDuration: Self.frameDuration)
        _ = clock.shouldAppend(pts: CMTime(value: 0, timescale: 60), isVideo: true)

        let v1 = CMTime(value: 1, timescale: 60)
        #expect(clock.shouldAppend(pts: v1, isVideo: true) == v1)

        let a1 = CMTime(value: 1, timescale: 60)
        #expect(clock.shouldAppend(pts: a1, isVideo: false) == a1)
    }

    // MARK: - Pause drops everything

    @Test("every buffer -- video or audio -- is dropped while paused")
    func buffersDroppedWhilePaused() {
        var clock = PauseClock(frameDuration: Self.frameDuration)
        _ = clock.shouldAppend(pts: CMTime(value: 0, timescale: 60), isVideo: true)

        clock.pause()

        #expect(clock.shouldAppend(pts: CMTime(value: 1, timescale: 60), isVideo: true) == nil)
        #expect(clock.shouldAppend(pts: CMTime(value: 1, timescale: 60), isVideo: false) == nil)
        #expect(clock.shouldAppend(pts: CMTime(value: 50, timescale: 60), isVideo: true) == nil)
    }

    // MARK: - Single pause/resume

    @Test("a single pause/resume collapses the gap to exactly one frame duration; audio shares the offset")
    func singlePauseResumeCollapsesGap() {
        var clock = PauseClock(frameDuration: Self.frameDuration)
        _ = clock.shouldAppend(pts: CMTime(value: 0, timescale: 60), isVideo: true)

        clock.pause()
        // Dropped -- arrives while paused.
        #expect(clock.shouldAppend(pts: CMTime(value: 10, timescale: 60), isVideo: true) == nil)
        clock.resume()

        // The real pause lasted a long time on the source clock (300 frames' worth).
        let resumeVideoPTS = CMTime(value: 300, timescale: 60)
        let retimedVideo = clock.shouldAppend(pts: resumeVideoPTS, isVideo: true)
        // Continuity: retimed PTS must land exactly one frame after the last appended one.
        #expect(retimedVideo == CMTime(value: 1, timescale: 60))

        let nextAudioPTS = CMTime(value: 301, timescale: 60)
        let retimedAudio = clock.shouldAppend(pts: nextAudioPTS, isVideo: false)
        // Same (newly established) offset of 299/60 applied to audio too.
        #expect(retimedAudio == CMTime(value: 2, timescale: 60))

        let nextVideoPTS = CMTime(value: 301, timescale: 60)
        let retimedVideo2 = clock.shouldAppend(pts: nextVideoPTS, isVideo: true)
        #expect(retimedVideo2 == CMTime(value: 2, timescale: 60))
    }

    // MARK: - Multiple pause/resume cycles

    @Test("two pause/resume cycles accumulate their offsets")
    func twoPauseCyclesAccumulateOffsets() {
        var clock = PauseClock(frameDuration: Self.frameDuration)
        _ = clock.shouldAppend(pts: CMTime(value: 0, timescale: 60), isVideo: true)

        clock.pause()
        clock.resume()
        let firstResumeVideo = CMTime(value: 100, timescale: 60)
        #expect(clock.shouldAppend(pts: firstResumeVideo, isVideo: true) == CMTime(value: 1, timescale: 60))

        let steadyVideo = CMTime(value: 101, timescale: 60)
        #expect(clock.shouldAppend(pts: steadyVideo, isVideo: true) == CMTime(value: 2, timescale: 60))

        clock.pause()
        clock.resume()
        let secondResumeVideo = CMTime(value: 500, timescale: 60)
        // lastAppendedVideoPTS is 2/60 going into this second gap.
        #expect(clock.shouldAppend(pts: secondResumeVideo, isVideo: true) == CMTime(value: 3, timescale: 60))

        let steadyVideo2 = CMTime(value: 501, timescale: 60)
        #expect(clock.shouldAppend(pts: steadyVideo2, isVideo: true) == CMTime(value: 4, timescale: 60))
    }

    // MARK: - Audio arriving before the resume-anchoring video buffer

    @Test(
        """
        audio that arrives after resume() but before the re-anchoring video buffer is DROPPED. \
        Retiming it with the stale pre-pause offset would append a PTS a full pause-length in \
        the future, and the next (re-anchored) audio buffer would then move BACKWARD on the \
        same writer input -- audio inputs require monotonically increasing PTS, so that one \
        stray buffer could fail the entire AVAssetWriter. Dropping bounds the loss to <1 frame.
        """
    )
    func audioBeforeVideoAfterResumeIsDropped() {
        var clock = PauseClock(frameDuration: Self.frameDuration)
        _ = clock.shouldAppend(pts: CMTime(value: 0, timescale: 60), isVideo: true)

        clock.pause()
        clock.resume()

        // Audio sneaks in before the resume-anchoring video buffer: dropped.
        let earlyAudioPTS = CMTime(value: 250, timescale: 60)
        #expect(clock.shouldAppend(pts: earlyAudioPTS, isVideo: false) == nil)

        // The next video buffer re-anchors and establishes the real offset going forward.
        let resumeVideoPTS = CMTime(value: 300, timescale: 60)
        #expect(clock.shouldAppend(pts: resumeVideoPTS, isVideo: true) == CMTime(value: 1, timescale: 60))

        // Post-anchor audio is retimed with the fresh offset -- monotonic with the
        // video timeline, never behind a previously appended audio PTS.
        let laterAudioPTS = CMTime(value: 301, timescale: 60)
        #expect(clock.shouldAppend(pts: laterAudioPTS, isVideo: false) == CMTime(value: 2, timescale: 60))
    }

    // MARK: - Pause/resume completing before the session starts

    @Test(
        """
        a pause/resume cycle that completes BEFORE the first video buffer must not leave a \
        re-anchor pending: the first video buffer is the anchor (offset zero), so the second \
        frame passes through unchanged instead of recomputing an offset against a gap that \
        never existed.
        """
    )
    func pauseResumeBeforeFirstVideoLeavesNoPendingReanchor() {
        var clock = PauseClock(frameDuration: Self.frameDuration)

        clock.pause()
        clock.resume()

        // First video buffer starts the session at its raw PTS.
        let v0 = CMTime(value: 100, timescale: 60)
        #expect(clock.shouldAppend(pts: v0, isVideo: true) == v0)

        // Audio right after must NOT be dropped (needsReanchor must be clear) and
        // must pass through with offset zero.
        let a0 = CMTime(value: 101, timescale: 60)
        #expect(clock.shouldAppend(pts: a0, isVideo: false) == a0)

        // Second video frame passes through unchanged — no spurious re-anchor.
        let v1 = CMTime(value: 110, timescale: 60)
        #expect(clock.shouldAppend(pts: v1, isVideo: true) == v1)
    }

    @Test("retiming stays consistent across realistic mixed timescales (host-time video, 48kHz audio)")
    func mixedTimescaleRetiming() {
        // Video PTS on a nanosecond-style host clock, audio on a 48kHz clock,
        // frameDuration 1/60 -- exactly what SCStream actually delivers.
        var clock = PauseClock(frameDuration: CMTime(value: 1, timescale: 60))

        let v0 = CMTime(value: 1_000_000_000, timescale: 1_000_000_000)  // t = 1.0s
        #expect(clock.shouldAppend(pts: v0, isVideo: true) == v0)

        clock.pause()
        clock.resume()

        // Re-anchor 5s later: retimed video must land exactly 1/60 after v0.
        let v1 = CMTime(value: 6_000_000_000, timescale: 1_000_000_000)  // t = 6.0s
        let retimedV1 = clock.shouldAppend(pts: v1, isVideo: true)
        let expectedV1 = CMTimeAdd(v0, CMTime(value: 1, timescale: 60))
        #expect(retimedV1 != nil && CMTimeCompare(retimedV1!, expectedV1) == 0)

        // 48kHz audio right after: shifted by the same ~4.983s offset, staying just
        // ahead of the retimed video -- and monotonic.
        let a1 = CMTime(value: 48_000 * 6 + 480, timescale: 48_000)  // t = 6.01s
        let retimedA1 = clock.shouldAppend(pts: a1, isVideo: false)
        #expect(retimedA1 != nil)
        #expect(CMTimeCompare(retimedA1!, retimedV1!) > 0)
        let expectedA1 = CMTimeSubtract(a1, CMTimeSubtract(v1, expectedV1))
        #expect(CMTimeCompare(retimedA1!, expectedA1) == 0)
    }
}
