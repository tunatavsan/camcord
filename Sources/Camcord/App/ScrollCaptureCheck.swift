import AppKit
import CoreMedia
import QuartzCore
import WebKit
import ImageIO
@preconcurrency import ScreenCaptureKit

/// Opt-in local diagnostic: captures only its own generated scrolling window.
/// No microphone, camera, desktop pixels, media files, or preference writes.
@MainActor
enum ScrollCaptureCheck {
    static func run() async -> Int32 {
        if let index = CommandLine.arguments.firstIndex(of: "--scroll-check-browser"),
           CommandLine.arguments.indices.contains(index + 1) {
            return await runBrowserFixture(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        guard CGPreflightScreenCaptureAccess() else { print("scroll-check: screen permission unavailable"); return 2 }
        let screen = NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let view = ScrollCheckView(scale: scale)
        let panel = NSPanel(contentRect: CGRect(x: 160, y: 180, width: 600, height: 400),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.title = "Camcord scroll diagnostic"
        panel.contentView = view
        panel.orderBack(nil)
        panel.displayIfNeeded()
        defer { view.stop(); panel.orderOut(nil) }
        do {
            var readyWindow: SCWindow?
            for _ in 0..<20 {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                readyWindow = content.windows.first { $0.windowID == CGWindowID(panel.windowNumber) && $0.frame.width > 0 }
                if readyWindow != nil { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            guard let window = readyWindow else { print("scroll-check: test window unavailable"); return 3 }
            let config = SCStreamConfiguration()
            config.width = Int(600 * scale)
            config.height = Int(400 * scale)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
            config.queueDepth = 5
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.captureResolution = .best
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let frames = ScrollFrameBuffer()
            let worker = ScrollStitchWorker()
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
            try stream.addStreamOutput(frames, type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "dev.tavsan.camcord.scroll-check", qos: .userInitiated))
            try await stream.startCapture()
            var sequence: UInt64 = 0
            let deadline = ContinuousClock.now + .seconds(3)
            while frames.peekLatest() == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            if let first = await worker.consumeFrames(from: frames, after: 0, predictedOffset: 0) { sequence = first.lastSequence }
            guard sequence > 0 else { try await stream.stopCapture(); print("scroll-check: no baseline"); return 4 }
            let startSequence = sequence
            let started = ContinuousClock.now
            view.start()
            while !view.finished, ContinuousClock.now - started < .seconds(8) {
                if let batch = await worker.consumeFrames(from: frames, after: sequence, predictedOffset: 0) { sequence = batch.lastSequence }
                try await Task.sleep(for: .milliseconds(2))
            }
            let motionDuration = ContinuousClock.now - started
            let motionFrames = sequence - startSequence
            try await Task.sleep(for: .milliseconds(200))
            try await stream.stopCapture()
            if let batch = await worker.consumeFrames(from: frames, after: sequence, predictedOffset: 0) { sequence = batch.lastSequence }
            let state = await worker.state()
            let result = await worker.finalImage()
            let expected = config.height + view.offset
            let mismatches = result.flatMap { actual in
                view.expectedImage().map { pixelMismatches(actual, $0) }
            } ?? -1
            let seconds = Double(motionDuration.components.seconds) + Double(motionDuration.components.attoseconds) / 1e18
            print("scroll-check: requested=120 displayMax=\(screen?.maximumFramesPerSecond ?? 0) updates=\(view.tickCount) captured=\(sequence - startSequence) motionFrames=\(motionFrames) seconds=\(seconds) dropped=\(frames.stats.droppedFrames)")
            print("scroll-check: output=\(result?.height ?? 0) expected=\(expected) mismatchedRowSamples=\(mismatches) unresolved=\(state.unresolved)")
            return view.finished && !state.unresolved && result?.height == expected && mismatches == 0 && frames.stats.droppedFrames == 0 ? 0 : 5
        } catch {
            print("scroll-check: \(error)")
            return 1
        }
    }

    /// A real WebKit page, rendered by WindowServer and captured with the production
    /// worker. Explicit local fixture only; ephemeral browser data, no owner tabs.
    private static func runBrowserFixture(_ url: URL) async -> Int32 {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let wide = CommandLine.arguments.contains("--scroll-check-wide")
        let size = wide ? CGSize(width: 1600, height: 1000) : CGSize(width: 1000, height: 820)
        let endOffset = CommandLine.arguments.contains("--scroll-check-blank-end") ? 2400 : 3600
        let web = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        let panel = NSPanel(contentRect: CGRect(origin: CGPoint(x: 80, y: 110), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.title = "Camcord local browser check"
        panel.level = .floating
        panel.contentView = web
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); web.stopLoading() }
        do {
            let html = try String(contentsOf: url, encoding: .utf8)
            web.loadHTMLString(html, baseURL: nil)
            for _ in 0..<120 {
                try await Task.sleep(for: .milliseconds(25))
                if !web.isLoading, (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(panel.windowNumber) }) else { return 3 }
            let scale = panel.backingScaleFactor
            let config = SCStreamConfiguration()
            config.width = Int(web.bounds.width * scale)
            config.height = Int(web.bounds.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            config.ignoreShadowsSingleWindow = true
            config.colorSpaceName = CGColorSpace.sRGB
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let worker = ScrollStitchWorker()
            var lastOffset = 0
            let stops = [0, 22, 44, 66, 120, 240, 480, 720, 1100, 1400, 1800, 2100, 2500, 3000]
                .filter { $0 < endOffset } + [endOffset]
            for offset in stops {
                _ = try await web.evaluateJavaScript("window.scrollTo(0, \(offset));")
                try await Task.sleep(for: .milliseconds(80))
                lastOffset = (try await web.evaluateJavaScript("window.scrollY") as? NSNumber)?.intValue ?? 0
                let frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                if let index = CommandLine.arguments.firstIndex(of: "--scroll-check-save"),
                   CommandLine.arguments.indices.contains(index + 1) {
                    let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let output = directory.appendingPathComponent("viewport-\(lastOffset).png")
                    if let writer = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(writer, frame, nil)
                        CGImageDestinationFinalize(writer)
                    }
                }
                let began = ContinuousClock.now
                let result = await worker.add(frame, predictedOffset: 0, settled: offset == endOffset)
                let elapsed = ContinuousClock.now - began
                print("browser-check: offset=\(lastOffset) outcome=\(result.outcome) height=\(result.contentPixelHeight) unresolved=\(result.hasUnresolvedContinuity) time=\(elapsed)")
            }
            let final = await worker.finalImage()
            let expected = config.height + Int(CGFloat(lastOffset) * scale)
            print("browser-check: final=\(final?.height ?? 0) expected=\(expected)")
            if let final, final.height == expected, CommandLine.arguments.contains("--scroll-check-live") {
                return try await runBrowserStream(web, filter: filter, config: config, expected: final, endOffset: endOffset)
            }
            return final?.height == expected ? 0 : 5
        } catch { print("browser-check: \(error)"); return 1 }
    }

    private static func runBrowserStream(_ web: WKWebView, filter: SCContentFilter,
                                         config: SCStreamConfiguration, expected: CGImage, endOffset: Int) async throws -> Int32 {
        _ = try await web.evaluateJavaScript("window.scrollTo(0, 0)")
        try await Task.sleep(for: .milliseconds(150))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let frames = ScrollFrameBuffer()
        let worker = ScrollStitchWorker()
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(frames, type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "dev.tavsan.camcord.browser-check", qos: .userInitiated))
        try await stream.startCapture()
        var sequence: UInt64 = 0
        let saveIndex = CommandLine.arguments.firstIndex(of: "--scroll-check-save")
        var savedFrames: [ScrollFrameBuffer.Frame] = []
        for _ in 0..<100 {
            if saveIndex != nil { savedFrames.append(contentsOf: frames.frames(after: sequence)) }
            if let batch = await worker.consumeFrames(from: frames, after: sequence, predictedOffset: 0) {
                sequence = batch.lastSequence
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Drive explicit scroll positions so an occluded test window's rAF throttle
        // cannot turn a capture test into a stationary-page test.
        var done = false
        let driver = Task { @MainActor in
            defer { done = true }
            let steps = [22, 38, 64, 112, 58, 160, 96]
            var offset = 0, tick = 0
            for target in [1400, 800, min(2400, endOffset), endOffset] {
                while offset != target {
                    try Task.checkCancellation()
                    let distance = min(steps[tick % steps.count], abs(target - offset))
                    offset += target > offset ? distance : -distance
                    tick += 1
                    _ = try await web.evaluateJavaScript("window.scrollTo(0, \(offset))")
                    try await Task.sleep(for: .milliseconds(12))
                }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        let began = ContinuousClock.now
        while !done, ContinuousClock.now - began < .seconds(12) {
            if saveIndex != nil { savedFrames.append(contentsOf: frames.frames(after: sequence)) }
            if let batch = await worker.consumeFrames(from: frames, after: sequence, predictedOffset: 0) {
                sequence = batch.lastSequence
                if batch.result.hasUnresolvedContinuity {
                    print("browser-stream: \(batch.result.outcome) height=\(batch.result.contentPixelHeight) seq=\(sequence)")
                }
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        if !done { driver.cancel() }
        try await driver.value
        try await Task.sleep(for: .milliseconds(150))
        let resting = await worker.consumeRestingFrame(from: frames, after: sequence, predictedOffset: 0) {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
        if let error = resting.error { throw error }
        sequence = resting.lastSequence
        try await stream.stopCapture()
        if saveIndex != nil { savedFrames.append(contentsOf: frames.frames(after: sequence)) }
        _ = await worker.consumeFrames(from: frames, after: sequence, predictedOffset: 0)
        let final = await worker.finalImage()
        let state = await worker.state()
        let mismatches = final.map { pixelMismatches($0, expected, excludingRight: 20) } ?? -1
        if let index = saveIndex, CommandLine.arguments.indices.contains(index + 1) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            for (name, image) in [("actual", final), ("expected", Optional(expected))] {
                if let image, let writer = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name + ".png") as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(writer, image, nil)
                    CGImageDestinationFinalize(writer)
                }
            }
            for frame in savedFrames {
                let url = directory.appendingPathComponent(String(format: "stream-%05d.png", frame.seq))
                if let writer = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(writer, frame.image, nil)
                    CGImageDestinationFinalize(writer)
                }
            }
        }
        print("browser-stream: finished=\(done) captured=\(frames.peekLatest()?.seq ?? 0) dropped=\(frames.stats.droppedFrames) height=\(final?.height ?? 0) expected=\(expected.height) mismatchedPixels=\(mismatches) unresolved=\(state.unresolved)")
        return done && final?.height == expected.height && mismatches == 0 && !state.unresolved ? 0 : 6
    }

    private static func pixelMismatches(_ actual: CGImage, _ expected: CGImage, excludingRight: Int = 0) -> Int {
        guard actual.width == expected.width, actual.height == expected.height else { return -1 }
        func raster(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        let a = raster(actual), b = raster(expected)
        var mismatches = 0
        for index in stride(from: 0, to: a.count, by: 4) {
            // Check EVERY row through the interiors of all 8-pixel-wide markers.
            // WindowServer can shift/resample horizontal marker boundaries by one
            // pixel even in the initial unstitched viewport; those are not row loss.
            let x = (index / 4) % actual.width
            if excludingRight > 0 {
                guard x < actual.width - excludingRight else { continue }
            } else {
                guard (2...5).contains(x % 8) else { continue }
            }
            // Screen/window color conversion may round by one or two code values.
            if (0..<3).contains(where: { abs(Int(a[index + $0]) - Int(b[index + $0])) > 3 }) {
                if mismatches < 4 { print("scroll-check mismatch: x=\((index / 4) % actual.width) y=\((index / 4) / actual.width) actual=\(a[index]) expected=\(b[index])") }
                mismatches += 1
            }
        }
        return mismatches
    }
}

@MainActor
private final class ScrollCheckView: NSView {
    private let page: CGImage
    private let scale: CGFloat
    private var link: CADisplayLink?
    private(set) var offset = 0
    private(set) var tickCount = 0
    var finished: Bool { tickCount >= 180 }

    init(scale: CGFloat) {
        self.scale = scale
        let width = Int(600 * scale), height = Int(7_000 * scale)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                var hash = UInt64(row / 3 + 1) &* 2_654_435_761 ^ UInt64(column / 8 + 7) &* 2_246_822_519
                hash ^= hash >> 13
                if !CommandLine.arguments.contains("--scroll-check-low-contrast") {
                    hash &*= 3_266_489_917
                    hash ^= hash >> 16
                }
                let value = UInt8(40 + (hash >> 19) % 190)
                let index = (row * width + column) * 4
                pixels[index] = value; pixels[index + 1] = value; pixels[index + 2] = value
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        page = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        wantsLayer = true
        layer?.contentsScale = scale
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
        layer?.actions = ["contents": NSNull()]
    }

    required init?(coder: NSCoder) { nil }
    func expectedImage() -> CGImage? {
        imageForRows(from: 0, height: Int(400 * scale) + offset)
    }
    private func imageForRows(from row: Int, height: Int) -> CGImage? {
        guard let data = page.dataProvider?.data, let base = CFDataGetBytePtr(data),
              let slice = CFDataCreate(nil, base.advanced(by: row * page.bytesPerRow), height * page.bytesPerRow),
              let provider = CGDataProvider(data: slice) else { return nil }
        return CGImage(width: page.width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: page.bytesPerRow, space: page.colorSpace!, bitmapInfo: page.bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    func start() {
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick(_ link: CADisplayLink) {
        guard !finished else { stop(); return }
        offset += Int([18, 26, 34, 22][tickCount % 4] * Int(scale))
        tickCount += 1
        needsDisplay = true
        displayIfNeeded()
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        // No implicit contents crossfade: the oracle is a discrete pixel scroll,
        // not the transient blend between two unrelated generated viewport images.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = imageForRows(from: offset, height: Int(400 * scale))
        CATransaction.commit()
    }
}
