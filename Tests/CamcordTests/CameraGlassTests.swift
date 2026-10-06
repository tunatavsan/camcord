import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import Camcord

/// The camera's tray in the file: the numbers both renderers share, and the ring the
/// compositor actually writes. Pure: small software renders, no window and no device.
@Suite("Camera tray")
struct CameraGlassEdgeTests {
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

    @Test("in the file the tray rings the camera the same points wide at any size and scale",
          arguments: [(0.1, 1.0), (0.55, 1.0), (0.1, 2.0), (0.55, 2.0)])
    func fileTrayRing(widthFraction: Double, pixelsPerPoint: CGFloat) throws {
        let screen = try sampleBuffer(buffer: solidBuffer(width: 1920, height: 1080, grey: 128))
        let camera = solidBuffer(width: 64, height: 36, grey: 40)
        let options = CameraOptions(enabled: true, corner: .bottomLeft, widthFraction: widthFraction, mirrored: false)
        let output = try #require(CMSampleBufferGetImageBuffer(
            try softwareCompositor().composite(screen: screen, camera: camera, options: options,
                                               contentPointWidth: 1920 / pixelsPerPoint)
        ))
        let rect = CameraOptions.pixelAligned(options.rect(in: CGSize(width: 1920, height: 1080)), pixelsPerUnit: 1)
        let ring = Int(CameraOptions.trayRing * pixelsPerPoint)
        let rim = Int(CameraOptions.trayRim.inner.width * pixelsPerPoint)
        // Out from the camera along its middle row and column: the frost keeps the screen's own
        // level, and the rim's light line is the tray's outer edge, a ring away.
        let row = Int(rect.midY), column = Int(rect.midX)
        let screenLevel = grey(output, ciX: 1900, ciY: 1060)
        let frost = grey(output, ciX: Int(rect.minX) - ring / 2, ciY: row)
        let left = (Int(rect.minX) - ring - 4..<Int(rect.minX)).filter { grey(output, ciX: $0, ciY: row) > screenLevel + 8 }
        let top = (Int(rect.maxY)..<Int(rect.maxY) + ring + 4).filter { grey(output, ciX: column, ciY: $0) > screenLevel + 8 }
        #expect(left == Array(Int(rect.minX) - ring..<Int(rect.minX) - ring + rim), "left rim \(left) at \(widthFraction)")
        #expect(top == Array(Int(rect.maxY) + ring - rim..<Int(rect.maxY) + ring), "top rim \(top) at \(widthFraction)")
        // Between the camera and the rim: frost, not camera and not a border.
        #expect(abs(frost - screenLevel) <= 2, "frost \(frost) against the screen's \(screenLevel)")
        #expect(grey(output, ciX: Int(rect.minX) + 2, ciY: row) < screenLevel - 20)
    }

    @Test("the tray's frost blurs the screen behind it and leaves the rest of the screen sharp")
    func trayFrostsTheScreen() throws {
        let screen = try sampleBuffer(buffer: stripedBuffer(width: 640, height: 360))
        let camera = solidBuffer(width: 64, height: 36, grey: 128)
        let options = CameraOptions(enabled: true, corner: .bottomLeft, widthFraction: 0.4, mirrored: false)
        let output = try #require(CMSampleBufferGetImageBuffer(
            try softwareCompositor().composite(screen: screen, camera: camera, options: options, contentPointWidth: 320)
        ))
        let rect = CameraOptions.pixelAligned(options.rect(in: CGSize(width: 640, height: 360)), pixelsPerUnit: 1)
        let row = Int(rect.midY)
        func contrast(at x: Int) -> Int { abs(grey(output, ciX: x, ciY: row) - grey(output, ciX: x + 1, ciY: row)) }
        // In the ring, one-pixel stripes melt into grey; well clear of the tray they stay crisp.
        let frost = Int(rect.minX) - Int(CameraOptions.trayRing)
        #expect(contrast(at: frost) < 24, "frost contrast \(contrast(at: frost))")
        #expect(contrast(at: Int(rect.maxX) + 70) > 80)
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

/// What raises the tile and the toast over a fullscreen game, and what the user reads
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

/// Alternate one-pixel columns of dark and light: sharp until something blurs it.
private func stripedBuffer(width: Int, height: Int) -> CVPixelBuffer {
    let buffer = solidBuffer(width: width, height: height, grey: 40)
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in stride(from: 1, to: width, by: 2) {
            for channel in 0..<3 { base[y * rowBytes + x * 4 + channel] = 216 }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

/// The green channel of one pixel, addressed in Core Image's y-up space like the tile rect.
private func grey(_ buffer: CVPixelBuffer, ciX: Int, ciY: Int) -> Int {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let row = CVPixelBufferGetHeight(buffer) - 1 - ciY
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    return Int(base[row * CVPixelBufferGetBytesPerRow(buffer) + ciX * 4 + 1])
}
