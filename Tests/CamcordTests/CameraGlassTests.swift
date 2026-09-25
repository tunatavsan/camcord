import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import Camcord

/// Phase P/W2: the camera tile's glass edge — the numbers both renderers share, and the
/// gradient the compositor actually writes into the file. Pure: one small software render,
/// no window and no device.
@Suite("Camera glass edge")
struct CameraGlassEdgeTests {
    @Test("the edge is a translucent gradient of light, never a flat white line")
    func edgeIsGlassNotWhite() {
        let stops = CameraOptions.edgeHighlight
        #expect(stops.bright == 0.55)
        #expect(stops.dim == 0.10)
        // Flat white is what the round removed: both ends are translucent and they differ
        // enough to read as a gradient rather than as one alpha with a rounding error.
        #expect(stops.bright < 1)
        #expect(stops.bright - stops.dim > 0.3)
    }

    @Test("the shadow is one spec in pixels: the screen's points and the file's pixels match, it grows, then caps")
    func shadowInPixels() {
        // The 320x180 pt reference tile on a Retina screen: blur 18 pt, drop 6 pt, as before.
        let screen = CameraOptions.shadow(forTile: CGSize(width: 320, height: 180), pixelsPerUnit: 2)
        #expect(abs(screen.blur - 18) < 0.001)
        #expect(abs(screen.offsetY + 6) < 0.001)
        #expect(screen.alpha == 0.35)
        // The same tile in the file is 640x360 px and drops the same shadow, in pixels.
        let file = CameraOptions.shadow(forTile: CGSize(width: 640, height: 360), pixelsPerUnit: 1)
        #expect(abs(file.blur - screen.blur * 2) < 0.001)
        #expect(abs(file.offsetY - screen.offsetY * 2) < 0.001)
        // It grows with the tile up to the cap, then stops.
        let big = CameraOptions.shadow(forTile: CGSize(width: 1920, height: 1080), pixelsPerUnit: 1)
        #expect(big.blur == CameraOptions.shadowCap.blur)
        #expect(big.offsetY == -CameraOptions.shadowCap.drop)
        let small = CameraOptions.shadow(forTile: CGSize(width: 160, height: 90), pixelsPerUnit: 1)
        #expect(small.blur < file.blur && file.blur <= big.blur)
    }

    @Test("tile rects land on whole device pixels")
    func pixelAlignment() {
        let aligned = CameraOptions.pixelAligned(CGRect(x: 10.3, y: 20.26, width: 100.4, height: 50.1), pixelsPerUnit: 2)
        #expect(aligned == CGRect(x: 10.5, y: 20.5, width: 100, height: 50))
        let file = CameraOptions.pixelAligned(CGRect(x: 10.3, y: 20.6, width: 100.4, height: 50.1), pixelsPerUnit: 1)
        #expect(file == CGRect(x: 10, y: 21, width: 101, height: 50))
    }

    @Test("in the file the edge is one pixel wide at a small and at a large tile", arguments: [0.1, 0.55])
    func fileEdgeIsOnePixel(widthFraction: Double) throws {
        let screen = try sampleBuffer(buffer: solidBuffer(width: 1920, height: 1080, grey: 128))
        let camera = solidBuffer(width: 64, height: 36, grey: 40)
        let options = CameraOptions(enabled: true, corner: .bottomLeft, widthFraction: widthFraction, mirrored: false)
        let output = try #require(CMSampleBufferGetImageBuffer(
            try softwareCompositor().composite(screen: screen, camera: camera, options: options)
        ))
        let rect = CameraOptions.pixelAligned(options.rect(in: CGSize(width: 1920, height: 1080)), pixelsPerUnit: 1)
        // Along the tile's middle row, from its left edge inward, and down from its top edge
        // at the middle column: pixels lifted above the dark interior are the hairline.
        let interior = grey(output, ciX: Int(rect.midX), ciY: Int(rect.midY))
        var left = 0
        for x in Int(rect.minX)..<Int(rect.minX) + 12 where grey(output, ciX: x, ciY: Int(rect.midY)) > interior + 6 { left += 1 }
        var top = 0
        for y in (Int(rect.maxY) - 12)..<Int(rect.maxY) where grey(output, ciX: Int(rect.midX), ciY: y) > interior + 6 { top += 1 }
        #expect(left == 1, "left edge \(left) px at widthFraction \(widthFraction)")
        #expect(top == 1, "top edge \(top) px at widthFraction \(widthFraction)")
    }

    @Test("the compositor writes the gradient hairline into the file")
    func compositorDrawsTheGlassEdge() throws {
        // Mid-grey on both sides, so the light hairline is the only thing that can lift a
        // pixel near the tile's boundary — and the diagonal says which end lifts further.
        let screen = try sampleBuffer(buffer: solidBuffer(width: 400, height: 240, grey: 128))
        let camera = solidBuffer(width: 64, height: 36, grey: 128)
        let options = CameraOptions(enabled: true, corner: .bottomLeft, widthFraction: 0.6, mirrored: false)
        let output = try #require(CMSampleBufferGetImageBuffer(
            try softwareCompositor().composite(screen: screen, camera: camera, options: options)
        ))
        let rect = options.rect(in: CGSize(width: 400, height: 240))
        let interior = grey(output, ciX: Int(rect.midX), ciY: Int(rect.midY))
        // Read the brightest pixel of a short scan across the edge: a one-point hairline
        // lands between pixel centres, and the scan stays clear of the rounded corners.
        let inset = Int(CameraOptions.cornerRadius(for: rect.size)) + 4
        let lit = brightest(output, ciX: Int(rect.minX) + inset,
                            ciY: Int(rect.maxY) - 2...Int(rect.maxY))
        let dim = brightest(output, ciX: Int(rect.maxX) - inset,
                            ciY: Int(rect.minY)...Int(rect.minY) + 2)
        #expect(lit > interior + 40)
        #expect(dim > interior)
        #expect(lit > dim + 25)
    }
}

/// The tile's entrance: 320 ms, scale from 0.92, and a fade only under Reduce Motion.
@Suite("Camera entrance")
struct CameraEntranceTests {
    @Test("the tile grows from 0.92 about its own centre over 320 ms")
    func springEntrance() {
        #expect(CameraEntrance.scale == 0.92)
        #expect(CameraEntrance.duration(reduceMotion: false) == 0.32)
        #expect(CameraEntrance.scales(reduceMotion: false))
        let final = CGRect(x: 100, y: 200, width: 320, height: 180)
        let start = CameraEntrance.startFrame(final)
        #expect(abs(start.width - final.width * 0.92) < 0.001)
        #expect(abs(start.height - final.height * 0.92) < 0.001)
        #expect(abs(start.midX - final.midX) < 0.001)
        #expect(abs(start.midY - final.midY) < 0.001)
    }

    @Test("Reduce Motion keeps the fade and drops the scale")
    func reduceMotionFadesOnly() {
        #expect(!CameraEntrance.scales(reduceMotion: true))
        #expect(CameraEntrance.duration(reduceMotion: true) == 0.16)
        #expect(CameraEntrance.duration(reduceMotion: true) < CameraEntrance.duration(reduceMotion: false))
    }
}

/// The tile as it is actually drawn: the same glass edge the compositor writes into the
/// file has to be a gradient on screen too, or "identical on screen and in the recording"
/// is a claim nothing checks. Set CAMCORD_RENDER_SHOTS=<dir> to look at the tile over
/// light and dark content.
@Suite("Camera glass on screen")
@MainActor
struct CameraGlassRenderTests {
    @Test("the drawn edge is brightest at the top-leading corner and dimmest opposite")
    func drawnEdgeIsAGradient() throws {
        _ = NSApplication.shared
        let shots = ProcessInfo.processInfo.environment["CAMCORD_RENDER_SHOTS"]
        let size = CGSize(width: 320, height: 180)
        let bounds = CGRect(origin: .zero, size: size)

        for (name, backdrop) in [("dark", NSColor(calibratedWhite: 0.06, alpha: 1)),
                                 ("light", NSColor(calibratedWhite: 0.97, alpha: 1))] {
            let view = FloatingCameraView(frame: bounds)
            view.image = solidImage(size: size, color: NSColor(calibratedWhite: 0.5, alpha: 1))
            view.layoutSubtreeIfNeeded()

            let scale: CGFloat = 2
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: scale, y: scale)
            backdrop.setFill()
            bounds.fill()
            view.layer?.render(in: context.cgContext)
            NSGraphicsContext.restoreGraphicsState()
            if let shots {
                try rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(shots)/tile-\(name).png"))
            }

            // Rows run top-down in the bitmap. Sample the edge clear of the rounded corners; the
            // hairline is the outermost device pixel row.
            let inset = Int((CameraOptions.cornerRadius(for: size) + 6) * scale)
            let top = try #require(rep.colorAt(x: inset, y: 0)).brightnessComponent
            let bottom = try #require(rep.colorAt(x: rep.pixelsWide - inset, y: rep.pixelsHigh - 1)).brightnessComponent
            let interior = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)).brightnessComponent
            #expect(top > interior, "\(name): the lit edge must lift off the tile")
            #expect(top > bottom + 0.1, "\(name): the edge must fall off along the diagonal")
            // Never a flat white line: the brightest point of the edge stays translucent.
            #expect(top < 0.99, "\(name): the edge must stay glass, not white")
        }
    }

    @Test("on screen the edge is one device pixel at the smallest and the largest tile",
          arguments: [CGSize(width: 128, height: 72), CGSize(width: 960, height: 540)])
    func screenEdgeIsOneDevicePixel(size: CGSize) throws {
        _ = NSApplication.shared
        let view = FloatingCameraView(frame: CGRect(origin: .zero, size: size))
        view.image = solidImage(size: size, color: NSColor(calibratedWhite: 0.2, alpha: 1))
        view.layoutSubtreeIfNeeded()
        let scale = view.pixelsPerPoint
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        view.layer?.render(in: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        if let shots = ProcessInfo.processInfo.environment["CAMCORD_RENDER_SHOTS"] {
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(shots)/tile-edge-\(Int(size.width)).png"))
        }
        let interior = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)).brightnessComponent
        func lifted(_ x: Int, _ y: Int) -> Bool {
            (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 0) > interior + 0.02
        }
        let midRow = rep.pixelsHigh / 2, midColumn = rep.pixelsWide / 2
        let left = (0..<12).filter { lifted($0, midRow) }.count
        let top = (0..<12).filter { lifted(midColumn, $0) }.count
        #expect(left == 1, "\(Int(size.width)) pt tile: left edge \(left) device px")
        #expect(top == 1, "\(Int(size.width)) pt tile: top edge \(top) device px")
    }

    private func solidImage(size: CGSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }
}

/// G.4: what raises the tile and the toast over a fullscreen game, and what the owner reads
/// in the log afterwards.
@MainActor
@Suite("Game overlay elevation", .serialized)
struct GameOverlayElevationTests {
    @Test("a game-like context raises the surfaces, and an unseen panel raises them too")
    func elevationRule() {
        #expect(GameOverlayElevation.shouldElevate(gameLike: true, probeVisible: true))
        // The probe is the measurement the prediction cannot make: the panel went up and is
        // not on screen, so something is over it whatever the context said.
        #expect(GameOverlayElevation.shouldElevate(gameLike: false, probeVisible: false))
        #expect(!GameOverlayElevation.shouldElevate(gameLike: false, probeVisible: true))
    }

    @Test("the level is the shielding level while active and the ordinary one after")
    func levelFollowsTheFlag() {
        let base = CameraOverlayController.baseLevel
        #expect(GameOverlayElevation.shieldingLevel.rawValue == Int(CGShieldingWindowLevel()))
        #expect(GameOverlayElevation.shieldingLevel > base)
        GameOverlayElevation.set(false)
        #expect(GameOverlayElevation.level(base: base) == base)
        #expect(GameOverlayElevation.level(base: .statusBar) == .statusBar)
        GameOverlayElevation.set(true)
        #expect(GameOverlayElevation.level(base: base) == GameOverlayElevation.shieldingLevel)
        #expect(GameOverlayElevation.level(base: .statusBar) == GameOverlayElevation.shieldingLevel)
        GameOverlayElevation.set(false)
    }

    @Test("the toggle line names the preview's visibility and its level")
    func toggleLogLine() {
        let line = GameOverlayElevation.logLine(
            surface: "preview", visible: false, level: GameOverlayElevation.shieldingLevel
        )
        #expect(line == "preview.visible=false level=\(Int(CGShieldingWindowLevel()))")
    }
}

private func softwareCompositor() -> CameraCompositor {
    CameraCompositor(context: CIContext(options: [
        .useSoftwareRenderer: true,
        .cacheIntermediates: false,
    ]))
}

private func solidBuffer(width: Int, height: Int, grey: UInt8) -> CVPixelBuffer {
    var result: CVPixelBuffer?
    precondition(CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &result
    ) == kCVReturnSuccess)
    let buffer = result!
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * rowBytes + x * 4
            base[offset] = grey
            base[offset + 1] = grey
            base[offset + 2] = grey
            base[offset + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

private func sampleBuffer(buffer: CVPixelBuffer) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format
    ) == noErr, let format else { throw CameraCompositorError.missingFormatDescription }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(value: 7, timescale: 30),
        decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
        sampleTiming: &timing, sampleBufferOut: &sample
    ) == noErr, let sample else { throw CameraCompositorError.missingFormatDescription }
    return sample
}

/// The brightest of a short vertical scan, in the same y-up space.
private func brightest(_ buffer: CVPixelBuffer, ciX: Int, ciY rows: ClosedRange<Int>) -> Int {
    rows.map { grey(buffer, ciX: ciX, ciY: $0) }.max() ?? 0
}

/// The green channel of one pixel, addressed in Core Image's y-up space like the tile rect.
private func grey(_ buffer: CVPixelBuffer, ciX: Int, ciY: Int) -> Int {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let row = CVPixelBufferGetHeight(buffer) - 1 - ciY
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    return Int(base[row * CVPixelBufferGetBytesPerRow(buffer) + ciX * 4 + 1])
}
