import AppKit
import CoreGraphics

/// A tiny monotonically increasing token source for newest-request-wins async work.
/// Increment at acceptance, not completion: an older slow task can never become current again.
struct LatestRequestGate {
    private var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    func isCurrent(_ token: UInt64) -> Bool {
        token == generation
    }

    mutating func invalidate() {
        generation &+= 1
    }
}

/// Immutable desktop pixels and window geometry sampled before the selection overlay appears.
///
/// The screenshot path crops only these images. Mouse movement, hover dismissal, window animation,
/// or overlay focus changes after this value is created therefore cannot alter the result.
struct FrozenDesktopSnapshot: @unchecked Sendable {
    struct Display: @unchecked Sendable {
        let id: CGDirectDisplayID
        let cgFrame: CGRect
        let image: CGImage

        var scaleX: CGFloat { CGFloat(image.width) / max(cgFrame.width, 0.001) }
        var scaleY: CGFloat { CGFloat(image.height) / max(cgFrame.height, 0.001) }
    }

    struct Window: Sendable, Equatable {
        let id: CGWindowID
        let frame: CGRect
    }

    struct Crop: @unchecked Sendable {
        let image: CGImage
        let pointSize: CGSize
    }

    let displays: [Display]
    /// Front-to-back normal windows captured at trigger time.
    let windows: [Window]
    let resolutionScale: ResolutionScale

    init(
        displays: [Display],
        windows: [Window],
        resolutionScale: ResolutionScale = .native
    ) {
        self.displays = displays
        self.windows = windows
        self.resolutionScale = resolutionScale
    }

    var desktopBounds: CGRect {
        displays.first?.cgFrame ?? .null
    }

    func display(id: CGDirectDisplayID) -> Display? {
        displays.first { $0.id == id }
    }

    func matches(displayFramesByID current: [CGDirectDisplayID: CGRect]) -> Bool {
        return displays.allSatisfy { display in
            guard let frame = current[display.id] else { return false }
            return abs(frame.minX - display.cgFrame.minX) < 0.01
                && abs(frame.minY - display.cgFrame.minY) < 0.01
                && abs(frame.width - display.cgFrame.width) < 0.01
                && abs(frame.height - display.cgFrame.height) < 0.01
        }
    }

    /// Hit-tests the immutable trigger-time z-order. The list is already filtered to normal,
    /// user-sized, non-Camcord windows by the capture factory.
    func window(atCGPoint point: CGPoint) -> Window? {
        windows.first { $0.frame.contains(point) }
    }

    static func scaledImage(
        _ image: CGImage,
        pointSize: CGSize,
        resolutionScale: ResolutionScale
    ) -> CGImage? {
        guard pointSize.width >= 1, pointSize.height >= 1 else { return nil }
        let frame = CGRect(origin: .zero, size: pointSize)
        return FrozenDesktopSnapshot(
            displays: [.init(id: 0, cgFrame: frame, image: image)],
            windows: [],
            resolutionScale: resolutionScale
        ).crop(cgRect: frame)?.image
    }

    /// Crops a CG-space selection from the one frozen display, clamping at its edges.
    /// Native mode preserves the source bytes; one-X emits one pixel per point.
    func crop(cgRect requestedRect: CGRect, resolutionScale requestedScale: ResolutionScale? = nil) -> Crop? {
        guard requestedRect.width >= 1, requestedRect.height >= 1, let display = displays.first else {
            return nil
        }
        let target = requestedRect.intersection(display.cgFrame)
        guard !target.isNull, target.width >= 1, target.height >= 1 else { return nil }

        let mode = requestedScale ?? resolutionScale
        let outputScale: CGFloat = mode == .oneX ? 1 : max(display.scaleX, display.scaleY)
        let outputWidth = max(1, Int((target.width * outputScale).rounded()))
        let outputHeight = max(1, Int((target.height * outputScale).rounded()))

        // Preserve native source bytes and their color profile when no resampling is needed.
        if abs(display.scaleX - outputScale) < 0.001,
            abs(display.scaleY - outputScale) < 0.001,
            display.cgFrame.contains(target)
        {
            let sourceRect = pixelRect(
                globalRect: target,
                relativeTo: display.cgFrame,
                scaleX: display.scaleX,
                scaleY: display.scaleY
            )
            if Int(sourceRect.width) == outputWidth, Int(sourceRect.height) == outputHeight,
                let image = display.image.cropping(to: sourceRect)
            {
                return Crop(image: image, pointSize: target.size)
            }
        }

        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: outputWidth * 4,
            space: (display.image.colorSpace?.model == .rgb ? display.image.colorSpace : nil)
                ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        // Bitmap rows and the CG/SCK global coordinates used here are both top-to-bottom.

        let sourceRect = pixelRect(
            globalRect: target,
            relativeTo: display.cgFrame,
            scaleX: display.scaleX,
            scaleY: display.scaleY
        )
        guard let source = display.image.cropping(to: sourceRect) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))

        guard let image = context.makeImage() else { return nil }
        return Crop(image: image, pointSize: target.size)
    }

    private func pixelRect(
        globalRect: CGRect,
        relativeTo displayFrame: CGRect,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> CGRect {
        let minX = Int(((globalRect.minX - displayFrame.minX) * scaleX).rounded())
        let minY = Int(((globalRect.minY - displayFrame.minY) * scaleY).rounded())
        let maxX = Int(((globalRect.maxX - displayFrame.minX) * scaleX).rounded())
        let maxY = Int(((globalRect.maxY - displayFrame.minY) * scaleY).rounded())
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }
}
