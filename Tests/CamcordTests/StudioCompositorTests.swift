import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Testing
import os
@testable import Camcord

@Suite("Studio raster and media composition")
struct StudioCompositorTests {
    @Test("square logos fit uniformly inside a wide destination without stretching")
    func logoAspectFit() throws {
        let sample = try StudioPixels.sample(buffer: StudioPixels.buffer(width: 200, height: 100, color: (0, 0, 0, 255)))
        let snapshot = StudioLayerSnapshot(layers: [.init(id: UUID(), image: StudioPixels.image(color: (255, 0, 0, 255)),
                                                          rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), opacity: 1)])
        let output = try StudioPixels.compositor().composite(screen: sample, camera: nil, options: .init(), layers: snapshot)
        let buffer = try #require(CMSampleBufferGetImageBuffer(output))
        let bounds = try #require(StudioPixels.redBounds(buffer))
        #expect(abs(bounds.width - bounds.height) <= 1)
        #expect(abs(bounds.midX - 100) <= 1 && abs(bounds.midY - 50) <= 1)
        #expect(bounds.width >= 79 && bounds.width <= 81)
    }

    @Test("real CoreText glyph proportions survive a tall destination canvas")
    func textAspectFit() async throws {
        let text = StudioLayer(kind: .text, name: "H", text: "H", rect: CGRect(x: 0.1, y: 0.1, width: 0.75, height: 0.75),
                               textStyle: .init(fontSize: 256, bold: true, red: 1, green: 0, blue: 0, alpha: 1))
        let snapshot = try await StudioLayerRasterizer().snapshot(layers: [text], assets: [:])
        let raster = try #require(snapshot.layers.first)
        #expect(raster.alignment == .topLeading)
        let original = try #require(StudioPixels.alphaBounds(raster.image))
        let sample = try StudioPixels.sample(buffer: StudioPixels.buffer(width: 120, height: 240, color: (0, 0, 0, 255)))
        let output = try StudioPixels.compositor().composite(screen: sample, camera: nil, options: .init(), layers: snapshot)
        let buffer = try #require(CMSampleBufferGetImageBuffer(output))
        let bounds = try #require(StudioPixels.redBounds(buffer))
        #expect(abs(bounds.width / bounds.height - original.width / original.height) < 0.2)
        #expect(bounds.height < 20)
    }

    @Test("idle window preview uses the actual fixed destination canvas and shared layer fit")
    func idleDestinationCanvas() async throws {
        let sample = try StudioPixels.sample(buffer: StudioPixels.buffer(width: 160, height: 90, color: (0, 0, 255, 255)))
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true))
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        let key = SCStreamFrameInfo.contentRect.rawValue as NSString
        let rect = CGRect(x: 0, y: 0, width: 96, height: 60).dictionaryRepresentation
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(rect).toOpaque())
        let image = try #require(await StudioIdlePreviewRenderer().render(.init(sample: sample), camera: nil, options: .init(),
                                                                         layers: .empty, fitsWindow: true))
        #expect(image.width == 160 && image.height == 90)
        let fit = try #require(StreamWriter.canvasFit(of: sample))
        #expect(fit.canvas == CGSize(width: 160, height: 90))
        #expect(fit.content.size == CGSize(width: 96, height: 60))
    }
    @MainActor @Test("an engine retains a stage handler subscribed before writer creation")
    func stageBeforeWriter() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-stage-pending-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = RecordingEngine()
        let frames = OSAllocatedUnfairLock(initialState: 0)
        engine.setStageSink { _ in frames.withLock { $0 += 1 } }
        let writer = try StreamWriter(outputURL: url, container: .mov, codec: .h264, bitrateMbps: 1,
                                      pixelWidth: 80, pixelHeight: 48, frameDuration: CMTime(value: 1, timescale: 30),
                                      dynamicRange: .sdr, includeSystemAudio: false, includeMicrophone: false)
        engine.configurePreparedWriterStudioState(writer)
        writer.consume(try StudioPixels.sample(buffer: StudioPixels.buffer(width: 80, height: 48, color: (0, 0, 255, 255))), of: .screen)
        #expect(frames.withLock { $0 } == 1)
        writer.markFinished(atHostTime: nil)
        _ = try await writer.finishWriting()
    }
    @Test("writer stage camera bounds describe the accepted fitted output or the actual raw fallback", arguments: [false, true])
    func stageCameraContentMetadata(failsFit: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-stage-bounds-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = StudioPixels.buffer(width: 80, height: 48, color: (0, 0, 255, 255))
        let sample = try StudioPixels.sample(buffer: source)
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true))
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        let key = SCStreamFrameInfo.contentRect.rawValue as NSString
        let content = CGRect(x: 0, y: 0, width: 40, height: 40).dictionaryRepresentation
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(content).toOpaque())
        let compositor = CameraCompositor(context: CIContext(options: [.useSoftwareRenderer: true]), fitPreflight: {
            if failsFit { throw CameraCompositorError.filterUnavailable }
        })
        let writer = try StreamWriter(outputURL: url, container: .mov, codec: .h264, bitrateMbps: 1,
                                      pixelWidth: 80, pixelHeight: 48, frameDuration: CMTime(value: 1, timescale: 30),
                                      dynamicRange: .sdr, includeSystemAudio: false, includeMicrophone: false,
                                      fitsWindowContent: true, compositor: compositor)
        let stage = OSAllocatedUnfairLock<PixelBufferBox?>(initialState: nil)
        writer.stageSink = { box in stage.withLock { $0 = box } }
        writer.consume(sample, of: .screen)
        let published = try #require(stage.withLock { $0 })
        #expect(published.cameraContentRect == (failsFit ? CGRect(x: 0, y: 0, width: 80, height: 48)
                                                      : CGRect(x: 16, y: 0, width: 48, height: 48)))
        #expect((published.value === source) == failsFit)
        writer.markFinished(atHostTime: nil)
        _ = try await writer.finishWriting()
    }
    @Test("normalized top-left layers paint each destination corner", arguments: 0..<4)
    func destinationCorners(corner: Int) throws {
        let screen = try StudioPixels.sample(buffer: StudioPixels.buffer(width: 80, height: 40, color: (0, 0, 255, 255)))
        let x = corner % 2 == 0 ? 0.0 : 0.75, y = corner < 2 ? 0.0 : 0.75
        let image = StudioPixels.image(color: (255, 0, 0, 255))
        let snapshot = StudioLayerSnapshot(layers: [.init(id: UUID(), image: image,
                                                          rect: CGRect(x: x, y: y, width: 0.25, height: 0.25), opacity: 1)])
        let output = try StudioPixels.compositor().composite(screen: screen, camera: nil, options: .init(), layers: snapshot)
        let pixels = try #require(CMSampleBufferGetImageBuffer(output))
        let point = CGPoint(x: (x + 0.125) * 80, y: (y + 0.125) * 40)
        #expect(StudioPixels.pixel(pixels, topLeft: point).r > 240)
        let opposite = CGPoint(x: (1 - x - 0.125) * 80, y: (1 - y - 0.125) * 40)
        #expect(StudioPixels.pixel(pixels, topLeft: opposite).b > 240)
    }

    @Test("layers compose after window fit and every camera position", arguments: [false, true])
    func afterFitAndCamera(fitted: Bool) throws {
        let size = CGSize(width: 200, height: 120)
        let screen = try StudioPixels.sample(buffer: StudioPixels.buffer(width: 200, height: 120, color: (0, 0, 255, 255)))
        let camera = StudioPixels.buffer(width: 40, height: 20, color: (0, 255, 0, 255))
        let fit = fitted ? CanvasFit(canvas: size, content: CGRect(x: 0, y: 0, width: 140, height: 100)) : nil
        let content = fit.map { $0.flipped($0.fitted) } ?? CGRect(origin: .zero, size: size)
        for corner in CameraCorner.allCases {
            let options = CameraOptions(enabled: true, corner: corner, widthFraction: 0.3)
            let cameraRect = options.rect(in: content.size).offsetBy(dx: content.minX, dy: content.minY)
            let normalized = CGRect(x: cameraRect.minX / size.width, y: 1 - cameraRect.maxY / size.height,
                                    width: cameraRect.width / size.width, height: cameraRect.height / size.height)
            let layers = StudioLayerSnapshot(layers: [.init(id: UUID(), image: StudioPixels.image(color: (255, 0, 0, 255)),
                                                            rect: normalized, opacity: 1)])
            let output = try StudioPixels.compositor().composite(screen: screen, camera: camera, options: options,
                                                                 fit: fit, layers: layers)
            let buffer = try #require(CMSampleBufferGetImageBuffer(output))
            let center = CGPoint(x: cameraRect.midX, y: size.height - cameraRect.midY)
            let color = StudioPixels.pixel(buffer, topLeft: center)
            #expect(color.r > 240 && color.g < 10 && color.b < 10)
        }
    }

    @Test("real layer order and opacity retain media timing and exact empty identity")
    func opacityOrderAndMediaContract() throws {
        let sample = try StudioPixels.sample(buffer: StudioPixels.buffer(width: 80, height: 40, color: (0, 0, 0, 255)))
        let compositor = StudioPixels.compositor()
        #expect(try compositor.composite(screen: sample, camera: nil, options: .init(), layers: .empty) === sample)
        let rect = CGRect(x: 0, y: 0, width: 0.25, height: 0.25)
        let layers = StudioLayerSnapshot(layers: [
            .init(id: UUID(), image: StudioPixels.image(color: (255, 0, 0, 255)), rect: rect, opacity: 1),
            .init(id: UUID(), image: StudioPixels.image(color: (0, 0, 255, 255)), rect: rect, opacity: 0.5),
        ])
        let output = try compositor.composite(screen: sample, camera: nil, options: .init(), layers: layers)
        let buffer = try #require(CMSampleBufferGetImageBuffer(output))
        let p = StudioPixels.pixel(buffer, topLeft: CGPoint(x: 5, y: 5))
        #expect(p.r > 110 && p.r < 145 && p.b > 110 && p.b < 145)
        #expect(CMSampleBufferGetPresentationTimeStamp(output) == CMSampleBufferGetPresentationTimeStamp(sample))
        #expect(CMSampleBufferGetDuration(output) == CMSampleBufferGetDuration(sample))
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetWidth(buffer) == 80 && CVPixelBufferGetHeight(buffer) == 40)
    }

    @Test("a real encoded file contains the current layer snapshot")
    func encodedLayers() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-studio-layer-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try StreamWriter(outputURL: url, container: .mov, codec: .h264, bitrateMbps: 1,
                                      pixelWidth: 80, pixelHeight: 48, frameDuration: CMTime(value: 1, timescale: 30),
                                      dynamicRange: .sdr, includeSystemAudio: false, includeMicrophone: false)
        writer.updateStudioLayers(.init(layers: [.init(id: UUID(), image: StudioPixels.image(color: (255, 0, 0, 255)),
                                                        rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), opacity: 1)]))
        for index in 0..<3 {
            writer.consume(try StudioPixels.sample(buffer: StudioPixels.buffer(width: 80, height: 48, color: (0, 0, 255, 255)),
                                                   pts: CMTime(value: Int64(index), timescale: 30)), of: .screen)
            try await Task.sleep(for: .milliseconds(35))
        }
        writer.markFinished(atHostTime: nil)
        _ = try await writer.finishWriting()
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        #expect(reader.startReading())
        let sample = try #require(output.copyNextSampleBuffer())
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        let logo = StudioPixels.pixel(buffer, topLeft: CGPoint(x: 10, y: 10))
        let screen = StudioPixels.pixel(buffer, topLeft: CGPoint(x: 60, y: 36))
        #expect(logo.r > 180 && logo.b < 70)
        #expect(screen.b > 180 && screen.r < 70)
        reader.cancelReading()
    }
}

private enum StudioPixels {
    static func redBounds(_ buffer: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        return bounds(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) { x, y in
            let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            return bytes[offset + 2] > 80 && bytes[offset] < 30 && bytes[offset + 1] < 30
        }
    }
    static func alphaBounds(_ image: CGImage) -> CGRect? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        return bounds(width: image.width, height: image.height) { x, y in bytes[y * image.bytesPerRow + x * 4 + 3] > 80 }
    }
    private static func bounds(width: Int, height: Int, contains: (Int, Int) -> Bool) -> CGRect? {
        var left = width, top = height, right = -1, bottom = -1
        for y in 0..<height {
            for x in 0..<width where contains(x, y) {
                left = min(left, x); top = min(top, y); right = max(right, x); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
    static func compositor() -> CameraCompositor {
        CameraCompositor(context: CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false]))
    }
    static func image(color: (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        let data = Data(Array(repeating: [color.0, color.1, color.2, color.3], count: 16).flatMap { $0 })
        return CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: .init(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func buffer(width: Int, height: Int, color: (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                       [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        let result = buffer!
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let base = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * CVPixelBufferGetBytesPerRow(result) + x * 4
                base[offset] = color.2; base[offset + 1] = color.1; base[offset + 2] = color.0; base[offset + 3] = color.3
            }
        }
        return result
    }
    static func pixel(_ buffer: CVPixelBuffer, topLeft point: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let offset = Int(point.y) * CVPixelBufferGetBytesPerRow(buffer) + Int(point.x) * 4
        let p = CVPixelBufferGetBaseAddress(buffer)!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        return (p[2], p[1], p[0])
    }
    static func sample(buffer: CVPixelBuffer, pts: CMTime = CMTime(value: 123, timescale: 30)) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: try #require(format),
                                                        sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        let result = try #require(sample)
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true))
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        let key = SCStreamFrameInfo.status.rawValue as NSString, value = NSNumber(value: SCFrameStatus.complete.rawValue)
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(value).toOpaque())
        return result
    }
}
