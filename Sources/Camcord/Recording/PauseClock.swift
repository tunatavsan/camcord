import CoreMedia

/// Shared timeline for video, system audio and microphone. The first video starts
/// the session. Explicit source-clock boundaries preserve active time while the screen
/// is static; every source then shares the same pause offset. The no-argument pause /
/// resume path retains lazy sample anchoring for callers that have no clock boundary.
struct PauseClock {
    private let frameDuration: CMTime
    private var sessionStarted = false
    private var isPaused = false
    private var needsReanchor = false
    private var offset: CMTime = .zero
    private var lastMediaEnd: CMTime = .invalid
    /// Retimed timeline position at an explicit pause command. Unlike lastMediaEnd,
    /// this advances through an active static interval even when SCK emitted no pixels.
    private var pauseBoundary: CMTime = .invalid
    /// A delayed callback captured before the new anchor may arrive afterwards. Drop
    /// it instead of appending behind the already committed, pre-pause media interval.
    private var resumeFloor: CMTime = .invalid
    /// Start/resume cues can complete before the writer has accepted its first video.
    /// In that case the resume boundary is still meaningful in the source timeline:
    /// callbacks captured during the cue but delivered late must not start the movie.
    private var sourceStartFloor: CMTime = .invalid

    init(frameDuration: CMTime) {
        self.frameDuration = frameDuration
    }

    mutating func pause() {
        guard !isPaused else { return }
        pauseBoundary = .invalid
        isPaused = true
    }

    mutating func pause(atSourceTime sourceTime: CMTime) {
        guard !isPaused else { return }
        if sessionStarted, sourceTime.isNumeric {
            let mapped = CMTimeSubtract(sourceTime, offset)
            pauseBoundary = maximum(lastMediaEnd, mapped)
            lastMediaEnd = pauseBoundary
        } else {
            pauseBoundary = .invalid
        }
        isPaused = true
    }

    mutating func resume() {
        guard isPaused else { return }
        isPaused = false
        needsReanchor = sessionStarted
    }

    mutating func resume(atSourceTime sourceTime: CMTime) {
        guard isPaused else { return }
        isPaused = false
        guard sourceTime.isNumeric else {
            needsReanchor = sessionStarted
            return
        }
        guard sessionStarted else {
            sourceStartFloor = sourceTime
            needsReanchor = false
            return
        }
        guard pauseBoundary.isValid else {
            needsReanchor = true
            return
        }
        offset = CMTimeSubtract(sourceTime, pauseBoundary)
        resumeFloor = pauseBoundary
        needsReanchor = false
    }

    /// Retimed writer-session boundary for a Stop command. Ending while paused holds
    /// at the pause boundary; ending while active includes static time up to sourceTime.
    func endTime(atSourceTime sourceTime: CMTime) -> CMTime? {
        guard sessionStarted, sourceTime.isNumeric else { return nil }
        if isPaused, pauseBoundary.isValid { return pauseBoundary }
        return maximum(lastMediaEnd, CMTimeSubtract(sourceTime, offset))
    }

    mutating func shouldAppend(pts: CMTime, isVideo: Bool, duration: CMTime = .invalid) -> CMTime? {
        guard !isPaused, pts.isNumeric else { return nil }
        // Keep this raw-source floor after the first video is accepted as well:
        // callbacks from the gated interval can arrive after that video and must
        // still be rejected from both audio tracks.
        if sourceStartFloor.isValid, pts < sourceStartFloor { return nil }
        if !sessionStarted {
            guard isVideo else { return nil }
            sessionStarted = true
            needsReanchor = false
            pauseBoundary = .invalid
        }
        if needsReanchor {
            offset = CMTimeSubtract(pts, lastMediaEnd)
            resumeFloor = lastMediaEnd
            needsReanchor = false
        }
        let retimed = CMTimeSubtract(pts, offset)
        if resumeFloor.isValid, retimed < resumeFloor { return nil }
        let span = duration.isNumeric && duration > .zero ? duration : (isVideo ? frameDuration : .zero)
        let end = CMTimeAdd(retimed, span)
        if !lastMediaEnd.isValid || end > lastMediaEnd { lastMediaEnd = end }
        return retimed
    }

    private func maximum(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        guard lhs.isValid else { return rhs }
        guard rhs.isValid else { return lhs }
        return CMTimeCompare(lhs, rhs) >= 0 ? lhs : rhs
    }
}
