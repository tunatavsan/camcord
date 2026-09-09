import AVFoundation
import AppKit
import SwiftUI

/// Headless design harness: renders the panel's visual states to PNG files so the
/// design can be inspected and iterated without launching the app and clicking.
/// Invoked via `Camcord --render-panel <dir>` (see main.swift).
@MainActor
enum PanelPreviewRenderer {
    static func renderAll(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let fixtureRecording = makeFixtureRecording(in: directory)
        defer {
            if let fixtureRecording { try? FileManager.default.removeItem(at: fixtureRecording) }
        }

        enum Kind { case state(RecordingController.UIState, String?), finishing, finished }
        let states: [(name: String, kind: Kind)] = [
            // Initial state deliberately has no discovered files: both stable destination
            // buttons must still render before the asynchronous library scan completes.
            ("panel-idle-empty-library", .state(.idle, nil)),
            ("panel-recording", .state(.recording, "1:07")),
            ("panel-paused", .state(.paused, "1:07")),
            ("panel-finishing", .finishing),
            ("panel-finished", .finished),
        ]

        for scheme in ["dark", "light"] {
            for entry in states {
                let model = RecordingStateModel()
                switch entry.kind {
                case .state(let s, let e):
                    model.state = s
                    model.elapsed = e
                    if s != .idle {
                        model.health = representativeHealth
                    }
                case .finishing:
                    model.isFinishing = true
                case .finished:
                    model.finishedURL = fixtureRecording ?? URL(
                        fileURLWithPath: "/Users/x/Movies/camcord/camcord 2026-07-04 at 21.15.30.mov"
                    )
                }
                // Use a stable opaque stand-in for the translucent popover material.
                let backdrop = scheme == "dark"
                    ? Color(red: 0.16, green: 0.16, blue: 0.17)
                    : Color(red: 0.94, green: 0.94, blue: 0.95)
                let view = CapturePanelView(model: model, actions: PanelActions())
                    .background(backdrop)
                    .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                    // Native behind-window material cannot be judged in an invisible
                    // backing window. Exercise the real Reduce Transparency fallback.
                    .environment(\.camcordOpaqueMaterialPreview, true)
                    .environment(\.camcordDesignPreview, true)
                    // A still-image harness should capture settled layouts rather than a
                    // random frame of the panel's spring/opacity transitions.
                    .transaction { $0.disablesAnimations = true }

                let settleCompletionAnimation: Bool
                switch entry.kind {
                case .finished: settleCompletionAnimation = true
                default: settleCompletionAnimation = false
                }
                guard let png = nativePNG(
                    for: view,
                    scheme: scheme,
                    size: nil,
                    settleCompletionAnimation: settleCompletionAnimation
                ) else {
                    FileHandle.standardError.write(Data("render failed: \(entry.name)-\(scheme)\n".utf8))
                    continue
                }
                let url = directory.appendingPathComponent("\(entry.name)-\(scheme).png")
                try? png.write(to: url)
                print(url.path)
            }
        }
    }

    /// Hosts the complete SwiftUI tree in AppKit before caching its display. Unlike
    /// `ImageRenderer`, this includes native-backed Slider, TextField, and ProgressView
    /// controls instead of substituting yellow placeholder views.
    /// Shared native snapshot seam used by the panel and Settings design harnesses.
    /// An explicit size constrains resizable surfaces; nil uses the root view's ideal size.
    static func nativePNG<Content: View>(
        for view: Content,
        scheme: String,
        size: CGSize? = nil
    ) -> Data? {
        nativePNG(for: view, scheme: scheme, size: size, settleCompletionAnimation: false)
    }

    private static func nativePNG<Content: View>(
        for view: Content,
        scheme: String,
        size explicitSize: CGSize?,
        settleCompletionAnimation: Bool
    ) -> Data? {
        let appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = appearance

        let size = explicitSize ?? hostingView.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        hostingView.frame = CGRect(origin: .zero, size: size)

        // A backing window establishes AppKit appearance/layout without becoming visible.
        // Keeping it local also ensures every fixture starts from a fresh native view tree.
        let window = NSWindow(
            contentRect: hostingView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.contentView = hostingView
        for _ in 0..<2 {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            window.layoutIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
        }
        if settleCompletionAnimation {
            let deadline = Date(timeIntervalSinceNow: 0.7)
            while Date() < deadline {
                _ = RunLoop.main.run(
                    mode: .default,
                    before: min(deadline, Date(timeIntervalSinceNow: 0.02))
                )
            }
        }
        hostingView.displayIfNeeded()

        let scale = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width * CGFloat(scale))),
            pixelsHigh: Int(ceil(size.height * CGFloat(scale))),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    private static var representativeHealth: RecordingHealth {
        RecordingHealth(
            video: SampleDeliveryStats(delivered: 2_040, appended: 2_038, dropped: 2),
            systemAudio: AudioSourceHealth(
                enabled: true,
                levels: AudioLevels(rmsDBFS: -18, peakDBFS: -7, limited: false),
                lastSampleUptime: ProcessInfo.processInfo.systemUptime,
                samples: SampleDeliveryStats(delivered: 1_021, appended: 1_021, dropped: 0)
            ),
            microphone: AudioSourceHealth(
                enabled: true,
                levels: AudioLevels(rmsDBFS: -27, peakDBFS: -11, limited: false),
                lastSampleUptime: ProcessInfo.processInfo.systemUptime,
                samples: SampleDeliveryStats(delivered: 1_018, appended: 1_018, dropped: 0)
            )
        )
    }

    /// A two-frame local movie lets the finished fixture exercise the real async
    /// AVAssetImageGenerator path. It is deleted after the PNGs are complete.
    private static func makeFixtureRecording(in directory: URL) -> URL? {
        let url = directory.appendingPathComponent("Camcord Preview.mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        let width = 320
        let height = 180
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        for (index, time) in [CMTime.zero, CMTime(seconds: 1, preferredTimescale: 600)].enumerated() {
            guard input.isReadyForMoreMediaData,
                  let buffer = fixturePixelBuffer(width: width, height: height, phase: index),
                  adaptor.append(buffer, withPresentationTime: time)
            else {
                writer.cancelWriting()
                return nil
            }
        }
        input.markAsFinished()
        let completed = DispatchSemaphore(value: 0)
        writer.finishWriting { completed.signal() }
        guard completed.wait(timeout: .now() + 3) == .success, writer.status == .completed else {
            writer.cancelWriting()
            return nil
        }
        return url
    }

    private static func fixturePixelBuffer(width: Int, height: Int, phase: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let iris = x > width / 2
                let upper = y > height / 2
                row[x * 4] = iris ? UInt8(196 - phase * 22) : UInt8(76 + phase * 18)
                row[x * 4 + 1] = upper ? UInt8(112 + phase * 15) : UInt8(64 + phase * 20)
                row[x * 4 + 2] = iris ? UInt8(90 + phase * 14) : UInt8(235 - phase * 18)
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }
}
