import AVFoundation
import AppKit
import CoreImage
@preconcurrency import ScreenCaptureKit
import os

/// Retained immutable SCK sample. Mutating the native sample after publication is forbidden.
struct StudioSampleFrame: @unchecked Sendable {
    let sample: CMSampleBuffer
    let sequence: UInt64
    let epoch: UUID?
    init(sample: CMSampleBuffer, sequence: UInt64 = 0, epoch: UUID? = nil) {
        self.sample = sample; self.sequence = sequence; self.epoch = epoch
    }
}

@MainActor
protocol StudioPreviewCapture: StudioPreviewResource {
    func start(target: RecordingEngine.Target, canvasSize: CGSize, capturesAudio: Bool) async throws
    func stop() async
    func latestFrame() -> StudioSampleFrame?
    func audioSnapshot() -> MicrophoneProbeSnapshot
    func updateGain(_ gainDB: Double)
    func configure(viewport: StudioPreviewViewport, frameSink: @escaping @Sendable (StudioSampleFrame) -> Void)
    func updateViewport(_ viewport: StudioPreviewViewport) async throws
}

/// One viewport-resolution, explicit-source idle stream. It has no writer, microphone,
/// camera, playback or file output. The recording engine remains the active owner.
@MainActor
final class StudioScreenPreview: StudioPreviewCapture {
    private var stream: SCStream?
    private let receiver = Receiver()
    private var viewport: StudioPreviewViewport?
    private var sourceRect: CGRect?
    private var capturesAudio = false

    static func configuration(canvasSize: CGSize, capturesAudio: Bool,
                              viewport: StudioPreviewViewport? = nil) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let viewport = viewport ?? StudioPreviewViewport(pixelSize: canvasSize, refreshRate: 60)
        configuration.width = Int(viewport.pixelSize.width)
        configuration.height = Int(viewport.pixelSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(viewport.refreshRate))
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
        self.capturesAudio = capturesAudio
        sourceRect = nil
        let configuration = Self.configuration(canvasSize: canvasSize, capturesAudio: capturesAudio, viewport: viewport)
        let filter: SCContentFilter
        switch target {
        case .window(let window): filter = SCContentFilter(desktopIndependentWindow: window)
        case .display(let display, _, let excluding):
            filter = SCContentFilter(display: display, excludingApplications: excluding.map { [$0] } ?? [], exceptingWindows: [])
        case .region(let clamp, let display, let excluding):
            filter = SCContentFilter(display: display, excludingApplications: excluding.map { [$0] } ?? [], exceptingWindows: [])
            configuration.sourceRect = clamp.sourceRect
            sourceRect = clamp.sourceRect
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
        self.stream = stream
        receiver.begin(stream: stream)
        do {
            try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
            if capturesAudio { try stream.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: receiver.queue) }
            try await stream.startCapture()
        } catch {
            if self.stream === stream { self.stream = nil }
            receiver.end(stream: stream)
            try? await stream.stopCapture()
            throw error
        }
    }

    func stop() async {
        let old = stream
        stream = nil
        if let old { receiver.end(stream: old) }
        if let old { try? await old.stopCapture() }
        // A retired receiver belongs to this preview identity, never a replacement.
        if let old { receiver.end(stream: old) }
    }
    func latestFrame() -> StudioSampleFrame? { receiver.latestFrame() }
    func audioSnapshot() -> MicrophoneProbeSnapshot { receiver.audioSnapshot() }
    func updateGain(_ gainDB: Double) { receiver.updateGain(gainDB) }
    func configure(viewport: StudioPreviewViewport, frameSink: @escaping @Sendable (StudioSampleFrame) -> Void) {
        self.viewport = viewport
        receiver.setFrameSink(frameSink)
    }
    func updateViewport(_ viewport: StudioPreviewViewport) async throws {
        self.viewport = viewport
        guard let stream else { return }
        let configuration = Self.configuration(canvasSize: viewport.pixelSize, capturesAudio: capturesAudio, viewport: viewport)
        if let sourceRect { configuration.sourceRect = sourceRect }
        try await stream.updateConfiguration(configuration)
    }

    /// All processor mutation lives on its sample queue; only retained frame/meter
    /// snapshots cross through the lock. The relay is deliberately non-MainActor.
    private final class Receiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        let queue = DispatchQueue(label: "dev.tavsan.camcord.studio.preview.samples", qos: .userInitiated)
        private struct State {
            var frame: StudioSampleFrame?
            var audio = MicrophoneProbeSnapshot()
            var stream: ObjectIdentifier?
            var epoch = UUID()
            var sequence: UInt64 = 0
            var sink: (@Sendable (StudioSampleFrame) -> Void)?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private var processor = AudioSampleProcessor()
        private var gainDB: Double = 0
        func setFrameSink(_ sink: @escaping @Sendable (StudioSampleFrame) -> Void) { state.withLock { $0.sink = sink } }
        func begin(stream: SCStream) {
            state.withLock {
                $0.frame = nil; $0.audio = .init(); $0.stream = ObjectIdentifier(stream)
                $0.epoch = UUID(); $0.sequence = 0
            }
        }
        func end(stream: SCStream) {
            state.withLock {
                guard $0.stream == ObjectIdentifier(stream) else { return }
                $0.stream = nil; $0.frame = nil; $0.sink = nil; $0.audio = .init()
            }
        }
        func latestFrame() -> StudioSampleFrame? { state.withLock { $0.frame } }
        func audioSnapshot() -> MicrophoneProbeSnapshot { state.withLock { $0.audio } }
        func updateGain(_ gain: Double) { queue.async { self.gainDB = gain } }
        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard CMSampleBufferIsValid(sampleBuffer) else { return }
            let identity = ObjectIdentifier(stream)
            guard state.withLock({ $0.stream == identity }) else { return }
            if type == .screen {
                guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                        as? [[SCStreamFrameInfo: Any]],
                      let status = attachments.first?[.status] as? Int,
                      status == SCFrameStatus.complete.rawValue,
                      CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
                let native = StudioSampleFrame(sample: sampleBuffer)
                let delivery = state.withLock { state -> (StudioSampleFrame, (@Sendable (StudioSampleFrame) -> Void)?)? in
                    guard state.stream == identity else { return nil }
                    state.sequence &+= 1
                    let frame = StudioSampleFrame(sample: native.sample, sequence: state.sequence, epoch: state.epoch)
                    state.frame = frame
                    return (frame, state.sink)
                }
                if let delivery { delivery.1?(delivery.0) }
            } else if type == .audio {
                do {
                    let output = try processor.process(sampleBuffer, gainDB: gainDB)
                    let levels = output.levels
                    state.withLock { if $0.stream == identity { $0.audio = MicrophoneProbeSnapshot(levels: levels) } }
                } catch { state.withLock { if $0.stream == identity { $0.audio.failed = true } } }
            }
        }
        func stream(_ stream: SCStream, didStopWithError error: Error) {
            state.withLock {
                guard $0.stream == ObjectIdentifier(stream) else { return }
                $0.frame = nil; $0.audio.failed = true
            }
        }
    }
}

/// Called only on the native transport's serial queue; no image bridge or actor hop.
final class StudioIdlePreviewRenderer {
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private lazy var compositor = CameraCompositor(context: context)

    func render(_ frame: StudioSampleFrame, configuration: StudioIdlePreviewConfiguration) -> PixelBufferBox? {
        do {
            let fit = configuration.fitsWindow ? StreamWriter.canvasFit(of: frame.sample) : nil
            let camera = configuration.cameraSource?.latestFrame()
            let sample = try compositor.composite(screen: frame.sample, camera: camera,
                options: configuration.cameraOptions, fit: fit, layers: configuration.layers)
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
            let full = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            return PixelBufferBox(buffer, cameraContentRect: fit?.fitted ?? full,
                pts: CMSampleBufferGetPresentationTimeStamp(sample), sequence: frame.sequence, epoch: frame.epoch)
        } catch { return nil }
    }
}
