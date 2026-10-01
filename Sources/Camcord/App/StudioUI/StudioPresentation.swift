import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Observation
import CoreGraphics
import SwiftUI

/// Presentation rules are value-only so lifecycle and keyboard actions can be checked without a window.
struct StudioViewGate: Equatable {
    var moduleVisible: Bool
    var windowAllowsPreview: Bool
    var captureTransition: Bool
    var allowsPreview: Bool { moduleVisible && windowAllowsPreview && !captureTransition }
}

/// Hardware/output bindings lock for a recording; the existing writer accepts gain, placement and layer deltas live.
@MainActor struct StudioEditingPolicy {
    let state: RecordingController.UIState
    let isStarting: Bool
    let isFinishing: Bool
    let isArmed: Bool
    let controllerBusy: Bool
    let allowsPreview: Bool
    var bindingsLocked: Bool { controllerBusy || state != .idle || liveEditsLocked }
    var liveEditsLocked: Bool { isStarting || isFinishing || isArmed || !allowsPreview }
}

enum StudioAudioStatus: Equatable {
    case off, ready, testing, noSignal, recording, paused
    static func resolve(enabled: Bool, recording: Bool, paused: Bool, ownsTest: Bool, levels: AudioLevels?) -> Self {
        if !enabled && !ownsTest { return .off }
        if recording {
            if paused { return .paused }
            return levels == nil ? .noSignal : .recording
        }
        if ownsTest { return levels == nil ? .noSignal : .testing }
        return .ready
    }
    var title: LocalizedStringResource {
        switch self {
        case .off: "Off"
        case .ready: "Ready to test"
        case .testing: "Test"
        case .noSignal: "No signal"
        case .recording: "Recording"
        case .paused: "Paused"
        }
    }
    var measures: Bool { self == .testing || self == .recording || self == .noSignal }
}

/// Layer destinations use a top-left unit canvas. CameraOptions alone uses bottom-left travel.
enum StudioStageGeometry {
    static func fittedCanvas(_ canvas: CGSize, in bounds: CGRect) -> CGRect {
        guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / canvas.width, bounds.height / canvas.height)
        let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
    static func layerRect(_ unit: CGRect, in canvas: CGRect) -> CGRect {
        CGRect(x: canvas.minX + unit.minX * canvas.width, y: canvas.minY + unit.minY * canvas.height,
               width: unit.width * canvas.width, height: unit.height * canvas.height)
    }
    static func movedLayer(_ rect: CGRect, translation: CGSize, canvas: CGRect) -> CGRect {
        guard canvas.width > 0, canvas.height > 0 else { return rect }
        return CGRect(x: min(max(0, rect.minX + translation.width / canvas.width), 1 - rect.width),
                      y: min(max(0, rect.minY + translation.height / canvas.height), 1 - rect.height),
                      width: rect.width, height: rect.height)
    }
    /// Content metadata is top-left destination geometry emitted by the actual compositor.
    /// CameraOptions is bottom-left travel inside that content, while layers use the whole canvas.
    static func cameraRect(_ options: CameraOptions, canvas: CGSize, contentRect: CGRect, fitted: CGRect) -> CGRect {
        guard validCameraViewport(canvas: canvas, contentRect: contentRect, fitted: fitted) else { return .zero }
        let rect = options.rect(in: contentRect.size)
        let scale = fitted.width / canvas.width
        return CGRect(x: fitted.minX + (contentRect.minX + rect.minX) * scale,
                      y: fitted.minY + (contentRect.minY + contentRect.height - rect.maxY) * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }
    static func movedCamera(_ options: CameraOptions, translation: CGSize, canvas: CGSize,
                            contentRect: CGRect, fitted: CGRect) -> CameraOptions {
        guard validCameraViewport(canvas: canvas, contentRect: contentRect, fitted: fitted) else { return options }
        let scale = canvas.width / fitted.width
        var result = options
        let moved = options.rect(in: contentRect.size).offsetBy(dx: translation.width * scale, dy: -translation.height * scale)
        result.place(edgeMagnet(moved, in: contentRect.size, distance: 8 * scale), in: contentRect.size)
        return result.resolved()
    }
    static func resizedCamera(_ options: CameraOptions, translation: CGSize, corner: CameraCorner,
                              canvas: CGSize, contentRect: CGRect, fitted: CGRect) -> CameraOptions {
        guard validCameraViewport(canvas: canvas, contentRect: contentRect, fitted: fitted) else { return options }
        let scale = canvas.width / fitted.width
        return CameraResizeGeometry.resize(start: options.rect(in: contentRect.size),
            translation: CGPoint(x: translation.width * scale, y: -translation.height * scale),
            corner: corner, options: options, in: contentRect.size)
    }
    /// Stage-point attraction is converted to destination units; placement stays shared with the compositor.
    static func edgeMagnet(_ rect: CGRect, in size: CGSize, distance: CGFloat) -> CGRect {
        let margin = CameraOptions.margin(in: size)
        let left = margin, right = max(left, size.width - margin - rect.width)
        let bottom = margin, top = max(bottom, size.height - margin - rect.height)
        var result = rect
        if abs(rect.minX - left) <= distance { result.origin.x = left }
        else if abs(rect.minX - right) <= distance { result.origin.x = right }
        if abs(rect.minY - bottom) <= distance { result.origin.y = bottom }
        else if abs(rect.minY - top) <= distance { result.origin.y = top }
        return result
    }
    private static func validCameraViewport(canvas: CGSize, contentRect: CGRect, fitted: CGRect) -> Bool {
        canvas.width.isFinite && canvas.height.isFinite && canvas.width > 0 && canvas.height > 0
            && contentRect.origin.x.isFinite && contentRect.origin.y.isFinite
            && contentRect.width.isFinite && contentRect.height.isFinite && contentRect.width > 0 && contentRect.height > 0
            && fitted.width.isFinite && fitted.height.isFinite && fitted.width > 0 && fitted.height > 0
    }

}

extension StudioIssue {
    var studioMessage: LocalizedStringResource {
        switch self {
        case .screenPermissionRequired: "Allow Screen Recording in System Settings to preview and record."
        case .sourceUnavailable: "The source is no longer available. Choose another source."
        case .sourceListUnavailable: "Sources could not be loaded. Refresh to try again."
        case .previewFailed: "The preview could not start. Try again or choose another source."
        case .layerLimit: "You can add up to 24 layers."
        case .imageTooLarge: "This image is too large. Choose an image below 20 MB and 16 megapixels."
        case .invalidImage: "This file could not be opened as an image."
        case .textTooLong: "This text is too long. Shorten it and try again."
        }
    }
}


/// Read-only display data can be supplied independently of the actual resource lifecycle.
/// Nil uses the live session. Implementations own their media and provenance; controls never
/// mutate a supplied snapshot or send its displayed state to a recording engine.
@MainActor protocol StudioPresentationProvider: AnyObject {
    var snapshot: StudioPresentationSnapshot { get }
}

@MainActor struct StudioPresentationSnapshot {
    let provenance: String
    let sources: [StudioSourceChoice]
    let thumbnails: [StudioSourceChoice.ID: NSImage]
    let selectedSource: StudioSourceChoice?
    let stageImage: NSImage?
    let canvasSize: CGSize
    let previewState: StudioPreviewState
    let settings: RecordingSettings
    let systemAudioLevels: AudioLevels?
    let microphoneLevels: AudioLevels?
    let recordingState: RecordingController.UIState
    let elapsed: String?
    let canRecord: Bool
    let cameraName: String
    let cameraFormat: String
    let microphoneName: String
    let finishedFile: StudioFinishedFilePresentation?
}

@MainActor struct StudioFinishedFilePresentation {
    let url: URL
    let thumbnail: NSImage?
    let dimensions: CGSize?
    let duration: Double?
    let byteCount: Int64?
}

extension EnvironmentValues {
    @Entry var studioPresentationProvider: (any StudioPresentationProvider)?
}


@MainActor protocol StudioFinishedFileLoading {
    func load(_ url: URL) async throws -> StudioFinishedFilePresentation
}

/// Real metadata and a bounded thumbnail; setup settings are never substituted for facts.
@MainActor struct StudioMediaFileLoader: StudioFinishedFileLoading {
    func load(_ url: URL) async throws -> StudioFinishedFilePresentation {
        let raw = try await StudioMediaFileReader.read(url)
        return .init(url: url, thumbnail: raw.png.flatMap(NSImage.init(data:)), dimensions: raw.size,
                     duration: raw.duration, byteCount: raw.bytes)
    }
}

private struct StudioRawFileFacts: Sendable {
    let png: Data?
    let size: CGSize?
    let duration: Double?
    let bytes: Int64?
}

private enum StudioMediaFileReader {
    static func read(_ url: URL) async throws -> StudioRawFileFacts {
        try await withThrowingTaskGroup(of: StudioRawFileFacts.self) { group in
            group.addTask { try await readAsset(url) }
            group.addTask { try await Task.sleep(for: .seconds(5)); throw CocoaError(.userCancelled) }
            defer { group.cancelAll() }
            return try await group.next() ?? { throw CocoaError(.fileReadUnknown) }()
        }
    }
    private static func readAsset(_ url: URL) async throws -> StudioRawFileFacts {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let file = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .isSymbolicLinkKey, .fileSizeKey])
        guard file.isRegularFile == true, file.isReadable == true, file.isSymbolicLink != true else { throw CocoaError(.fileReadUnknown) }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let track = try await asset.loadTracks(withMediaType: .video).first
        let size = try await track?.load(.naturalSize)
        try Task.checkCancellation()
        let decoder = StudioThumbnailDecode(url: url)
        let data = try await withTaskCancellationHandler { try await decoder.png() }
            onCancel: { Task { await decoder.cancel() } }
        try Task.checkCancellation()
        return .init(png: data, size: size, duration: duration.isFinite && duration >= 0 ? duration : nil,
                     bytes: file.fileSize.map(Int64.init))
    }
}

@MainActor @Observable final class StudioFinishedFileState {
    private(set) var file: StudioFinishedFilePresentation?
    private(set) var isLoading = false
    private var epoch = UUID()
    let loader: any StudioFinishedFileLoading
    init(loader: any StudioFinishedFileLoading = StudioMediaFileLoader()) { self.loader = loader }
    func load(_ url: URL) async {
        let token = UUID(); epoch = token; file = nil; isLoading = true
        let value = try? await loader.load(url)
        guard epoch == token, !Task.isCancelled else { return }
        isLoading = false
        file = value?.url == url ? value : nil
    }
    func hide() { epoch = UUID(); file = nil; isLoading = false }
}

enum StudioDisplayTime {
    static func clock(_ elapsed: String) -> String {
        let fields = elapsed.split(separator: ":").compactMap { Int($0.split(separator: ".").first ?? "") }
        guard !fields.isEmpty else { return elapsed }
        let seconds = fields.reversed().enumerated().reduce(0) { $0 + $1.element * Int(pow(60.0, Double($1.offset))) }
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
    static func length(_ seconds: Double) -> String { clock(String(format: "%.0f", seconds.rounded(.down))) }
}


private actor StudioThumbnailDecode {
    private let generator: AVAssetImageGenerator
    init(url: URL) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 400)
    }
    func cancel() { generator.cancelAllCGImageGeneration() }
    func png() async throws -> Data {
        let image: CGImage = try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, _, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
            }
        }
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileReadCorruptFile) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileReadCorruptFile) }
        return data as Data
    }
}
