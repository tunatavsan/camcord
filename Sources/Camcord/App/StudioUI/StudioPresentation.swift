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
        result.place(options.rect(in: contentRect.size).offsetBy(dx: translation.width * scale, dy: -translation.height * scale),
                     in: contentRect.size, snapDistance: min(84, min(contentRect.width, contentRect.height) * 0.18))
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
