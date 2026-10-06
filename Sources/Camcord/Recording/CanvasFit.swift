import CoreGraphics
import Foundation

/// The recording canvas of a WINDOW target. The file's size is fixed when the recording
/// starts; the window is not. `matchWindow` keeps the start window's size, the others give
/// the canvas that ratio (its long side the start window's long side, capped to the display).
/// Region and display targets ignore it.
enum CanvasAspect: String, Codable, CaseIterable, Sendable {
    case matchWindow
    case wide16x9
    case tall9x16
    case square
    case classic4x3

    /// Width over height, or nil for the start window's own shape.
    var ratio: CGFloat? {
        switch self {
        case .matchWindow: nil
        case .wide16x9: 16.0 / 9.0
        case .tall9x16: 9.0 / 16.0
        case .square: 1
        case .classic4x3: 4.0 / 3.0
        }
    }

    var title: String {
        switch self {
        case .matchWindow: String(localized: "Match window", comment: "Canvas setting: the file keeps the recorded window's shape")
        case .wide16x9: "16:9"
        case .tall9x16: "9:16"
        case .square: "1:1"
        case .classic4x3: "4:3"
        }
    }

    /// The canvas in pixels for a window of `window` pixels on a display of `display`
    /// pixels. Even dimensions, as the encoders want.
    func canvasSize(window: CGSize, display: CGSize) -> (width: Int, height: Int) {
        guard let ratio, window.width > 0, window.height > 0 else {
            return (Self.even(window.width), Self.even(window.height))
        }
        let long = max(window.width, window.height)
        var size = ratio >= 1
            ? CGSize(width: long, height: long / ratio)
            : CGSize(width: long * ratio, height: long)
        if display.width > 0, display.height > 0 {
            let cap = min(1, display.width / size.width, display.height / size.height)
            size = CGSize(width: size.width * cap, height: size.height * cap)
        }
        return (Self.even(size.width), Self.even(size.height))
    }

    /// The same rounding as every other target; an empty window still yields 0 and is
    /// rejected by the writer rather than recorded as a 2×2 file.
    private static func even(_ value: CGFloat) -> Int { RegionClamp.evenFloor(value) }
}

/// Where a window's live content sits in the fixed canvas, and what fills the rest. All
/// rects are in canvas PIXELS with a TOP-LEFT origin, the buffer's own row order.
///
/// ScreenCaptureKit, with `scalesToFit` and `preservesAspectRatio`, puts a resized window's
/// content in the TOP-LEFT of the fixed buffer — shrunk windows at 1×, grown ones scaled
/// down — and leaves the rest black. `SCStreamFrameInfo.contentRect` is that content, in
/// output points (measured 2026-09-25). This moves it to
/// the centre, aspect-fit, over a backdrop made from the same frame.
struct CanvasFit: Equatable, Sendable {
    /// The canvas, which is also the buffer ScreenCaptureKit fills.
    let canvas: CGSize
    /// The live content inside the buffer, as ScreenCaptureKit placed it.
    let content: CGRect
    /// Where the content goes: aspect-fit and centred in the canvas.
    let fitted: CGRect
    /// The content scaled to fill the canvas (and beyond), centred — blurred, it is the
    /// backdrop behind `fitted`, so no black band ever reaches the file.
    let backdrop: CGRect

    /// A content rect within a pixel of the whole canvas needs no work at all.
    var isPassThrough: Bool {
        abs(content.minX) < 1 && abs(content.minY) < 1
            && abs(content.width - canvas.width) < 1 && abs(content.height - canvas.height) < 1
    }

    init(canvas: CGSize, content rawContent: CGRect) {
        self.canvas = canvas
        let bounds = CGRect(origin: .zero, size: canvas)
        var content = rawContent.integral.intersection(bounds)
        if content.isNull || content.width < 2 || content.height < 2 { content = bounds }
        self.content = content
        let fit = min(canvas.width / content.width, canvas.height / content.height)
        let fill = max(canvas.width / content.width, canvas.height / content.height)
        fitted = Self.centred(CGSize(width: content.width * fit, height: content.height * fit), in: canvas)
        backdrop = Self.centred(CGSize(width: content.width * fill, height: content.height * fill), in: canvas)
    }

    /// From a frame's `contentRect` (output points) and `scaleFactor` (points → pixels).
    init(canvas: CGSize, contentRect: CGRect, scaleFactor: CGFloat) {
        let scale = scaleFactor.isFinite && scaleFactor > 0 ? scaleFactor : 1
        self.init(canvas: canvas, content: CGRect(
            x: contentRect.minX * scale, y: contentRect.minY * scale,
            width: contentRect.width * scale, height: contentRect.height * scale
        ))
    }

    /// A top-left-origin rect in the bottom-left-origin space Core Image draws in.
    func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func centred(_ size: CGSize, in canvas: CGSize) -> CGRect {
        CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
               width: size.width, height: size.height)
    }
}
