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
        documents the chosen semantics: audio that arrives after resume() but before the next \
        video buffer is retimed with the OLD (pre-this-pause) offset, not dropped and not \
        re-anchored early -- only a video buffer can establish a new offset. In practice this \
        window is a handful of milliseconds (audio buffers are far more frequent than one video \
        frame), so the brief accepts this as a documented tradeoff rather than adding a second \
        state machine to hold audio back until the next video frame.
        """
    )
    func audioBeforeVideoAfterResumeUsesOldOffset() {
        var clock = PauseClock(frameDuration: Self.frameDuration)
        _ = clock.shouldAppend(pts: CMTime(value: 0, timescale: 60), isVideo: true)

        clock.pause()
        clock.resume()

        // Audio sneaks in before the resume-anchoring video buffer -- offset is still the old
        // (here: zero, no prior pause cycle) one.
        let earlyAudioPTS = CMTime(value: 250, timescale: 60)
        #expect(clock.shouldAppend(pts: earlyAudioPTS, isVideo: false) == earlyAudioPTS)

        // The next video buffer re-anchors and establishes the real offset going forward.
        let resumeVideoPTS = CMTime(value: 300, timescale: 60)
        #expect(clock.shouldAppend(pts: resumeVideoPTS, isVideo: true) == CMTime(value: 1, timescale: 60))

        let laterAudioPTS = CMTime(value: 301, timescale: 60)
        #expect(clock.shouldAppend(pts: laterAudioPTS, isVideo: false) == CMTime(value: 2, timescale: 60))
    }
}
