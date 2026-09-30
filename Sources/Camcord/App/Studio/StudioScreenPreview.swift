import AVFoundation
import AppKit
import CoreImage
@preconcurrency import ScreenCaptureKit
import os

/// Retained immutable SCK sample. Mutating the native sample after publication is forbidden.
struct StudioSampleFrame: @unchecked Sendable {
    let sample: CMSampleBuffer
}

@MainActor
protocol StudioPreviewCapture: StudioPreviewResource {
    func start(target: RecordingEngine.Target, canvasSize: CGSize, capturesAudio: Bool) async throws
    func stop() async
    func latestFrame() -> StudioSampleFrame?
    func audioSnapshot() -> MicrophoneProbeSnapshot
    func updateGain(_ gainDB: Double)
}

/// One low-resolution, explicit-source idle stream. It has no writer, microphone,
/// camera, playback or file output. The recording engine remains the active owner.
@MainActor
final class StudioScreenPreview: StudioPreviewCapture {
    private var stream: SCStream?
    private let receiver = Receiver()

    static func configuration(canvasSize: CGSize, capturesAudio: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let longest = max(canvasSize.width, canvasSize.height)
        let scale = longest > 0 ? min(1, 960 / longest) : 1
        configuration.width = max(2, RegionClamp.evenFloor(canvasSize.width * scale))
        configuration.height = max(2, RegionClamp.evenFloor(canvasSize.height * scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 12)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = capturesAudio
        configuration.captureMicrophone = false
        configuration.excludesCurrentProcessAudio = true
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        return configuration
    }

    func start(target: RecordingEngine.Target, canvasSize: CGSize, capturesAudio: Bool) async throws {
        let configuration = Self.configuration(canvasSize: canvasSize, capturesAudio: capturesAudio)
        let filter: SCContentFilter
        switch target {
        case .window(let window): filter = SCContentFilter(desktopIndependentWindow: window)
        case .display(let display, _, let excluding):
            filter = SCContentFilter(display: display, excludingApplications: excluding.map { [$0] } ?? [], exceptingWindows: [])
        case .region(let clamp, let display, let excluding):
            filter = SCContentFilter(display: display, excludingApplications: excluding.map { [$0] } ?? [], exceptingWindows: [])
            configuration.sourceRect = clamp.sourceRect
        }
        receiver.clear()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
        self.stream = stream
        do {
            try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
            if capturesAudio { try stream.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: receiver.queue) }
            try await stream.startCapture()
        } catch {
            if self.stream === stream { self.stream = nil }
            try? await stream.stopCapture()
            throw error
        }
    }

    func stop() async {
        let old = stream
        stream = nil
        receiver.clear()
        if let old { try? await old.stopCapture() }
        // A retired receiver belongs to this preview identity, never a replacement.
        receiver.clear()
    }
    func latestFrame() -> StudioSampleFrame? { receiver.latestFrame() }
    func audioSnapshot() -> MicrophoneProbeSnapshot { receiver.audioSnapshot() }
    func updateGain(_ gainDB: Double) { receiver.updateGain(gainDB) }

    /// All processor mutation lives on its sample queue; only retained frame/meter
    /// snapshots cross through the lock. The relay is deliberately non-MainActor.
    private final class Receiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        let queue = DispatchQueue(label: "dev.tavsan.camcord.studio.preview.samples", qos: .userInitiated)
        private struct State { var frame: StudioSampleFrame?; var audio = MicrophoneProbeSnapshot() }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private var processor = AudioSampleProcessor()
        private var gainDB: Double = 0
        func clear() { state.withLock { $0 = State() } }
        func latestFrame() -> StudioSampleFrame? { state.withLock { $0.frame } }
        func audioSnapshot() -> MicrophoneProbeSnapshot { state.withLock { $0.audio } }
        func updateGain(_ gain: Double) { queue.async { self.gainDB = gain } }
        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard CMSampleBufferIsValid(sampleBuffer) else { return }
            if type == .screen {
                guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                        as? [[SCStreamFrameInfo: Any]],
                      let status = attachments.first?[.status] as? Int,
                      status == SCFrameStatus.complete.rawValue,
                      CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
                let frame = StudioSampleFrame(sample: sampleBuffer)
                state.withLock { $0.frame = frame }
            } else if type == .audio {
                do {
                    let output = try processor.process(sampleBuffer, gainDB: gainDB)
                    let levels = output.levels
                    state.withLock { $0.audio = MicrophoneProbeSnapshot(levels: levels) }
                } catch { state.withLock { $0.audio.failed = true } }
            }
        }
        func stream(_ stream: SCStream, didStopWithError error: Error) {
            state.withLock { $0.frame = nil; $0.audio.failed = true }
        }
    }
}

/// The same compositor used by StreamWriter, with a single owned serial render
/// context. AppKit image construction stays in StudioSession on the main actor.
final class StudioIdlePreviewRenderer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.tavsan.camcord.studio.preview.render", qos: .userInitiated)
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private lazy var compositor = CameraCompositor(context: context)

    func render(_ frame: StudioSampleFrame, camera: PixelBufferBox?, options: CameraOptions,
                layers: StudioLayerSnapshot, fitsWindow: Bool) async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    let fit = fitsWindow ? StreamWriter.canvasFit(of: frame.sample) : nil
                    let sample = try self.compositor.composite(screen: frame.sample, camera: camera?.value,
                                                               options: options, fit: fit, layers: layers)
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continuation.resume(returning: nil); return }
                    let image = CIImage(cvPixelBuffer: buffer)
                    continuation.resume(returning: self.context.createCGImage(image, from: image.extent))
                } catch { continuation.resume(returning: nil) }
            }
        }
    }
}
