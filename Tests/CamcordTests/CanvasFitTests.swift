import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import os
import ScreenCaptureKit
import Testing

@testable import Camcord

/// A resized window never leaves black in the file: the canvas is fixed, the live content is
/// re-centred aspect-fit, and a blurred backdrop of the same frame fills the rest. The two
/// cases below are the ones measured from ScreenCaptureKit on 2026-09-25.
@Suite("Canvas fit")
struct CanvasFitTests {
    private let canvas = CGSize(width: 1200, height: 964)

    @Test("a shrunk window (SCK: top-left, 1×) is centred full-height with backdrop either side")
    func shrunkWindow() {
        let fit = CanvasFit(canvas: canvas, contentRect: CGRect(x: 0, y: 0, width: 400, height: 482), scaleFactor: 2)
        #expect(fit.content == CGRect(x: 0, y: 0, width: 800, height: 964))
        #expect(fit.fitted == CGRect(x: 200, y: 0, width: 800, height: 964))
        #expect(!fit.isPassThrough)
        #expect(fit.backdrop.contains(CGRect(origin: .zero, size: canvas)))
    }

    @Test("a grown window (SCK: top-left, scaled 0.75) is centred full-width with backdrop above and below")
    func grownWindow() {
        let fit = CanvasFit(canvas: canvas, contentRect: CGRect(x: 0, y: 0, width: 600, height: 249), scaleFactor: 2)
        #expect(fit.content == CGRect(x: 0, y: 0, width: 1200, height: 498))
        #expect(fit.fitted == CGRect(x: 0, y: 233, width: 1200, height: 498))
        #expect(fit.backdrop.contains(CGRect(origin: .zero, size: canvas)))
    }

    @Test("fit is aspect-true, centred and inside the canvas; the backdrop always covers it", arguments: [
        CGRect(x: 0, y: 0, width: 300, height: 700),
        CGRect(x: 0, y: 0, width: 1200, height: 100),
        CGRect(x: 0, y: 0, width: 40, height: 40),
        CGRect(x: 10, y: 20, width: 900, height: 600),
    ])
    func invariants(content: CGRect) {
        let fit = CanvasFit(canvas: canvas, content: content)
        let bounds = CGRect(origin: .zero, size: canvas)
        #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(fit.fitted))
        #expect(abs(fit.fitted.midX - bounds.midX) < 0.01)
        #expect(abs(fit.fitted.midY - bounds.midY) < 0.01)
        #expect(abs(fit.fitted.width / fit.fitted.height - fit.content.width / fit.content.height) < 0.001)
        // Touches the canvas on at least one axis: aspect-FIT, not a floating stamp.
        #expect(abs(fit.fitted.width - canvas.width) < 0.01 || abs(fit.fitted.height - canvas.height) < 0.01)
        #expect(fit.backdrop.insetBy(dx: -0.01, dy: -0.01).contains(bounds))
    }

    @Test("a full frame is a pass-through, and a garbage rect falls back to the whole canvas")
    func passThroughAndGarbage() {
        #expect(CanvasFit(canvas: canvas, contentRect: CGRect(x: 0, y: 0, width: 600, height: 482), scaleFactor: 2).isPassThrough)
        #expect(CanvasFit(canvas: canvas, content: CGRect(x: 0, y: 0, width: 1199.6, height: 964)).isPassThrough)
        #expect(CanvasFit(canvas: canvas, content: .null).isPassThrough)
        #expect(CanvasFit(canvas: canvas, content: CGRect(x: 5000, y: 0, width: 10, height: 10)).isPassThrough)
        #expect(CanvasFit(canvas: canvas, contentRect: CGRect(x: 0, y: 0, width: 600, height: 482), scaleFactor: .nan).content
            == CGRect(x: 0, y: 0, width: 600, height: 482))
        // Core Image space is bottom-left: the top 100 rows are the highest y.
        let fit = CanvasFit(canvas: canvas, content: CGRect(x: 0, y: 0, width: 600, height: 100))
        #expect(fit.flipped(CGRect(x: 0, y: 0, width: 600, height: 100)) == CGRect(x: 0, y: 864, width: 600, height: 100))
    }

    @Test("canvas setting: match window keeps the window, a ratio takes the window's long side, capped to the display")
    func canvasSizes() {
        let display = CGSize(width: 3024, height: 1964)
        #expect(CanvasAspect.matchWindow.canvasSize(window: CGSize(width: 1601, height: 1203), display: display) == (1600, 1202))
        #expect(CanvasAspect.wide16x9.canvasSize(window: CGSize(width: 1600, height: 1200), display: display) == (1600, 900))
        #expect(CanvasAspect.wide16x9.canvasSize(window: CGSize(width: 900, height: 1600), display: display) == (1600, 900))
        #expect(CanvasAspect.square.canvasSize(window: CGSize(width: 1600, height: 1200), display: display) == (1600, 1600))
        #expect(CanvasAspect.classic4x3.canvasSize(window: CGSize(width: 800, height: 1200), display: display) == (1200, 900))
        // 9:16 at a 2000 px long side is taller than the display: scaled down to fit it.
        let tall = CanvasAspect.tall9x16.canvasSize(window: CGSize(width: 3000, height: 2000), display: display)
        #expect(tall.height <= 1964 && tall.width <= 3024)
        #expect(abs(Double(tall.width) / Double(tall.height) - 9.0 / 16.0) < 0.01)
        #expect(tall.width % 2 == 0 && tall.height % 2 == 0)
        // Every ratio canvas has its ratio.
        for aspect in CanvasAspect.allCases {
            guard let ratio = aspect.ratio else { continue }
            let size = aspect.canvasSize(window: CGSize(width: 1500, height: 1100), display: display)
            #expect(abs(CGFloat(size.width) / CGFloat(size.height) - ratio) < 0.01)
            #expect(max(size.width, size.height) == 1500)
        }
    }

    @Test("the canvas setting persists, defaults to match window and survives old or odd settings")
    func persistence() throws {
        #expect(RecordingSettings().canvasAspect == .matchWindow)
        let legacy = try JSONDecoder().decode(RecordingSettings.self, from: Data("{\"fps\":30}".utf8))
        #expect(legacy.canvasAspect == .matchWindow)
        let odd = try JSONDecoder().decode(RecordingSettings.self, from: Data("{\"canvasAspect\":\"cinemascope\"}".utf8))
        #expect(odd.canvasAspect == .matchWindow)
        var chosen = RecordingSettings()
        chosen.canvasAspect = .wide16x9
        let decoded = try JSONDecoder().decode(RecordingSettings.self, from: JSONEncoder().encode(chosen))
        #expect(decoded.canvasAspect == .wide16x9)
        let merged = chosen.merging(from: RecordingSettings(), into: RecordingSettings(fps: 30))
        #expect(merged.canvasAspect == .wide16x9)
        #expect(merged.fps == 30)
    }

    // MARK: - Pixels

    @Test("the file has no pure-black edge rows or columns after a shrink or a grow")
    func noBlackEdges() throws {
        let compositor = CameraCompositor(context: CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false]))
        // A 240×180 canvas; SCK drew the live content top-left and left the rest black.
        for content in [CGRect(x: 0, y: 0, width: 120, height: 180), CGRect(x: 0, y: 0, width: 240, height: 90)] {
            let buffer = makeBuffer(width: 240, height: 180) { x, y in
                content.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
                    ? (UInt8(40 + x % 60), 150, UInt8(90 + y % 80), 255) : (0, 0, 0, 255)
            }
            let fit = CanvasFit(canvas: CGSize(width: 240, height: 180), content: content)
            let output = try #require(CMSampleBufferGetImageBuffer(
                try compositor.composite(screen: sample(buffer), camera: nil, options: CameraOptions(), fit: fit)
            ))
            let edges = blackEdgeLines(output)
            #expect(edges == 0, "content \(content): \(edges) pure-black edge lines")
            // The live content is in the middle now.
            let middle = pixel(output, x: 120, y: 90)
            #expect(middle.g > 120)
        }
    }

    @Test("with a fit, the camera sits in the fitted content, where the on-screen tile is")
    func cameraFollowsContent() throws {
        let compositor = CameraCompositor(context: CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false]))
        let content = CGRect(x: 0, y: 0, width: 120, height: 180)   // a shrunk, tall window
        let buffer = makeBuffer(width: 240, height: 180) { x, y in
            content.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) ? (200, 200, 200, 255) : (0, 0, 0, 255)
        }
        let camera = makeBuffer(width: 32, height: 18) { _, _ in (10, 220, 10, 255) }
        let fit = CanvasFit(canvas: CGSize(width: 240, height: 180), content: content)
        let options = CameraOptions(enabled: true, corner: .bottomRight, widthFraction: 0.4, mirrored: false)
        let output = try #require(CMSampleBufferGetImageBuffer(
            try compositor.composite(screen: sample(buffer), camera: camera, options: options, fit: fit)
        ))
        // In Core Image space, the fitted content spans x 60…180; the tile is in ITS corner.
        let fitted = fit.flipped(fit.fitted)
        let tile = options.rect(in: fitted.size).offsetBy(dx: fitted.minX, dy: fitted.minY)
        #expect(fitted.contains(tile))
        let inTile = pixel(output, x: Int(tile.midX), y: 179 - Int(tile.midY))
        #expect(inTile.g > 170 && inTile.r < 80)
        // Where a canvas-relative tile would be (and the fitted one is not) is backdrop.
        let canvasCorner = pixel(output, x: 220, y: 150)
        #expect(!(canvasCorner.g > 170 && canvasCorner.r < 80))
    }

    @Test("the writer reads the fit from SCK's frame info, and a full frame costs nothing")
    func readsFrameInfo() throws {
        let buffer = makeBuffer(width: 1200, height: 964) { _, _ in (0, 0, 0, 255) }
        let shrunk = try sample(buffer)
        attach(shrunk, SCStreamFrameInfo.contentRect.rawValue,
               CGRect(x: 0, y: 0, width: 400, height: 482).dictionaryRepresentation)
        attach(shrunk, SCStreamFrameInfo.scaleFactor.rawValue, 2.0 as NSNumber)
        let fit = try #require(StreamWriter.canvasFit(of: shrunk))
        #expect(fit.content == CGRect(x: 0, y: 0, width: 800, height: 964))

        let full = try sample(buffer)
        attach(full, SCStreamFrameInfo.contentRect.rawValue,
               CGRect(x: 0, y: 0, width: 600, height: 482).dictionaryRepresentation)
        attach(full, SCStreamFrameInfo.scaleFactor.rawValue, 2.0 as NSNumber)
        #expect(StreamWriter.canvasFit(of: full) == nil)
        #expect(StreamWriter.canvasFit(of: try sample(buffer)) == nil)
    }

    @Test("a window recording's writer re-centres every frame; other targets pass frames through untouched")
    func writerFitsWindowFrames() async throws {
        for fits in [true, false] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-canvas-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try StreamWriter(outputURL: url, container: .mov, codec: .h264, bitrateMbps: 2,
                                          pixelWidth: 240, pixelHeight: 180, frameDuration: CMTime(value: 1, timescale: 30),
                                          dynamicRange: .sdr, includeSystemAudio: false, includeMicrophone: false,
                                          fitsWindowContent: fits)
            let staged = OSAllocatedUnfairLock<PixelBufferBox?>(initialState: nil)
            writer.stageSink = { frame in staged.withLock { $0 = frame } }
            let content = CGRect(x: 0, y: 0, width: 120, height: 180)
            let frame = try sample(makeBuffer(width: 240, height: 180) { x, y in
                content.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) ? (90, 160, 60, 255) : (0, 0, 0, 255)
            })
            attach(frame, SCStreamFrameInfo.status.rawValue, NSNumber(value: SCFrameStatus.complete.rawValue))
            attach(frame, SCStreamFrameInfo.contentRect.rawValue, content.dictionaryRepresentation)
            attach(frame, SCStreamFrameInfo.scaleFactor.rawValue, 1.0 as NSNumber)
            writer.consume(frame, of: .screen)
            let output = try #require(staged.withLock { $0 }).value
            if fits {
                #expect(blackEdgeLines(output) == 0)
            } else {
                #expect(blackEdgeLines(output) > 0)
            }
            writer.markFinished(atHostTime: nil)
            _ = try await writer.finishWriting()
        }
    }
}

// MARK: - Helpers

private struct RGB { let r: UInt8, g: UInt8, b: UInt8 }

/// Rows and columns along the four edges whose every pixel is pure black.
private func blackEdgeLines(_ buffer: CVPixelBuffer) -> Int {
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    func isBlack(_ x: Int, _ y: Int) -> Bool { let p = pixel(buffer, x: x, y: y); return p.r == 0 && p.g == 0 && p.b == 0 }
    var lines = 0
    for y in [0, 1, height - 2, height - 1] where (0..<width).allSatisfy({ isBlack($0, y) }) { lines += 1 }
    for x in [0, 1, width - 2, width - 1] where (0..<height).allSatisfy({ isBlack(x, $0) }) { lines += 1 }
    return lines
}

/// Top-left-origin pixel read.
private func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> RGB {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
    return RGB(r: base[offset + 2], g: base[offset + 1], b: base[offset])
}

private func makeBuffer(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer {
    var result: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                     [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                                     &result) == kCVReturnSuccess)
    let buffer = result!
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in 0..<width {
            let value = pixel(x, y)   // (b, g, r, a)
            let offset = y * rowBytes + x * 4
            base[offset] = value.0; base[offset + 1] = value.1; base[offset + 2] = value.2; base[offset + 3] = value.3
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    // Tagged like SCK's buffers, so the render writes sRGB values instead of linear ones.
    CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
    return buffer
}

private func sample(_ buffer: CVPixelBuffer) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                    presentationTimeStamp: CMTime(value: 3, timescale: 30), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                             formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
    return try #require(sample)
}

private func attach(_ sample: CMSampleBuffer, _ key: String, _ value: AnyObject) {
    let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)!
    let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
    CFDictionarySetValue(dictionary, Unmanaged.passUnretained(key as NSString).toOpaque(),
                         Unmanaged.passUnretained(value).toOpaque())
}
