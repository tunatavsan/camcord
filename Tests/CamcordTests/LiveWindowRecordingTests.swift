import AppKit
import AVFoundation
import CoreImage
import QuartzCore
import Foundation
@preconcurrency import ScreenCaptureKit
import Testing

@testable import Camcord

/// A REAL window recording through `RecordingEngine`: the test opens its own window, records it
/// while shrinking it from 1200×900 to 800×400 and growing it back, then reads the file. Off by
/// default — it needs Screen Recording for the test runner and takes ~10 s per canvas:
/// `CAMCORD_LIVE_RECORDING=1 swift test --filter LiveWindowRecordingTests`.
/// Writes its measurements as JSON to `$CAMCORD_LIVE_REPORT` when set.
@MainActor
@Suite("Live window recording", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CAMCORD_LIVE_RECORDING"] == "1"))
struct LiveWindowRecordingTests {
    struct Report: Codable {
        var canvas: String
        var naturalSize: [Int]
        var frames: Int
        var seconds: Double
        var fps: Double
        var sampledFrames: Int
        var framesWithBlackEdge: Int
        var blackEdgeLines: Int
    }

    /// `resizes: false` is the control: the same window and settings, never resized, so every
    /// frame passes through untouched — the source's own frame rate on this machine.
    @Test("a resized window leaves no black edge in the file, at the recording's frame rate",
          arguments: [(CanvasAspect.matchWindow, true), (.wide16x9, true), (.matchWindow, false)])
    func resizeLeavesNoBlack(canvas: CanvasAspect, resizes: Bool) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1200, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "camcord-live-recording-test"
        window.isReleasedWhenClosed = false
        let view = GradientView(frame: window.contentLayoutRect)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // Something changes every frame, so ScreenCaptureKit keeps delivering.
        let ticker = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { view.phase += 0.02; view.needsDisplay = true }
        }
        RunLoop.main.add(ticker, forMode: .common)
        defer { ticker.invalidate() }
        try await Task.sleep(for: .milliseconds(500))

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let scWindow = try #require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })

        var settings = RecordingSettings()
        settings.systemAudio = false
        settings.microphone = false
        settings.camera.enabled = false
        settings.dndEnabled = false
        settings.countdownEnabled = false
        settings.fps = 60
        settings.canvasAspect = canvas
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("camcord-live-\(canvas.rawValue)-\(UUID().uuidString).mov")
        let engine = RecordingEngine(diagnostics: { _ in })
        try await engine.start(target: .window(scWindow), settings: settings, outputURL: url)

        func animate(to size: NSSize, seconds: Double) async throws {
            let start = window.contentLayoutRect.size
            let steps = Int(seconds * 60)
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                window.setContentSize(NSSize(width: start.width + (size.width - start.width) * t,
                                             height: start.height + (size.height - start.height) * t))
                try await Task.sleep(for: .milliseconds(16))
            }
        }
        try await Task.sleep(for: .seconds(1))
        try await animate(to: NSSize(width: resizes ? 800 : 1200, height: resizes ? 400 : 900), seconds: 1)
        try await Task.sleep(for: .seconds(1))
        try await animate(to: NSSize(width: 1200, height: 900), seconds: 1)
        try await Task.sleep(for: .seconds(1))
        let finished = try await engine.stop()
        defer { try? FileManager.default.removeItem(at: finished) }

        let asset = AVURLAsset(url: finished)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let natural = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        let frames = try countFrames(asset: asset, track: track)
        let (sampled, withBlack, lines) = try await blackEdges(asset: asset, duration: duration)

        let report = Report(canvas: canvas.rawValue + (resizes ? "" : "-control"), naturalSize: [Int(natural.width), Int(natural.height)],
                            frames: frames, seconds: duration, fps: Double(frames) / duration,
                            sampledFrames: sampled, framesWithBlackEdge: withBlack, blackEdgeLines: lines)
        if let path = ProcessInfo.processInfo.environment["CAMCORD_LIVE_REPORT"] {
            let file = URL(fileURLWithPath: path).appendingPathComponent("live-\(report.canvas).json")
            try JSONEncoder().encode(report).write(to: file)
        }
        #expect(withBlack == 0, "\(lines) black edge lines in \(withBlack) of \(sampled) sampled frames")
        if let ratio = canvas.ratio {
            #expect(abs(natural.width / natural.height - ratio) < 0.01)
        }
    }

    /// The fit's own cost at 4K on this Mac's GPU, in both writer pixel formats (8-bit BGRA
    /// and HEVC 10-bit's biplanar YUV). 60 fps leaves 16.7 ms per frame for everything.
    @Test("the 4K canvas fit renders well inside a 60 fps frame budget",
          arguments: [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    func fitCostAt4K(pixelFormat: OSType) throws {
        let compositor = CameraCompositor()
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 3840, 2160, pixelFormat,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
        let pixels = try #require(buffer)
        CVBufferSetAttachment(pixels, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                 formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        let screen = try #require(sample)
        let fit = CanvasFit(canvas: CGSize(width: 3840, height: 2160), content: CGRect(x: 0, y: 0, width: 2560, height: 2160))
        _ = try compositor.composite(screen: screen, camera: nil, options: CameraOptions(), fit: fit)   // warm-up
        let frames = 120
        let start = CACurrentMediaTime()
        for _ in 0..<frames {
            _ = try compositor.composite(screen: screen, camera: nil, options: CameraOptions(), fit: fit)
        }
        let perFrame = (CACurrentMediaTime() - start) / Double(frames) * 1000
        if let path = ProcessInfo.processInfo.environment["CAMCORD_LIVE_REPORT"] {
            let file = URL(fileURLWithPath: path).appendingPathComponent("fit-cost-\(pixelFormat).txt")
            try String(format: "%.2f ms/frame", perFrame).write(to: file, atomically: true, encoding: .utf8)
        }
        #expect(perFrame < 8, "\(perFrame) ms per 4K frame")
    }

    /// The owner's own camera, through the real `CameraCapture`, on Auto.
    @Test("the built-in camera starts on Auto and delivers frames of the format it reports")
    func builtInCameraOnAuto() async throws {
        let device = try #require(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified))
        let capture = CameraCapture()
        try await capture.start(deviceID: device.uniqueID, format: .auto)
        try await capture.waitForFirstFrame()
        let active = try #require(capture.activeFormat)
        let frame = try #require(capture.latestFrame())
        let size = (CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame))
        await capture.stop()
        if let path = ProcessInfo.processInfo.environment["CAMCORD_LIVE_REPORT"] {
            try "\(device.localizedName): \(active.label), frames \(size.0)x\(size.1)"
                .write(to: URL(fileURLWithPath: path).appendingPathComponent("camera-auto.txt"), atomically: true, encoding: .utf8)
        }
        #expect(active.width >= active.height)
        #expect(size.0 == active.width && size.1 == active.height)
    }

    private func countFrames(asset: AVAsset, track: AVAssetTrack) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { count += 1 }
        }
        return count
    }

    /// Decodes a frame every 50 ms and counts, along each edge, the outer two rows/columns
    /// that are entirely black (every channel ≤ 4 — codec noise on a true black band).
    nonisolated private func blackEdges(asset: AVAsset, duration: Double) async throws -> (sampled: Int, withBlack: Int, lines: Int) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var sampled = 0, withBlack = 0, lines = 0
        var time = 0.05
        while time < duration - 0.05 {
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let count = blackEdgeLines(image)
            sampled += 1
            if count > 0 { withBlack += 1; lines += count }
            time += 0.05
        }
        return (sampled, withBlack, lines)
    }

    nonisolated private func blackEdgeLines(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func black(_ x: Int, _ y: Int) -> Bool {
            let o = (y * width + x) * 4
            return data[o] <= 4 && data[o + 1] <= 4 && data[o + 2] <= 4
        }
        var lines = 0
        for y in [0, 1, height - 2, height - 1] where (0..<width).allSatisfy({ black($0, y) }) { lines += 1 }
        for x in [0, 1, width - 2, width - 1] where (0..<height).allSatisfy({ black(x, $0) }) { lines += 1 }
        return lines
    }
}

/// A moving diagonal gradient: never black, always changing.
private final class GradientView: NSView {
    var phase: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        let hue = phase.truncatingRemainder(dividingBy: 1)
        NSGradient(starting: NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1),
                   ending: NSColor(hue: (hue + 0.4).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.7, alpha: 1))?
            .draw(in: bounds, angle: 35)
    }
}
