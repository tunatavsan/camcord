import AVFoundation
import CoreMedia
import CoreVideo
import os

/// Read-only frame seam: recording and preview consume the same immutable source.
protocol CameraFrameSource: Sendable {
    func latestFrame() -> CVPixelBuffer?
}

enum CameraCaptureError: Error {
    case noDevice
    case cannotConfigure
    case didNotStart
}

/// Video-only camera source. Session and delegate state are confined to `sessionQueue`; the
/// newest retained pixel buffer is the sole cross-queue payload.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, CameraFrameSource, @unchecked Sendable {
    private struct ControlState {
        var generation: UInt64 = 0
        var wantsRunning = false
    }

    private struct FrameState: @unchecked Sendable {
        var buffer: CVPixelBuffer?
        var capturedAt: TimeInterval = 0
        var generation: UInt64 = 0
        var lossReported = false
    }

    private let sessionQueue = DispatchQueue(
        label: "dev.tavsan.camcord.camera-capture",
        qos: .userInitiated
    )
    private let control = OSAllocatedUnfairLock(initialState: ControlState())
    private let frame = OSAllocatedUnfairLock(initialState: FrameState())
    private let lossHandler: OSAllocatedUnfairLock<@Sendable () -> Void>

    // sessionQueue confined
    private var session: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var activeGeneration: UInt64?
    private var observers: [NSObjectProtocol] = []

    /// A camera frame older than this is treated as a lost source instead of being frozen into
    /// the recording indefinitely.
    private static let maximumFrameAge: TimeInterval = 1.0

    init(onSourceLost: @escaping @Sendable () -> Void = {}) {
        self.lossHandler = OSAllocatedUnfairLock(initialState: onSourceLost)
        super.init()
    }

    func setLossHandler(_ handler: @escaping @Sendable () -> Void) {
        lossHandler.withLock { $0 = handler }
    }

    /// The format the session runs, once started. Written on `sessionQueue`.
    private let resolvedFormat = OSAllocatedUnfairLock<CameraFormatResolution?>(initialState: nil)
    /// The choice this capture was started with, for the preview → recording handoff.
    private let started = OSAllocatedUnfairLock<CameraFormatChoice?>(initialState: nil)

    var activeFormat: CameraFormatResolution? { resolvedFormat.withLock { $0 } }
    var startedChoice: CameraFormatChoice? { started.withLock { $0 } }

    func start(deviceID: String?, format: CameraFormatChoice) async throws {
        started.withLock { $0 = format }
        let generation = control.withLock { state -> UInt64 in
            state.generation &+= 1
            state.wantsRunning = true
            return state.generation
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sessionQueue.async { [self] in
                    do {
                        try startOnQueue(deviceID: deviceID, format: format, generation: generation)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { [control] in
            control.withLock { state in
                guard state.generation == generation else { return }
                state.generation &+= 1
                state.wantsRunning = false
            }
        }
    }

    /// A running AVCaptureSession can still be warming up. Do not announce a
    /// ready camera or release the recording gate before its first usable frame.
    func waitForFirstFrame() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while latestFrame() == nil {
            try Task.checkCancellation()
            guard control.withLock({ $0.wantsRunning }) else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw CameraCaptureError.didNotStart }
            try await Task.sleep(for: .milliseconds(8))
        }
    }

    func stop() async {
        control.withLock { state in
            state.generation &+= 1
            state.wantsRunning = false
        }
        clearLatestFrame(reportLoss: false)
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                stopOnQueue()
                continuation.resume()
            }
        }
    }

    /// Returns the immutable newest frame reference. Internally only one camera buffer is retained.
    func latestFrame() -> CVPixelBuffer? {
        let (result, shouldReport) = frame.withLockUnchecked { state -> (CVPixelBuffer?, Bool) in
            guard let buffer = state.buffer else { return (nil, false) }
            guard ProcessInfo.processInfo.systemUptime - state.capturedAt <= Self.maximumFrameAge else {
                state.buffer = nil
                if state.generation != 0, !state.lossReported {
                    state.lossReported = true
                    return (nil, true)
                }
                return (nil, false)
            }
            return (buffer, false)
        }
        if shouldReport { lossHandler.withLock { $0 }() }
        return result
    }

    private func startOnQueue(deviceID: String?, format: CameraFormatChoice, generation: UInt64) throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard isCurrent(generation) else { throw CancellationError() }
        stopOnQueue()

        let selected = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)).flatMap {
            $0.isConnected ? $0 : nil
        }
        guard let device = selected
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video)
        else { throw CameraCaptureError.noDevice }

        guard isCurrent(generation) else { throw CancellationError() }

        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraCaptureError.cannotConfigure
        }
        session.addInput(input)
        // Choose the format after attaching the input: adding it may select a
        // different default format on the device.
        resolvedFormat.withLock { $0 = nil }
        do {
            let resolution = try Self.configure(device: device, choice: format)
            resolvedFormat.withLock { $0 = resolution }
        } catch {
            session.commitConfiguration()
            throw error
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        session.commitConfiguration()

        self.session = session
        videoOutput = output
        activeGeneration = generation
        installObservers(for: session, device: device, generation: generation)
        frame.withLock { $0 = FrameState(generation: generation) }

        session.startRunning()
        guard isCurrent(generation) else {
            stopOnQueue()
            throw CancellationError()
        }
        guard session.isRunning else {
            stopOnQueue()
            throw CameraCaptureError.didNotStart
        }
    }

    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        videoOutput = nil
        session?.stopRunning()
        session = nil
        activeGeneration = nil
        clearLatestFrame(reportLoss: false)
    }

    private func installObservers(
        for session: AVCaptureSession,
        device: AVCaptureDevice,
        generation: UInt64
    ) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.enqueueSourceLost(generation: generation)
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.enqueueSourceLost(generation: generation)
        })
        observers.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: device,
            queue: nil
        ) { [weak self] _ in
            self?.enqueueSourceLost(generation: generation)
        })
    }

    private func enqueueSourceLost(generation: UInt64) {
        sessionQueue.async { [weak self] in
            self?.sourceWasLost(generation: generation)
        }
    }

    private func sourceWasLost(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard activeGeneration == generation else { return }
        clearLatestFrame(reportLoss: true)
    }

    private func clearLatestFrame(reportLoss: Bool) {
        let shouldReport = frame.withLockUnchecked { state -> Bool in
            state.buffer = nil
            guard reportLoss, state.generation != 0, !state.lossReported else { return false }
            state.lossReported = true
            return true
        }
        if shouldReport { lossHandler.withLock { $0 }() }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        control.withLock { $0.generation == generation && $0.wantsRunning }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let videoOutput, output === videoOutput,
            let generation = activeGeneration, isCurrent(generation),
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        frame.withLockUnchecked {
            $0.buffer = pixelBuffer
            $0.capturedAt = ProcessInfo.processInfo.systemUptime
            $0.generation = generation
        }
    }

    /// Applies the user's choice (Auto or a manual `W×H @ fps`) through the pure rules in
    /// `CameraFormatSelection`, and returns what the device now runs.
    private static func configure(device: AVCaptureDevice, choice: CameraFormatChoice) throws -> CameraFormatResolution {
        let formats = device.formats
        guard let resolution = CameraFormatSelection.resolve(choice, formats: formats.map(CameraFormatDescriptor.init)),
              formats.indices.contains(resolution.index)
        else { throw CameraCaptureError.cannotConfigure }
        let format = formats[resolution.index]
        // A rate a range reaches exactly; clamped in case the range is 29.97-style.
        let range = format.videoSupportedFrameRateRanges.first {
            resolution.fps >= $0.minFrameRate && resolution.fps <= $0.maxFrameRate
        } ?? format.videoSupportedFrameRateRanges.max { $0.maxFrameRate < $1.maxFrameRate }
        guard let range else { throw CameraCaptureError.cannotConfigure }
        let actualFPS = min(max(resolution.fps, range.minFrameRate), range.maxFrameRate)

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        let duration = CMTimeMakeWithSeconds(1 / actualFPS, preferredTimescale: 60_000)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        var active = resolution
        active.fps = actualFPS
        return active
    }
}
