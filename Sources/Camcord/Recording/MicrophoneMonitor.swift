import AVFoundation
import Combine
import os

/// Explicit, meter-only microphone rehearsal. No audio is saved or played through
/// the speakers. The recording controller releases this hardware session before SCK
/// starts, so opening Settings can never compete with an active recording.
@MainActor
final class MicrophoneMonitor: ObservableObject {
    static let shared = MicrophoneMonitor()

    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var recordingLocked = false
    @Published private(set) var levels: AudioLevels?
    @Published private(set) var message: String?

    private let capture = MicrophoneProbeCapture()
    private var generation = UUID()
    private var poll: Task<Void, Never>?

    func start(deviceID: String?, gainDB: Double) async {
        guard !recordingLocked, !isStarting, !isRunning else { return }
        let token = UUID()
        generation = token
        isStarting = true
        message = nil
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .audio)
        default: authorized = false
        }
        guard generation == token, !recordingLocked else { return }
        guard authorized else {
            isStarting = false
            message = "Mikrofon izni gerekli. İzinler bölümünden açabilirsin."
            return
        }
        do {
            try await capture.start(deviceID: deviceID, gainDB: gainDB)
            guard generation == token, !recordingLocked else { return }
            isStarting = false
            isRunning = true
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.generation == token else { return }
                    let snapshot = self.capture.snapshot()
                    self.levels = snapshot.levels
                    self.message = snapshot.failed ? "Mikrofon verisi okunamadı. Başka bir giriş seç." : nil
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        } catch {
            guard generation == token else { return }
            isStarting = false
            message = "Mikrofon açılamadı. Bağlantısını ve seçili girişi kontrol et."
        }
    }

    func updateGain(_ gainDB: Double) { capture.updateGain(gainDB) }

    func stop() async {
        generation = UUID()
        poll?.cancel()
        poll = nil
        isStarting = false
        isRunning = false
        levels = nil
        await capture.stop()
    }

    func prepareForRecording() async {
        recordingLocked = true
        await stop()
    }

    func recordingEnded() { recordingLocked = false }
}

/// All AVCaptureSession and processor mutations use one queue. The tiny copied
/// meter snapshot is the only state read across queues.
private final class MicrophoneProbeCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Snapshot: Sendable { var levels: AudioLevels?; var failed = false }
    private let meter = OSAllocatedUnfairLock(initialState: Snapshot())
    private let queue = DispatchQueue(label: "dev.tavsan.camcord.microphone-probe", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var processor = AudioSampleProcessor()
    private var gainDB: Double = 0

    func snapshot() -> Snapshot { meter.withLock { $0 } }
    func updateGain(_ value: Double) { queue.async { self.gainDB = value } }

    func start(deviceID: String?, gainDB: Double) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    self.stopOnQueue()
                    guard let device = deviceID.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .audio) else {
                        throw ProbeError.noDevice
                    }
                    let session = AVCaptureSession()
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    output.audioSettings = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsNonInterleaved: false,
                    ]
                    guard session.canAddInput(input), session.canAddOutput(output) else { throw ProbeError.noDevice }
                    session.addInput(input)
                    session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    self.gainDB = gainDB
                    self.processor = AudioSampleProcessor()
                    self.session = session
                    session.startRunning()
                    guard session.isRunning else { throw ProbeError.noDevice }
                    continuation.resume()
                } catch {
                    self.stopOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { self.stopOnQueue(); continuation.resume() }
        }
    }

    private func stopOnQueue() {
        session?.stopRunning()
        session = nil
        meter.withLock { $0 = Snapshot() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard session != nil else { return }
        do {
            let levels = try processor.process(sampleBuffer, gainDB: gainDB).levels
            meter.withLock { $0 = Snapshot(levels: levels) }
        } catch {
            meter.withLock { $0.failed = true }
        }
    }

    private enum ProbeError: Error { case noDevice }
}
