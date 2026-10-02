import AppKit
import AVFoundation
import CoreText
import CryptoKit
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Camcord

/// Real owned files for Library evidence, indexed by the ordinary LibraryStore scanner.
@MainActor
enum LibraryPresentationFixture {
    static let states = ["grid", "search", "no-results", "empty", "list", "multi"]

    static func writeFiles(in directory: URL) async throws -> [URL] {
        var urls: [URL] = []
        let now = Date()
        for (index, title) in ["Capture workflow", "Panel layout", "Weekly capture summary", "Review workflow"].enumerated() {
            let url = directory.appendingPathComponent(title + ".png")
            try writePNG(image(index: index, title: title), to: url)
            let age: TimeInterval = index == 3 ? 86_400 + 1800 : Double(index * 1800 + 60)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
            urls.append(url)
        }
        let scroll = directory.appendingPathComponent("Documentation workflow.png")
        try writePNG(image(index: 4, title: "Documentation workflow", height: 1680), to: scroll)
        guard CaptureFileRules.tagScrollCapture(scroll) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-86_400 - 3600)], ofItemAtPath: scroll.path)
        urls.append(scroll)
        let movie = directory.appendingPathComponent("Studio walkthrough.mov")
        try await writeMovie(image: image(index: 5, title: "Studio walkthrough"), to: movie)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2700)], ofItemAtPath: movie.path)
        urls.append(movie)
        return urls
    }

    static func configure(_ store: LibraryStore, state: String) {
        store.search = state == "search" ? "workflow" : state == "no-results" ? "zz-no-library-fixture-matches-zz" : ""
        store.usesGrid = state != "list"
        let preferred = store.items.first { $0.title == "Capture workflow" }
        store.selection = Set((preferred.map { [$0] } ?? Array(store.items.prefix(1))).map(\.id))
        if state == "multi", let second = store.items.first(where: { $0.kind == .recording }) { store.selection.insert(second.id) }
    }

    static func facts(_ items: [CaptureItem], includeHash: Bool = false) throws -> [[String: Any]] {
        try items.map { item in
            var facts: [String: Any] = ["file": item.url.lastPathComponent, "id": item.id,
                "title": item.title, "kind": item.kind.rawValue, "bytes": item.byteSize,
                "pixels": item.pixelSize.map { [Int($0.width), Int($0.height)] } as Any? ?? NSNull(),
                "duration": item.duration as Any? ?? NSNull()]
            if includeHash { facts["sha256"] = SHA256.hash(data: try Data(contentsOf: item.url)).map { String(format: "%02x", $0) }.joined() }
            return facts
        }
    }

    private static func image(index: Int, title: String, height: Int = 630) throws -> CGImage {
        let width = 960
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let dark = index == 0
        context.setFillColor(CGColor(gray: dark ? 0.12 : 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: dark ? 0.16 : 0.92, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 56, width: width, height: 56))
        let font = CTFontCreateWithName(NSFont.systemFont(ofSize: 28, weight: .semibold).fontName as CFString, 28, nil)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: CGColor(gray: dark ? 0.9 : 0.14, alpha: 1)])
        context.textPosition = CGPoint(x: 52, y: height - 128)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        if index == 2 {
            for column in 0..<6 {
                let barHeight = CGFloat(100 + column * 44)
                context.setFillColor(CGColor(srgbRed: 0.23, green: 0.43, blue: 0.84, alpha: column.isMultiple(of: 2) ? 1 : 0.48))
                context.fill(CGRect(x: 74 + column * 128, y: 56, width: 74, height: Int(barHeight)))
            }
        } else if index == 1 || index == 5 {
            context.setFillColor(CGColor(gray: 0.84, alpha: 1))
            context.fill(CGRect(x: 112, y: 108, width: 570, height: 296))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 126, y: 122, width: 542, height: 268))
            for row in 0..<4 {
                context.setFillColor(CGColor(srgbRed: 0.46, green: 0.36, blue: 0.95, alpha: row == 0 ? 0.9 : 0.18))
                context.fill(CGRect(x: 180, y: 320 - row * 48, width: 386 - row * 24, height: 24))
            }
            if index == 5 {
                context.setFillColor(CGColor(gray: 0.42, alpha: 1))
                context.fill(CGRect(x: 726, y: 54, width: 178, height: 130))
            }
        } else {
            let rows = height > 630 ? 18 : 7
            for row in 0..<rows {
                if dark {
                    let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.47, 0.46, 0.85), (0.78, 0.52, 0.34), (0.48, 0.69, 0.57), (0.59, 0.62, 0.67)]
                    let color = colors[row % colors.count]
                    context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
                } else { context.setFillColor(CGColor(gray: row == 0 ? 0.18 : 0.82, alpha: 1)) }
                context.fill(CGRect(x: 68 + (row % 3) * 26, y: height - 210 - row * 52,
                                    width: 640 - (row % 4) * 72, height: 18))
            }
        }
        return try #require(context.makeImage())
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func writeMovie(image: CGImage, to url: URL) async throws {
        try await LibraryFixtureMovieWriter(image: image, url: url).write()
    }
}

/// The offline encoder advances on its own serial queue, independent of UI-test work
/// on MainActor. AVFoundation objects and mutable pump state are confined to that queue.
private final class LibraryFixtureMovieWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "camcord.tests.library-fixture-movie")
    private let image: CGImage
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var frame = 0
    private var finished = false
    private static let width = 320, height = 200

    init(image: CGImage, url: URL) throws {
        self.image = image
        let width = Self.width, height = Self.height
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    func write() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard writer.startWriting() else {
                    continuation.resume(throwing: writer.error ?? CocoaError(.fileWriteUnknown))
                    return
                }
                writer.startSession(atSourceTime: .zero)
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    pump(continuation)
                }
            }
        }
    }

    private func pump(_ continuation: CheckedContinuation<Void, Error>) {
        guard !finished else { return }
        do {
            guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            while input.isReadyForMoreMediaData && frame < 30 {
                let pixel = try pixelBuffer()
                guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                frame += 1
            }
            if frame == 30 {
                finished = true
                input.markAsFinished()
                writer.finishWriting { [self] in
                    if writer.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: writer.error ?? CocoaError(.fileWriteUnknown)) }
                }
            }
        } catch {
            finished = true
            input.markAsFinished()
            writer.cancelWriting()
            continuation.resume(throwing: error)
        }
    }

    private func pixelBuffer() throws -> CVPixelBuffer {
        let width = Self.width, height = Self.height
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let pixel = buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixel
    }
}

@MainActor
@Suite("Library owned presentation files", .serialized)
struct LibraryPresentationFixtureTests {
    @Test("Real PNGs, scroll tagging and a decoded movie reach the actual Library scanner")
    func mixedFiles() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-library-evidence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let directory = URL(fileURLWithPath: try #require(LibraryFiles.physicalPath(temporary)))
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try await LibraryPresentationFixture.writeFiles(in: directory)
        let suite = "camcord.library-evidence." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(defaults: defaults, roots: [.init(url: directory, origin: .savedFile)],
                                 cacheDirectory: directory.appendingPathComponent("unused-cache"))
        await store.refresh()
        try #require(store.loadingIssue == nil)
        #expect(store.items.count == 6)
        #expect(store.items.filter { $0.kind == .screenshot }.count == 4)
        let scroll = try #require(store.items.first { $0.kind == .scrollCapture })
        #expect(CaptureFileRules.readTag(scroll.url) == CaptureFileRules.scrollCaptureTag)
        #expect(scroll.pixelSize == CGSize(width: 960, height: 1680))
        let movie = try #require(store.items.first { $0.kind == .recording })
        #expect(movie.pixelSize == nil)
        let duration = try #require(movie.duration)
        #expect(duration > 0.8 && duration <= 1.1)
        let asset = AVURLAsset(url: movie.url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 200))
        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        try #require(reader.canAdd(frames))
        reader.add(frames)
        try #require(reader.startReading())
        var frameCount = 0
        while let sample = frames.copyNextSampleBuffer() {
            // Reader outputs may also vend zero-sample markers; those are not frames.
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            _ = try #require(CMSampleBufferGetImageBuffer(sample))
            frameCount += 1
        }
        #expect(reader.status == .completed)
        #expect(frameCount == 30)
        for item in store.items { #expect(await store.thumbnails.image(for: item) != nil) }
        #expect(Set(store.items.map(\.url)) == Set(urls))
        #expect(try LibraryPresentationFixture.facts(store.items, includeHash: true).count == 6)
        for state in ["grid", "search", "no-results", "list", "multi"] {
            LibraryPresentationFixture.configure(store, state: state)
            #expect(store.usesGrid == (state != "list"))
            #expect(store.selection.count == (state == "multi" ? 2 : 1))
            let expected = state == "search" ? 3 : state == "no-results" ? 0 : 6
            #expect(store.filteredItems.count == expected)
        }
    }
}
