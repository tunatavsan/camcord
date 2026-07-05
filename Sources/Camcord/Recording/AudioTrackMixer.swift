import AVFoundation
import os

/// Collapses a finished recording that has MORE THAN ONE audio track into an equivalent
/// file with **one** audio track — the source's audio tracks mixed (summed) together —
/// and the video passed through byte-for-byte.
///
/// Why this exists: a movie with two separate audio tracks (system audio + microphone)
/// plays only the FIRST track in most players and platforms (QuickTime's Quick Look,
/// Slack, browsers, Finder preview), so the microphone is silently inaudible even though
/// it was recorded perfectly. Mixing to a single track guarantees the mic is heard
/// everywhere. A power user who wants the tracks separate (for editing) turns
/// `RecordingSettings.mixAudioTracks` off.
///
/// The mixing is done by Apple's `AVAssetReaderAudioMixOutput` (sample-accurate, resamples
/// and sums at unity gain) — we never hand-roll DSP. The video track is copied with
/// `outputSettings: nil` (passthrough): no re-encode, no quality loss, so the cost is a
/// single audio re-encode + an I/O copy of the (already-compressed) video, done during the
/// existing "finishing…" phase.
enum AudioTrackMixer {
    private static let logger = Logger(subsystem: "dev.tavsan.camcord", category: "audio-mixer")

    enum MixError: Error {
        /// Fewer than two audio tracks — nothing to mix (caller keeps the original file).
        case notNeeded
        case readerSetupFailed(Error?)
        case writerSetupFailed(Error?)
        case pumpFailed(Error?)
    }

    /// Mixes `url` in place: writes a mixed copy alongside it, then atomically replaces the
    /// original. On any failure the original (multi-track) file is left untouched — a
    /// recording is never lost to a mix that didn't work. Throws `MixError.notNeeded` when
    /// the file has fewer than two audio tracks.
    static func mixInPlace(url: URL, fileType: AVFileType) async throws {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count >= 2 else { throw MixError.notNeeded }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoFormat = try await videoTracks.first?.load(.formatDescriptions).first

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".camcord-mix-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)

        let session = MixSession(
            asset: asset,
            videoTrack: videoTracks.first,
            videoFormat: videoFormat,
            audioTracks: audioTracks,
            destination: temp,
            fileType: fileType
        )
        do {
            try await session.run()
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            // The swap failed (permissions / volume) — drop the temp, keep the original.
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        logger.notice("Mixed \(audioTracks.count) audio tracks into one for \(url.lastPathComponent, privacy: .public)")
    }
}

/// Owns the reader/writer for one mix pass. A class (not free functions) so the
/// non-`Sendable` AVFoundation objects captured by `requestMediaDataWhenReady`'s
/// `@Sendable` callbacks live behind a single `@unchecked Sendable` boundary — the same
/// pattern `StreamWriter` uses. All pumping happens on one serial queue, so the shared
/// mutable state below is single-threaded.
private final class MixSession: @unchecked Sendable {
    private let asset: AVURLAsset
    private let videoTrack: AVAssetTrack?
    private let videoFormat: CMFormatDescription?
    private let audioTracks: [AVAssetTrack]
    private let destination: URL
    private let fileType: AVFileType

    private let queue = DispatchQueue(label: "dev.tavsan.camcord.audio-mixer")
    private let group = DispatchGroup()

    /// One reader-output → writer-input pipe. Stored on the class so the `@Sendable`
    /// `requestMediaDataWhenReady` callbacks capture only `self` (Sendable) + an Int
    /// index, never the non-Sendable AVFoundation objects directly.
    private final class Pipe {
        let input: AVAssetWriterInput
        let output: AVAssetReaderOutput
        var finished = false
        init(input: AVAssetWriterInput, output: AVAssetReaderOutput) {
            self.input = input
            self.output = output
        }
    }

    // All of the below are touched ONLY on `queue` (a serial queue), so the
    // `@unchecked Sendable` contract holds without locks.
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var pipes: [Pipe] = []
    private var firstError: Error?

    init(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack?,
        videoFormat: CMFormatDescription?,
        audioTracks: [AVAssetTrack],
        destination: URL,
        fileType: AVFileType
    ) {
        self.asset = asset
        self.videoTrack = videoTrack
        self.videoFormat = videoFormat
        self.audioTracks = audioTracks
        self.destination = destination
        self.fileType = fileType
    }

    func run() async throws {
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        self.reader = reader
        self.writer = writer

        // --- Audio: all source tracks mixed down to one PCM stream, re-encoded to AAC ---
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcmSettings)
        mixOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(mixOutput) else { throw AudioTrackMixer.MixError.readerSetupFailed(nil) }
        reader.add(mixOutput)

        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else { throw AudioTrackMixer.MixError.writerSetupFailed(nil) }
        writer.add(audioInput)
        pipes.append(Pipe(input: audioInput, output: mixOutput))

        // --- Video: passthrough (outputSettings nil = no re-encode) ---
        if let videoTrack {
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw AudioTrackMixer.MixError.readerSetupFailed(nil) }
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw AudioTrackMixer.MixError.writerSetupFailed(nil) }
            writer.add(input)
            pipes.append(Pipe(input: input, output: output))
        }

        guard reader.startReading() else { throw AudioTrackMixer.MixError.readerSetupFailed(reader.error) }
        guard writer.startWriting() else { throw AudioTrackMixer.MixError.writerSetupFailed(writer.error) }
        writer.startSession(atSourceTime: .zero)

        // `continuation` is Sendable, so capturing it directly is fine; every non-Sendable
        // AVFoundation object is reached through `self` (the @unchecked Sendable class).
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            for index in pipes.indices {
                pump(pipeIndex: index)
            }
            group.notify(queue: queue) { [self] in
                if self.reader?.status == .failed {
                    continuation.resume(throwing: AudioTrackMixer.MixError.pumpFailed(self.reader?.error))
                    return
                }
                if let firstError = self.firstError {
                    continuation.resume(throwing: firstError)
                    return
                }
                guard let writer = self.writer else {
                    continuation.resume(throwing: AudioTrackMixer.MixError.writerSetupFailed(nil))
                    return
                }
                writer.finishWriting { [self] in
                    if self.writer?.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: AudioTrackMixer.MixError.pumpFailed(self.writer?.error))
                    }
                }
            }
        }
    }

    /// Drains one pipe on `queue`. Captures only `self` + `index` (both Sendable), keeping
    /// every non-Sendable AVFoundation object behind the class's `@unchecked Sendable`
    /// boundary and reached through `self.pipes[index]`.
    private func pump(pipeIndex index: Int) {
        group.enter()
        pipes[index].input.requestMediaDataWhenReady(on: queue) { [self] in
            let pipe = self.pipes[index]
            while pipe.input.isReadyForMoreMediaData {
                if pipe.finished { return }
                if self.firstError != nil {
                    self.finish(pipe)
                    return
                }
                guard let sample = pipe.output.copyNextSampleBuffer() else {
                    // Drained cleanly (a reader failure is caught in the group's notify).
                    self.finish(pipe)
                    return
                }
                if !pipe.input.append(sample) {
                    self.firstError = self.writer?.error ?? AudioTrackMixer.MixError.pumpFailed(nil)
                    self.finish(pipe)
                    return
                }
            }
        }
    }

    private func finish(_ pipe: Pipe) {
        guard !pipe.finished else { return }
        pipe.finished = true
        pipe.input.markAsFinished()
        group.leave()
    }
}
