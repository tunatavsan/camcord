import AVFoundation
import AppKit
import CoreImage
import SwiftUI

/// Retains a Core Video frame across the recording queue → preview-renderer handoff.
/// The buffer is immutable while either side holds it.
struct PixelBufferBox: @unchecked Sendable {
    let value: CVPixelBuffer
    /// Camera placement bounds in destination buffer pixels, with a top-left origin.
    let cameraContentRect: CGRect?
    let pts: CMTime
    let sequence: UInt64
    let epoch: UUID?
    var contentRect: CGRect? { cameraContentRect }

    init(_ value: CVPixelBuffer, cameraContentRect: CGRect? = nil,
         pts: CMTime = .invalid, sequence: UInt64 = 0, epoch: UUID? = nil) {
        self.value = value
        self.cameraContentRect = cameraContentRect
        self.pts = pts
        self.sequence = sequence
        self.epoch = epoch
    }

    var pixelSize: CGSize {
        CGSize(width: CVPixelBufferGetWidth(value), height: CVPixelBufferGetHeight(value))
    }
}

/// Coordinates the explicit Settings preview and the recording-owned camera source.
/// Only the former is owned/stopped here; while recording, the monitor reads the exact
/// `CameraCapture.latestFrame()` source that the compositor uses.
@MainActor
final class CameraPreviewMonitor: ObservableObject {
    static let shared = CameraPreviewMonitor()

    /// Device operations are injectable; the monitor still owns real capture identities,
    /// while lifecycle regressions can pause a stop without opening hardware.
    struct Operations {
        var authorize: (Bool) async -> Bool = { requestPermission in
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return true
            case .notDetermined where requestPermission:
                return await AVCaptureDevice.requestAccess(for: .video)
            default: return false
            }
        }
        var start: (CameraCapture, String?, CameraFormatChoice) async throws -> Void = {
            try await $0.start(deviceID: $1, format: $2)
        }
        var waitForFirstFrame: (CameraCapture) async throws -> Void = { try await $0.waitForFirstFrame() }
        var stop: (CameraCapture) async -> Void = { await $0.stop() }
    }
    private let operations: Operations

    init(operations: Operations = Operations()) { self.operations = operations }

    @Published private(set) var image: NSImage?
    @Published private(set) var isStarting = false
    @Published private(set) var isRunning = false
    @Published private(set) var recordingLocked = false
    @Published private(set) var message: String?

    /// Image surfaces share this renderer. Native Studio consumes the underlying
    /// immutable camera source and does not start the image conversion poll.
    let renderer = CameraPreviewRenderer()
    private var ownedCapture: CameraCapture?
    private var ownedCaptureID: UUID?
    private weak var recordingSource: CameraCapture?
    private var pollTask: Task<Void, Never>?
    private var renderInFlight = false
    private var visibleOwners = Set<String>()
    private var imageOwners = Set<String>()
    private var visible: Bool { !visibleOwners.isEmpty }
    private var imageVisible: Bool { !imageOwners.isEmpty }
    private var ownedDeviceID: String?
    private var ownedFormat: CameraFormatChoice?
    private var generation: UInt64 = 0

    func start(deviceID: String?, format: CameraFormatChoice, requestPermission: Bool = false) async {
        guard !Task.isCancelled, !recordingLocked, !isStarting, ownedCapture == nil else { return }
        generation &+= 1
        let token = generation
        isStarting = true
        message = nil

        let authorized = await operations.authorize(requestPermission)
        guard !Task.isCancelled, generation == token, !recordingLocked else {
            if generation == token { isStarting = false }
            return
        }
        guard authorized else {
            isStarting = false
            message = String(localized: "Camera permission is required. Open Permissions to enable it.", comment: "Camera preview status")
            return
        }

        let captureID = UUID()
        let capture = CameraCapture { [weak self] in
            Task { @MainActor [weak self] in self?.ownedSourceWasLost(captureID) }
        }
        ownedCapture = capture
        ownedCaptureID = captureID
        ownedDeviceID = deviceID
        ownedFormat = format
        do {
            try await operations.start(capture, deviceID, format)
            try await operations.waitForFirstFrame(capture)
            guard generation == token, !recordingLocked, ownedCapture === capture else {
                if ownedCapture === capture {
                    ownedCapture = nil
                    ownedCaptureID = nil
                    ownedDeviceID = nil
                    isStarting = false
                    isRunning = false
                }
                await operations.stop(capture)
                return
            }
            isStarting = false
            isRunning = true
            startPollingIfNeeded()
        } catch {
            await operations.stop(capture)
            guard generation == token, ownedCapture === capture else { return }
            ownedCapture = nil
            ownedCaptureID = nil
            isStarting = false
            isRunning = false
            image = nil
            message = Self.message(for: error)
        }
    }

    /// Stops only the Settings-owned rehearsal. A recording's camera belongs to the
    /// recording engine and is never stopped through this surface.
    func stop() async {
        guard recordingSource == nil else { return }
        // Invalidate a restart even while its previous capture is already awaiting stop.
        generation &+= 1
        guard ownedCapture != nil || isStarting else { return }
        let capture = ownedCapture
        ownedCapture = nil
        ownedCaptureID = nil
        isStarting = false
        isRunning = false
        image = nil
        stopPolling()
        if let capture { await operations.stop(capture) }
    }

    /// Only a preview running the SAME camera in the SAME format becomes the recording's
    /// camera; anything else is stopped and the recording opens its own.
    nonisolated static func canHandOff(running: Bool, deviceID: String?, format: CameraFormatChoice?,
                                       to options: CameraOptions) -> Bool {
        let resolved = options.resolved()
        return resolved.enabled && running && deviceID == resolved.deviceID && format == resolved.format
    }

    /// The running preview no longer shows the chosen camera or format: the user would not
    /// see their choice, and the record start would refuse the hand-off and reopen the camera.
    nonisolated static func isStale(deviceID: String?, format: CameraFormatChoice?,
                                    for options: CameraOptions) -> Bool {
        guard let format else { return false }   // nothing owned
        let resolved = options.resolved()
        return deviceID != resolved.deviceID || format != resolved.format
    }

    /// The camera or its format changed in Settings: a running preview restarts on the new
    /// choice; a stopped one stays stopped.
    func cameraSettingsChanged(_ options: CameraOptions) async {
        guard ownedCapture != nil, !isStarting,
              Self.isStale(deviceID: ownedDeviceID, format: ownedFormat, for: options) else { return }
        let resolved = options.resolved()
        let restartGeneration = generation &+ 1
        await stop()
        guard !Task.isCancelled, visible, !recordingLocked, generation == restartGeneration else { return }
        await start(deviceID: resolved.deviceID, format: resolved.format)
    }

    func prepareForRecording(options: CameraOptions) async -> CameraCapture? {
        let canTransfer = Self.canHandOff(running: isRunning, deviceID: ownedDeviceID, format: ownedFormat, to: options)
        recordingLocked = true
        generation &+= 1
        let capture = ownedCapture
        ownedCapture = nil
        ownedCaptureID = nil
        recordingSource = nil
        isStarting = false
        isRunning = canTransfer
        if !canTransfer { image = nil }
        message = nil
        stopPolling()
        if canTransfer { return capture }
        if let capture { await operations.stop(capture) }
        return nil
    }

    func useRecordingSource(_ source: CameraCapture?) {
        generation &+= 1
        recordingLocked = true
        recordingSource = source
        isStarting = false
        isRunning = source != nil
        if source == nil { image = nil }
        message = source == nil ? String(localized: "The recording camera is unavailable.", comment: "Camera preview status") : nil
        stopPolling()
        startPollingIfNeeded()
    }

    func recordingEnded() {
        generation &+= 1
        recordingLocked = false
        recordingSource = nil
        isStarting = false
        isRunning = false
        image = nil
        message = nil
        stopPolling()
    }

    /// A name for one on-screen instance of a preview surface.
    static func makeOwnerID(_ surface: String) -> String { "\(surface)-\(UUID().uuidString)" }

    /// Each visible surface owns its rendering subscription independently.
    func setVisible(_ visible: Bool, owner: String, rendersImage: Bool = true) {
        if visible { visibleOwners.insert(owner) } else { visibleOwners.remove(owner) }
        if visible && rendersImage { imageOwners.insert(owner) } else { imageOwners.remove(owner) }
        if imageVisible {
            startPollingIfNeeded()
        } else {
            stopPolling()
        }
    }

    /// True while any surface still holds the preview open — the floating preview keeps
    /// its claim through the fade-out, so the device outlives the last visible frame.
    var isObserved: Bool { visible }
    /// Native source observers hold the device without running the image bridge.
    var isRenderingImagePreview: Bool { pollTask != nil }

    /// Studio may join a compatible rehearsal, but cannot replace another visible owner's camera.
    func canObserve(options: CameraOptions, owner: String) -> Bool {
        visibleOwners.subtracting([owner]).isEmpty
            || Self.canHandOff(running: isRunning, deviceID: ownedDeviceID, format: ownedFormat, to: options)
    }

    func stopIfUnobserved() async {
        if visibleOwners.isEmpty { await stop() }
    }

    private func startPollingIfNeeded() {
        guard imageVisible, pollTask == nil, activeSource != nil else { return }
        let token = generation
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.imageVisible, self.generation == token else { return }
                await self.updateImage(generation: token)
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private var activeSource: CameraCapture? { recordingSource ?? ownedCapture }

    /// Immutable native frame for Studio's shared compositor; does not acquire the device.
    func currentPreviewFrame() -> PixelBufferBox? {
        activeSource?.latestFrame().map { PixelBufferBox($0) }
    }

    /// Snapshot the source identity on a lifecycle change. Its locked native frame
    /// accessor can then be used by Studio's serial compositor without actor hops.
    func currentPreviewSource() -> (any CameraFrameSource)? { activeSource }

    private func updateImage(generation token: UInt64) async {
        guard !renderInFlight else { return }
        guard let source = activeSource else { return }
        guard let frame = source.latestFrame() else {
            guard generation == token else { return }
            image = nil
            if message == nil { message = String(localized: "Waiting for the camera image…", comment: "Camera preview status") }
            return
        }

        renderInFlight = true
        defer { renderInFlight = false }
        let rendered = await renderer.render(frame, maximumWidth: 960)
        guard !Task.isCancelled, generation == token, activeSource === source else { return }
        guard let rendered else {
            image = nil
            message = String(localized: "The camera preview could not be rendered.", comment: "Camera preview status")
            return
        }
        image = NSImage(cgImage: rendered.image, size: rendered.size)
        message = nil
    }

    private func ownedSourceWasLost(_ captureID: UUID) {
        guard ownedCaptureID == captureID, let capture = ownedCapture else { return }
        generation &+= 1
        ownedCapture = nil
        ownedCaptureID = nil
        isStarting = false
        isRunning = false
        image = nil
        message = String(localized: "The camera disconnected. Check its connection and try again.", comment: "Camera preview status")
        stopPolling()
        Task { await capture.stop() }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case CameraCaptureError.noDevice:
            String(localized: "No camera found. Check the connection and the selected camera.", comment: "Camera preview error")
        case CameraCaptureError.cannotConfigure:
            String(localized: "The camera could not start with this format. Choose another camera.", comment: "Camera preview error")
        default:
            String(localized: "The camera could not start. Check its connection and try again.", comment: "Camera preview error")
        }
    }
}

/// GPU-backed preview conversion runs on a dedicated serial queue. Returning a CGImage
/// keeps AppKit object creation on the main actor and bounds rendering to one in-flight
/// frame because the monitor awaits each call before polling again.
final class CameraPreviewRenderer: @unchecked Sendable {
    struct RenderedFrame: @unchecked Sendable {
        let image: CGImage
        let size: NSSize
    }

    private let queue = DispatchQueue(label: "dev.tavsan.camcord.camera-preview", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])

    func render(_ pixelBuffer: CVPixelBuffer, maximumWidth: CGFloat) async -> RenderedFrame? {
        let pixelBuffer = PixelBufferBox(pixelBuffer)
        return await withCheckedContinuation { (continuation: CheckedContinuation<RenderedFrame?, Never>) in
            queue.async { [context] in
                let source = CIImage(cvPixelBuffer: pixelBuffer.value)
                guard source.extent.width > 0, source.extent.height > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let scale = min(1, maximumWidth / source.extent.width)
                let normalized = source.transformed(by: CGAffineTransform(
                    translationX: -source.extent.minX,
                    y: -source.extent.minY
                ))
                let rendered = scale < 1
                    ? normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    : normalized
                let extent = CGRect(
                    origin: .zero,
                    size: CGSize(
                        width: max(1, (source.extent.width * scale).rounded(.down)),
                        height: max(1, (source.extent.height * scale).rounded(.down))
                    )
                )
                guard let image = context.createCGImage(rendered, from: extent) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: RenderedFrame(image: image, size: extent.size))
            }
        }
    }
}

/// Compact Settings surface. Camera permission/hardware starts only after the explicit
/// `Preview` action; merely opening Settings performs no capture work.
struct CameraPreviewView: View {
    let options: CameraOptions

    @ObservedObject private var monitor = CameraPreviewMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Each shown instance holds the preview under its own name, so one host closing never
    /// takes the preview away from another that is still on screen.
    @State private var owner = CameraPreviewMonitor.makeOwnerID("settings")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: CamcordStyle.Radius.control)
                    .fill(Color.black.opacity(0.16))
                if let image = monitor.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(x: options.resolved().mirrored ? -1 : 1, y: 1)
                        .transition(reduceMotion ? .identity : .opacity)
                } else {
                    VStack(spacing: 7) {
                        Image(systemName: "video")
                            .font(.system(size: 24, weight: .light))
                        Text(previewPlaceholder)
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: CamcordStyle.Radius.control))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Camera preview")
            .accessibilityValue(accessibilityPreviewValue)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: monitor.image != nil)

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if monitor.recordingLocked {
                    Label("Used by the recording", systemImage: "record.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("The recording is using the camera")
                } else {
                    Button(monitor.isRunning ? "Stop" : "Preview") {
                        Task {
                            if monitor.isRunning {
                                await monitor.stop()
                            } else {
                                await monitor.start(
                                    deviceID: options.resolved().deviceID,
                                    format: options.resolved().format,
                                    requestPermission: true
                                )
                            }
                        }
                    }
                    .controlSize(.small)
                    .disabled(monitor.isStarting)
                    .accessibilityHint(
                        monitor.isRunning ? "Stops the camera preview" : "Asks for camera permission and starts the preview"
                    )
                }
            }
        }
        .onAppear { monitor.setVisible(true, owner: owner) }
        .onDisappear {
            monitor.setVisible(false, owner: owner)
            Task { await monitor.stopIfUnobserved() }
        }
        .onChange(of: options.resolved().deviceID) { _, _ in
            Task { await monitor.cameraSettingsChanged(options) }
        }
        .onChange(of: options.resolved().format) { _, _ in
            Task { await monitor.cameraSettingsChanged(options) }
        }
    }

    private var previewPlaceholder: String {
        if monitor.isStarting { return String(localized: "Starting camera…", comment: "Camera preview status") }
        if monitor.recordingLocked { return String(localized: "Waiting for the recording camera…", comment: "Camera preview status") }
        return String(localized: "Start preview", comment: "Camera preview placeholder")
    }

    private var statusText: String {
        if let message = monitor.message { return message }
        if monitor.isStarting { return String(localized: "Starting camera…", comment: "Camera preview status") }
        if monitor.recordingLocked, monitor.isRunning {
            return String(localized: "Recording camera is live", comment: "Camera preview status")
        }
        if monitor.recordingLocked { return String(localized: "Waiting for the recording camera…", comment: "Camera preview status") }
        if monitor.isRunning { return String(localized: "Live preview", comment: "Camera preview status") }
        return String(localized: "Camera off", comment: "Camera preview status")
    }

    private var statusColor: Color {
        if monitor.message != nil { return .orange }
        if monitor.isRunning { return .green }
        return .secondary.opacity(0.6)
    }

    private var accessibilityPreviewValue: String {
        if monitor.image != nil {
            return options.resolved().mirrored
                ? String(localized: "Live, mirrored", comment: "Accessibility value: the camera preview")
                : String(localized: "Live", comment: "Accessibility value: the camera preview")
        }
        return statusText
    }
}
