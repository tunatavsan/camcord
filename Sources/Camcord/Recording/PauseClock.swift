import CoreMedia

/// Pure CMTime state machine implementing the recording pipeline's soft-pause.
///
/// While paused every buffer is dropped. On resume, the first video buffer re-anchors
/// the timeline: the accumulated offset is chosen so that buffer lands exactly one
/// frame duration after the last appended video frame, collapsing the pause gap.
/// The same offset is applied to every track (video is the clock master; audio that
/// sneaks in between `resume()` and the anchoring video buffer keeps the previous
/// offset -- a documented, milliseconds-wide tradeoff).
///
/// The session starts on the first video buffer; anything arriving before it is
/// dropped (`AVAssetWriter.startSession` must be anchored to video).
struct PauseClock {
    private let frameDuration: CMTime

    private var sessionStarted = false
    private var isPaused = false
    /// Set by `resume()`; the next video buffer recomputes the offset.
    private var needsReanchor = false
    /// Total source-clock time removed by pauses so far.
    private var offset: CMTime = .zero
    /// The PTS of the last appended video buffer, in *output* (retimed) time.
    private var lastAppendedVideoPTS: CMTime = .invalid

    init(frameDuration: CMTime) {
        self.frameDuration = frameDuration
    }

    mutating func pause() {
        isPaused = true
    }

    mutating func resume() {
        isPaused = false
        needsReanchor = true
    }

    /// Returns the retimed PTS the buffer should be appended with, or nil to drop it.
    mutating func shouldAppend(pts: CMTime, isVideo: Bool) -> CMTime? {
        if isPaused { return nil }

        if !sessionStarted {
            guard isVideo else { return nil }
            sessionStarted = true
            lastAppendedVideoPTS = pts
            return pts
        }

        if isVideo {
            if needsReanchor {
                // Land this buffer exactly one frame after the last appended one.
                let target = CMTimeAdd(lastAppendedVideoPTS, frameDuration)
                offset = CMTimeSubtract(pts, target)
                needsReanchor = false
            }
            let retimed = CMTimeSubtract(pts, offset)
            lastAppendedVideoPTS = retimed
            return retimed
        }

        return CMTimeSubtract(pts, offset)
    }
}
