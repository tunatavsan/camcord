import AVFoundation
import AppKit
import CoreImage
import SwiftUI

/// Retains a Core Video frame across the recording queue → preview-renderer handoff.
/// The buffer is immutable while either side holds it.
struct PixelBufferBox: @unchecked Sendable {
    let value: CVPixelBuffer

    init(_ value: CVPixelBuffer) { self.value = value }

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

    @Published private(set) var image: NSImage?
    @Published private(set) var isStarting = false
    @Published private(set) var isRunning = false
    @Published private(set) var recordingLocked = false
    @Published private(set) var message: String?

    /// The camera preview and recording stage share this renderer, including its queue
    /// and CIContext, so opening the stage creates no second GPU rendering pipeline.
    let renderer = CameraPreviewRenderer()
    private var ownedCapture: CameraCapture?
    private var ownedCaptureID: UUID?
    private weak var recordingSource: CameraCapture?
    private var pollTask: Task<Void, Never>?
    private var renderInFlight = false
    private var visibleOwners = Set<String>()
    private var visible: Bool { !visibleOwners.isEmpty }
    private var ownedDeviceID: String?
    private var ownedFormat: CameraFormatChoice?
    private var generation: UInt64 = 0

    func start(deviceID: String?, format: CameraFormatChoice, requestPermission: Bool = false) async {
        guard !Task.isCancelled, !recordingLocked, !isStarting, ownedCapture == nil else { return }
        generation &+= 1
        let token = generation
        isStarting = true
        message = nil

        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
        case .notDetermined where requestPermission:
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        case .notDetermined:
            authorized = false
        default:
            authorized = false
        }
        guard !Task.isCancelled, generation == token, !recordingLocked else {
            isStarting = false
            return
        }
        guard authorized else {
            isStarting = false
            message = "Kamera izni gerekli. İzinler bölümünden açabilirsin."
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
            try await capture.start(deviceID: deviceID, format: format)
            try await capture.waitForFirstFrame()
            guard generation == token, !recordingLocked, ownedCapture === capture else {
                if ownedCapture === capture {
                    ownedCapture = nil
                    ownedCaptureID = nil
                    ownedDeviceID = nil
                    isStarting = false
                    isRunning = false
                }
                await capture.stop()
                return
            }
            isStarting = false
            isRunning = true
            startPollingIfNeeded()
        } catch {
            await capture.stop()
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
        guard recordingSource == nil, ownedCapture != nil || isStarting else { return }
        generation &+= 1
        let capture = ownedCapture
        ownedCapture = nil
        ownedCaptureID = nil
        isStarting = false
        isRunning = false
        image = nil
        stopPolling()
        if let capture { await capture.stop() }
    }

    /// Only a preview running the SAME camera in the SAME format becomes the recording's
    /// camera; anything else is stopped and the recording opens its own.
    nonisolated static func canHandOff(running: Bool, deviceID: String?, format: CameraFormatChoice?,
                                       to options: CameraOptions) -> Bool {
        let resolved = options.resolved()
        return resolved.enabled && running && deviceID == resolved.deviceID && format == resolved.format
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
        if let capture { await capture.stop() }
        return nil
    }

    func useRecordingSource(_ source: CameraCapture?) {
        generation &+= 1
        recordingLocked = true
        recordingSource = source
        isStarting = false
        isRunning = source != nil
        if source == nil { image = nil }
        message = source == nil ? "Kayıt kamerası kullanılamıyor." : nil
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

    /// Each visible surface owns its rendering subscription independently.
    func setVisible(_ visible: Bool, owner: String = "settings") {
        if visible { visibleOwners.insert(owner) } else { visibleOwners.remove(owner) }
        if self.visible {
            startPollingIfNeeded()
        } else {
            stopPolling()
        }
    }

    /// True while any surface still holds the preview open — the floating preview keeps
    /// its claim through the fade-out, so the device outlives the last visible frame.
    var isObserved: Bool { visible }

    func stopIfUnobserved() async {
        if visibleOwners.isEmpty { await stop() }
    }

    private func startPollingIfNeeded() {
        guard visible, pollTask == nil, activeSource != nil else { return }
        let token = generation
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.visible, self.generation == token else { return }
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

    private func updateImage(generation token: UInt64) async {
        guard !renderInFlight else { return }
        guard let source = activeSource else { return }
        guard let frame = source.latestFrame() else {
            guard generation == token else { return }
            image = nil
            if message == nil { message = "Kamera görüntüsü bekleniyor…" }
            return
        }

        renderInFlight = true
        defer { renderInFlight = false }
        let rendered = await renderer.render(frame, maximumWidth: 960)
        guard !Task.isCancelled, generation == token, activeSource === source else { return }
        guard let rendered else {
            image = nil
            message = "Kamera önizlemesi oluşturulamadı."
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
        message = "Kamera bağlantısı kesildi. Bağlantıyı kontrol edip yeniden dene."
        stopPolling()
        Task { await capture.stop() }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case CameraCaptureError.noDevice:
            "Kamera bulunamadı. Bağlantıyı ve seçili kamerayı kontrol et."
        case CameraCaptureError.cannotConfigure:
            "Kamera bu görüntü ayarıyla açılamadı. Başka bir kamera seç."
        default:
            "Kamera açılamadı. Bağlantıyı kontrol edip yeniden dene."
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
/// `Önizleme` action; merely opening Settings performs no capture work.
struct CameraPreviewView: View {
    let options: CameraOptions

    @ObservedObject private var monitor = CameraPreviewMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .accessibilityLabel("Kamera önizlemesi")
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
                    Label("Kayda bağlı", systemImage: "record.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Kamera kayıt tarafından kullanılıyor")
                } else {
                    Button(monitor.isRunning ? "Durdur" : "Önizleme") {
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
                        monitor.isRunning ? "Kamera önizlemesini durdurur" : "Kamera izni ister ve önizlemeyi başlatır"
                    )
                }
            }
        }
        .onAppear { monitor.setVisible(true) }
        .onDisappear {
            monitor.setVisible(false)
            Task { await monitor.stopIfUnobserved() }
        }
        .onChange(of: options.resolved().deviceID) { _, _ in
            Task { await monitor.stop() }
        }
    }

    private var previewPlaceholder: String {
        if monitor.isStarting { return "Kamera açılıyor…" }
        if monitor.recordingLocked { return "Kayıt kamerası bekleniyor…" }
        return "Önizlemeyi başlat"
    }

    private var statusText: String {
        if let message = monitor.message { return message }
        if monitor.isStarting { return "Kamera açılıyor…" }
        if monitor.recordingLocked, monitor.isRunning { return "Kayıt kamerası canlı" }
        if monitor.recordingLocked { return "Kayıt kamerası bekleniyor…" }
        if monitor.isRunning { return "Önizleme canlı" }
        return "Kamera kapalı"
    }

    private var statusColor: Color {
        if monitor.message != nil { return .orange }
        if monitor.isRunning { return .green }
        return .secondary.opacity(0.6)
    }

    private var accessibilityPreviewValue: String {
        if monitor.image != nil { return options.resolved().mirrored ? "Canlı, aynalanmış" : "Canlı" }
        return statusText
    }
}
