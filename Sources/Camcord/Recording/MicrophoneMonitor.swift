import AVFoundation
import Combine
import os

struct MicrophoneProbeSnapshot: Sendable {
    var levels: AudioLevels?
    var failed = false
}

protocol MicrophoneProbe: AnyObject, Sendable {
    func start(deviceID: String?, gainDB: Double) async throws
    func stop() async
    func updateGain(_ value: Double)
    func snapshot() -> MicrophoneProbeSnapshot
}

/// Explicit meter-only microphone rehearsal. Each consumer owns a stable token;
/// recording clears all tokens before acquiring the physical input.
@MainActor
final class MicrophoneMonitor: ObservableObject {
    static let shared = MicrophoneMonitor()

    struct Operations {
        var authorize: () async -> Bool = {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
            default: return false
            }
        }
        var makeProbe: () -> any MicrophoneProbe = { MicrophoneProbeCapture() }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var recordingLocked = false
    @Published private(set) var levels: AudioLevels?
    @Published private(set) var message: String?
    @Published private(set) var activeOwner: UUID?

    private struct Request: Sendable {
        let id = UUID()
        let owner: UUID
        var deviceID: String?
        var gainDB: Double
    }
    private let operations: Operations
    private let legacyOwner = UUID()
    private var requests: [Request] = []
    private var capture: (any MicrophoneProbe)?
    private var generation = UUID()
    private var poll: Task<Void, Never>?

    init(operations: Operations = .init()) { self.operations = operations }

    /// True only for the currently selected owner, including its pending start.
    /// Older registrations may remain available after the newest owner is released.
    func owns(_ owner: UUID) -> Bool { requests.last?.owner == owner && !recordingLocked }

    func start(owner: UUID, deviceID: String?, gainDB: Double) async {
        guard !recordingLocked, !Task.isCancelled else { return }
        requests.removeAll { $0.owner == owner }
        let request = Request(owner: owner, deviceID: deviceID, gainDB: Self.gain(gainDB))
        requests.append(request)
        await withTaskCancellationHandler {
            await reconcile()
        } onCancel: {
            Task { @MainActor [weak self] in await self?.releaseCancelledRequest(request) }
        }
    }

    func release(owner: UUID) async {
        let wasCurrent = requests.last?.owner == owner
        requests.removeAll { $0.owner == owner }
        guard wasCurrent else { return }
        await reconcile()
    }

    func updateGain(_ gainDB: Double, owner: UUID) {
        guard let index = requests.firstIndex(where: { $0.owner == owner }) else { return }
        let value = Self.gain(gainDB)
        requests[index].gainDB = value
        if activeOwner == owner, owns(owner) { capture?.updateGain(value) }
    }

    // Legacy consumers have an independent lease; nil/stop cannot retire Studio or Settings.
    func start(deviceID: String?, gainDB: Double) async {
        await start(owner: legacyOwner, deviceID: deviceID, gainDB: gainDB)
    }
    func updateGain(_ gainDB: Double) { updateGain(gainDB, owner: legacyOwner) }
    func stop() async { await release(owner: legacyOwner) }

    func prepareForRecording() async {
        recordingLocked = true
        requests.removeAll()
        await reconcile()
    }
    func recordingEnded() { recordingLocked = false }

    private func releaseCancelledRequest(_ request: Request) async {
        guard requests.contains(where: { $0.id == request.id }) else { return }
        await release(owner: request.owner)
    }

    private func reconcile() async {
        let token = UUID()
        generation = token
        poll?.cancel()
        poll = nil
        let retiring = capture
        capture = nil
        activeOwner = nil
        isRunning = false
        isStarting = false
        levels = nil
        message = nil
        let desired = recordingLocked ? nil : requests.last
        isStarting = desired != nil
        if let retiring { await retiring.stop() }
        guard generation == token, !Task.isCancelled else { return }
        guard let desired, !recordingLocked, owns(desired.owner) else { isStarting = false; return }
        let authorized = await operations.authorize()
        guard generation == token, !Task.isCancelled, !recordingLocked, owns(desired.owner) else { return }
        guard authorized else {
            isStarting = false
            message = String(localized: "Microphone permission is required. Open Permissions to enable it.", comment: "Microphone rehearsal status")
            return
        }
        let probe = operations.makeProbe()
        capture = probe
        activeOwner = desired.owner
        do {
            try await probe.start(deviceID: desired.deviceID, gainDB: desired.gainDB)
            guard generation == token, !Task.isCancelled, !recordingLocked,
                  capture === probe, owns(desired.owner) else {
                await probe.stop()
                return
            }
            isStarting = false
            isRunning = true
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.generation == token, self.capture === probe else { return }
                    let snapshot = probe.snapshot()
                    self.levels = snapshot.levels
                    self.message = snapshot.failed ? String(localized: "Microphone data could not be read. Choose another input.", comment: "Microphone rehearsal status") : nil
                    do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                }
            }
        } catch {
            await probe.stop()
            guard generation == token, capture === probe else { return }
            capture = nil
            activeOwner = nil
            isStarting = false
            message = String(localized: "The microphone could not start. Check its connection and selected input.", comment: "Microphone rehearsal status")
        }
    }

    private static func gain(_ value: Double) -> Double {
        value.isFinite ? min(24, max(-24, value)) : 0
    }
}

/// All AVCaptureSession and processor mutations use one queue. The tiny copied
/// meter snapshot is the only state read across queues.
final class MicrophoneProbeCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable, MicrophoneProbe {
    private let meter = OSAllocatedUnfairLock(initialState: MicrophoneProbeSnapshot())
    private static let operationQueue = DispatchQueue(label: "dev.tavsan.camcord.microphone-probe", qos: .userInitiated)
    private let queue = operationQueue
    private var session: AVCaptureSession?
    private var processor = AudioSampleProcessor()
    private var gainDB: Double = 0

    func snapshot() -> MicrophoneProbeSnapshot { meter.withLock { $0 } }
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
        meter.withLock { $0 = MicrophoneProbeSnapshot() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard session != nil else { return }
        do {
            let levels = try processor.process(sampleBuffer, gainDB: gainDB).levels
            meter.withLock { $0 = MicrophoneProbeSnapshot(levels: levels) }
        } catch {
            meter.withLock { $0.failed = true }
        }
    }

    private enum ProbeError: Error { case noDevice }
}
