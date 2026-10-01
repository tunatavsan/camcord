import AVFoundation
import AppKit
import CoreText
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import Camcord

/// Owned, explicitly labeled display samples. This provider never calls a capture engine.
@MainActor final class StudioPresentationFixture: StudioPresentationProvider {
    let state: String
    let snapshot: StudioPresentationSnapshot
    let assetURLs: [URL]

    init(state: String, directory: URL) async throws {
        self.state = state
        var thumbnails: [StudioSourceChoice.ID: NSImage] = [:]
        var sources: [StudioSourceChoice] = []
        var urls: [URL] = []
        for (index, title) in ["Studio Display", "Notes — Studio", "Review — Studio"].enumerated() {
            let url = directory.appendingPathComponent("studio-owned-source-\(index).png")
            let image = try Self.neutralImage(index: index, title: title)
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            urls.append(url)
            let id: StudioSourceChoice.ID = index == 0 ? .display(9001) : .window(UInt32(9001 + index))
            sources.append(.init(id: id, title: title, frame: CGRect(x: 0, y: 0, width: 960, height: 600), pixelSize: CGSize(width: 960, height: 600)))
            thumbnails[id] = NSImage(cgImage: image, size: CGSize(width: 960, height: 600))
        }
        let stage = try Self.stageImage(try #require(thumbnails[sources[1].id]?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        var settings = RecordingSettings()
        settings.systemAudio = true; settings.microphone = true; settings.camera.enabled = true
        settings.canvasAspect = .wide16x9; settings.fps = 60; settings.resolutionScale = .native
        var finished: StudioFinishedFilePresentation?
        if state == "done" {
            let movie = directory.appendingPathComponent("Studio fixture recording.mov")
            try await Self.writeMovie(image: stage, to: movie)
            let asset = AVURLAsset(url: movie)
            let duration = try await asset.load(.duration).seconds
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let dimensions = try await track.load(.naturalSize)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let image = try await generator.image(at: .zero).image
            let bytes = try movie.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
            finished = .init(url: movie, thumbnail: NSImage(cgImage: image, size: dimensions), dimensions: dimensions, duration: duration, byteCount: bytes)
            urls.append(movie)
        }
        assetURLs = urls
        snapshot = .init(provenance: "Fixture frames · meters · \(state)", sources: sources,
                         thumbnails: thumbnails, selectedSource: sources[1],
                         stageImage: NSImage(cgImage: stage, size: CGSize(width: 960, height: 600)),
                         canvasSize: CGSize(width: 960, height: 600), previewState: .inactive,
                         settings: settings,
                         systemAudioLevels: .init(rmsDBFS: -18, peakDBFS: -6, limited: false),
                         microphoneLevels: .init(rmsDBFS: -9, peakDBFS: -3, limited: false),
                         recordingState: state == "recording" ? .recording : .idle,
                         elapsed: state == "recording" ? "00:12.00" : nil,
                         canRecord: true, cameraName: "Camera tile", cameraFormat: "960 × 600 · 30",
                         microphoneName: "Audio input", finishedFile: finished)
    }

    private static func neutralImage(index: Int, title: String) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 960, height: 600, bitsPerComponent: 8,
            bytesPerRow: 3840, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: index == 2 ? 0.18 : 0.94, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 960, height: 600))
        context.setFillColor(CGColor(gray: index == 2 ? 0.28 : 0.86, alpha: 1)); context.fill(CGRect(x: 0, y: 554, width: 960, height: 46))
        context.setFillColor(CGColor(gray: index == 2 ? 0.78 : 0.18, alpha: 1))
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: CGColor(gray: index == 2 ? 0.85 : 0.2, alpha: 1)])
        context.textPosition = CGPoint(x: 44, y: 487); CTLineDraw(CTLineCreateWithAttributedString(text), context)
        for row in 0..<5 { context.fill(CGRect(x: 44 + CGFloat(index * 8), y: CGFloat(405 - row * 54), width: CGFloat(740 - row * 73), height: 16)) }
        return try #require(context.makeImage())
    }

    private static func stageImage(_ source: CGImage) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 960, height: 600, bitsPerComponent: 8,
            bytesPerRow: 3840, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.07, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 960, height: 600))
        context.draw(source, in: CGRect(x: 52, y: 46, width: 850, height: 510))
        let tile = CameraOptions(enabled: true).rect(in: CGSize(width: 960, height: 600))
        let radius = CameraOptions.cornerRadius(for: tile.size)
        context.setFillColor(CGColor(gray: 0.29, alpha: 1))
        context.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)); context.fillPath()
        context.setFillColor(CGColor(gray: 0.63, alpha: 1))
        context.fillEllipse(in: CGRect(x: tile.midX - tile.height / 4, y: tile.midY - tile.height / 4, width: tile.height / 2, height: tile.height / 2))
        return try #require(context.makeImage())
    }

    private static func writeMovie(image: CGImage, to url: URL) async throws {
        let width = 320, height = 200
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        #expect(writer.canAdd(input)); writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                guard ContinuousClock.now < deadline else { writer.cancelWriting(); throw CocoaError(.fileWriteUnknown) }
                await Task.yield()
            }
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                       [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer) == kCVReturnSuccess)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            #expect(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}


@MainActor @Suite("Studio readonly presentation fixtures", .serialized)
struct StudioPresentationFixtureTests {
    @Test("owned snapshots and a real finished movie never open the actual preview gate", arguments: ["setup", "recording", "done"])
    func readonlySnapshot(_ displayedState: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-studio-presentation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let presentation = try await StudioPresentationFixture(state: displayedState, directory: root)
        let data = presentation.snapshot
        #expect(data.provenance.contains("Fixture frames"))
        #expect(data.sources.count == 3 && data.thumbnails.count == 3)
        #expect(data.selectedSource?.id == data.sources[1].id)
        #expect(data.stageImage != nil)
        #expect(data.systemAudioLevels?.rmsDBFS == -18 && data.microphoneLevels?.rmsDBFS == -9)
        #expect(data.recordingState == (displayedState == "recording" ? .recording : .idle))
        if displayedState == "done" {
            let file = try #require(data.finishedFile)
            #expect(file.dimensions == CGSize(width: 320, height: 200))
            #expect((file.duration ?? 0) > 0.9 && (file.duration ?? 2) <= 1.1)
            #expect((file.byteCount ?? 0) > 0 && file.thumbnail != nil)
            #expect(FileManager.default.fileExists(atPath: file.url.path))
            let actual = try await StudioMediaFileLoader().load(file.url)
            #expect(actual.dimensions == file.dimensions && actual.byteCount == file.byteCount)
            #expect(actual.duration == file.duration && actual.thumbnail != nil)
        } else { #expect(data.finishedFile == nil) }

        let suite = "camcord.studio.presentation." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var actualSettings = RecordingSettings(); actualSettings.systemAudio = false; actualSettings.microphone = false; actualSettings.camera.enabled = false
        actualSettings.save(to: defaults)
        var hardwareCalls = 0
        let coordinator = CaptureCoordinator(operations: .init(screenCaptureAuthorized: { hardwareCalls += 1; return false }, feedback: false))
        let controller = RecordingController(coordinator: coordinator, defaults: defaults)
        let state = RecordingStateModel()
        let microphone = MicrophoneMonitor(operations: .init(authorize: { hardwareCalls += 1; return false }, isAuthorized: { hardwareCalls += 1; return false }))
        let camera = CameraPreviewMonitor(operations: .init(authorize: { _ in hardwareCalls += 1; return false }, start: { _, _, _ in hardwareCalls += 1; throw CocoaError(.featureUnsupported) }))
        let session = StudioSession(defaults: defaults, controller: controller, recordingState: state, coordinator: coordinator,
            microphoneMonitor: microphone, cameraMonitor: camera, operations: .init(screenCaptureAuthorized: { hardwareCalls += 1; return false },
                content: { _ in hardwareCalls += 1; throw CocoaError(.featureUnsupported) }, cameraAuthorized: { hardwareCalls += 1; return false }))
        let model = MainWindowModel(defaults: defaults); model.selection = .studio
        let lifecycle = MainWindowLifecycle()
        let view = StudioView().environment(\.studioSession, session).environment(\.mainWindowModel, model)
            .environment(\.mainWindowLifecycle, lifecycle).environment(\.studioPresentationProvider, presentation)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 944, height: 704)
        host.layoutSubtreeIfNeeded()
        // Draw the production bodies off-window; no app activation, NSWindow, input or streams.
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        for _ in 0..<20 { await Task.yield() }
        #expect(!lifecycle.allowsLivePreview)
        #expect(!controller.isBusy && state.state == .idle)
        #expect(session.previewState == .inactive && session.stageImage == nil)
        #expect(session.sources.isEmpty && session.sourceThumbnails.images.isEmpty)
        #expect(!session.microphoneTestRequested && !session.cameraPreviewRequested && !session.systemAudioTestRequested)
        #expect(!microphone.isRunning && !camera.isRunning)
        #expect(hardwareCalls == 0)
        #expect(!session.settings.systemAudio && !session.settings.microphone && !session.settings.camera.enabled)
    }
}
