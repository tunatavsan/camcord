import CoreGraphics
import CoreText
import Foundation
import ImageIO
import os

final class StudioRasterTicket: Sendable {
    private let live = OSAllocatedUnfairLock(initialState: true)
    func cancel() { live.withLock { $0 = false } }
    var isCurrent: Bool { live.withLock { $0 } }
}

/// CoreText and ImageIO work is confined to one worker queue. The queue and immutable
/// limits are the only state: this Sendable wrapper never exposes its contexts.
final class StudioLayerRasterizer: Sendable {
    private let queue = DispatchQueue(label: "dev.tavsan.camcord.studio.layers", qos: .userInitiated)
    let limits: StudioLayerLimits

    init(limits: StudioLayerLimits = .init()) { self.limits = limits }

    func importImage(from url: URL) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [limits] in
                do {
                    guard url.isFileURL else { throw StudioIssue.invalidImage }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true, let size = values.fileSize,
                          size > 0, size <= limits.maximumEncodedBytes else { throw StudioIssue.imageTooLarge }
                    let (readBound, overflow) = limits.maximumEncodedBytes.addingReportingOverflow(1)
                    guard !overflow, readBound > 0 else { throw StudioIssue.imageTooLarge }
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let data = try file.read(upToCount: readBound) ?? Data()
                    guard data.count <= limits.maximumEncodedBytes else { throw StudioIssue.imageTooLarge }
                    continuation.resume(returning: try Self.decode(data, limits: limits))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func snapshot(layers: [StudioLayer], assets: [UUID: CGImage],
                  shouldContinue: @escaping @Sendable () -> Bool = { true }) async throws -> StudioLayerSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [limits] in
                do {
                    guard shouldContinue() else { throw CancellationError() }
                    guard layers.count <= limits.maximumLayers else { throw StudioIssue.layerLimit }
                    var rasters: [StudioRasterLayer] = []
                    var bytes = 0
                    for rawLayer in layers {
                        guard shouldContinue() else { throw CancellationError() }
                        let layer = rawLayer.resolved()
                        guard layer.isVisible, layer.opacity > 0, layer.rect.width > 0, layer.rect.height > 0 else { continue }
                        let image: CGImage
                        if layer.kind == .text {
                            image = try Self.text(layer.text, style: layer.textStyle, rect: layer.rect, limits: limits)
                        } else {
                            guard let asset = assets[layer.id] else { throw StudioIssue.invalidImage }
                            image = asset
                        }
                        let (size, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
                        guard !overflow, size <= limits.maximumSnapshotBytes - bytes else { throw StudioIssue.imageTooLarge }
                        bytes += size
                        rasters.append(StudioRasterLayer(id: layer.id, image: image, rect: layer.rect, opacity: layer.opacity,
                                                         alignment: layer.kind == .text ? .topLeading : .center))
                    }
                    continuation.resume(returning: StudioLayerSnapshot(layers: rasters, maximumLayers: limits.maximumLayers,
                                                                       maximumBytes: limits.maximumSnapshotBytes))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func decode(_ data: Data, limits: StudioLayerLimits) throws -> CGImage {
        guard !data.isEmpty, data.count <= limits.maximumEncodedBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber else { throw StudioIssue.invalidImage }
        let w = width.int64Value, h = height.int64Value
        let (pixels, overflow) = w.multipliedReportingOverflow(by: h)
        guard w > 0, h > 0, !overflow, pixels <= limits.maximumImagePixels else { throw StudioIssue.imageTooLarge }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: max(1, limits.maximumRasterDimension),
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw StudioIssue.invalidImage }
        return image
    }

    private static func text(_ text: String, style: StudioTextStyle, rect: CGRect,
                             limits: StudioLayerLimits) throws -> CGImage {
        // Font size uses reference pixels in a bounded 1920×1080 layout. Changing
        // bounds reflows text here; the shared compositor fits it uniformly so
        // glyphs keep their proportions on square, tall and window canvases.
        guard text.count <= limits.maximumTextCharacters else { throw StudioIssue.textTooLong }
        let width = max(2, min(limits.maximumRasterDimension, Int((1920 * rect.width).rounded(.up))))
        let height = max(2, min(limits.maximumRasterDimension, Int((1080 * rect.height).rounded(.up))))
        let (bytes, overflow) = (width * 4).multipliedReportingOverflow(by: height)
        guard !overflow, bytes <= limits.maximumSnapshotBytes,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw StudioIssue.imageTooLarge }
        let style = style.resolved()
        let color = CGColor(colorSpace: colorSpace, components: [style.red, style.green, style.blue, style.alpha])!
        let font = CTFontCreateWithName((style.bold ? "Helvetica-Bold" : "Helvetica") as CFString,
                                        style.fontSize, nil)
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let setter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        guard let image = context.makeImage() else { throw StudioIssue.invalidImage }
        return image
    }
}
