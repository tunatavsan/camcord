import CoreGraphics
import Foundation
import Testing

@testable import Camcord

@Suite("FrozenDesktopSnapshot")
struct FrozenDesktopSnapshotTests {
    @Test("native crop preserves top/bottom pixels at a negative global origin")
    func nativeCropPreservesPixelOrientationAndNegativeOrigin() throws {
        let source = image(width: 4, height: 4) { x, y in
            (UInt8(20 + x * 40), UInt8(10 + y * 50), 0, 255)
        }
        let display = FrozenDesktopSnapshot.Display(
            id: 7,
            cgFrame: CGRect(x: -2, y: -1, width: 2, height: 2),
            image: source
        )
        let snapshot = FrozenDesktopSnapshot(displays: [display], windows: [])

        let crop = try #require(snapshot.crop(
            cgRect: CGRect(x: -1.5, y: -0.5, width: 1, height: 1),
            resolutionScale: .native
        ))

        #expect(crop.image.width == 2)
        #expect(crop.image.height == 2)
        #expect(crop.pointSize == CGSize(width: 1, height: 1))
        #expect(pixel(crop.image, x: 0, y: 0) == Pixel(60, 60, 0, 255))
        #expect(pixel(crop.image, x: 1, y: 1) == Pixel(100, 110, 0, 255))
    }

    @Test("oneX crop downsamples a 2x source and keeps top/bottom orientation")
    func oneXCropDownsamplesWithCorrectOrientation() throws {
        let source = image(width: 4, height: 4) { _, y in
            y < 2 ? (240, 20, 10, 255) : (10, 30, 230, 255)
        }
        let snapshot = FrozenDesktopSnapshot(
            displays: [.init(id: 1, cgFrame: CGRect(x: 0, y: 0, width: 2, height: 2), image: source)],
            windows: []
        )

        let crop = try #require(snapshot.crop(
            cgRect: CGRect(x: 0, y: 0, width: 2, height: 2),
            resolutionScale: .oneX
        ))

        #expect(crop.image.width == 2)
        #expect(crop.image.height == 2)
        #expect(pixel(crop.image, x: 0, y: 0).r > 200)
        #expect(pixel(crop.image, x: 0, y: 1).b > 200)
    }

    @Test("cross-display native crop composites exact frozen pixels at the highest scale")
    func crossDisplayCropWithMixedScalesAndNegativeOrigin() throws {
        let left = image(width: 2, height: 2) { _, _ in (230, 15, 20, 255) }
        let right = image(width: 4, height: 4) { _, _ in (20, 40, 235, 255) }
        let snapshot = FrozenDesktopSnapshot(
            displays: [
                .init(id: 1, cgFrame: CGRect(x: -2, y: 0, width: 2, height: 2), image: left),
                .init(id: 2, cgFrame: CGRect(x: 0, y: 0, width: 2, height: 2), image: right),
            ],
            windows: []
        )

        let crop = try #require(snapshot.crop(
            cgRect: CGRect(x: -1, y: 0, width: 2, height: 2),
            resolutionScale: .native
        ))

        #expect(crop.image.width == 4)
        #expect(crop.image.height == 4)
        #expect(crop.pointSize == CGSize(width: 2, height: 2))
        #expect(pixel(crop.image, x: 0, y: 1).r > 200)
        #expect(pixel(crop.image, x: 3, y: 1).b > 200)
    }

    @Test("frozen window hit testing uses immutable trigger-time z order")
    func frozenWindowHitTestingUsesSnapshotOrder() {
        let source = image(width: 10, height: 10) { _, _ in (0, 0, 0, 255) }
        let snapshot = FrozenDesktopSnapshot(
            displays: [.init(id: 1, cgFrame: CGRect(x: 0, y: 0, width: 10, height: 10), image: source)],
            windows: [
                .init(id: 2, frame: CGRect(x: 2, y: 2, width: 6, height: 6)),
                .init(id: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
            ]
        )

        #expect(snapshot.window(atCGPoint: CGPoint(x: 3, y: 3))?.id == 2)
        #expect(snapshot.window(atCGPoint: CGPoint(x: 9, y: 9))?.id == 1)
    }

    @Test("latest request gate rejects an older completion")
    func latestRequestGateRejectsOlderCompletion() {
        var gate = LatestRequestGate()
        let older = gate.begin()
        let newer = gate.begin()
        #expect(!gate.isCurrent(older))
        #expect(gate.isCurrent(newer))
    }

    @Test("active-window selection prefers a normal window over an earlier utility surface")
    func activeWindowPrefersNormalSurface() {
        let utility = WindowSnapper.Candidate(
            windowID: 20,
            layer: 3,
            bounds: CGRect(x: 0, y: 0, width: 600, height: 80),
            ownerPID: 42
        )
        let document = WindowSnapper.Candidate(
            windowID: 21,
            layer: 0,
            bounds: CGRect(x: 20, y: 40, width: 900, height: 700),
            ownerPID: 42
        )
        #expect(WindowSnapper.activeWindowID(
            ordered: [utility, document],
            frontmostPID: 42,
            ownPID: 7,
            displayFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        ) == 21)
    }

    @Test("active-window selection excludes Camcord when Camcord is frontmost")
    func activeWindowFallsThroughOwnWindows() {
        let own = WindowSnapper.Candidate(
            windowID: 30,
            layer: 0,
            bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
            ownerPID: 7
        )
        let other = WindowSnapper.Candidate(
            windowID: 31,
            layer: 0,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            ownerPID: 99
        )
        #expect(WindowSnapper.activeWindowID(
            ordered: [own, other],
            frontmostPID: 7,
            ownPID: 7,
            displayFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        ) == 31)
    }

    @Test("display-sized non-normal surface is an exclusive-fullscreen fallback")
    func activeWindowAllowsOnlyDisplaySizedNonNormalFallback() {
        let titleBar = WindowSnapper.Candidate(
            windowID: 40,
            layer: 3,
            bounds: CGRect(x: 0, y: 0, width: 1200, height: 80),
            ownerPID: 42
        )
        let fullscreen = WindowSnapper.Candidate(
            windowID: 41,
            layer: 8,
            bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            ownerPID: 42
        )
        #expect(WindowSnapper.activeWindowID(
            ordered: [titleBar, fullscreen],
            frontmostPID: 42,
            ownPID: 7,
            displayFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        ) == 41)
    }
}

private struct Pixel: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

private func image(
    width: Int,
    height: Int,
    pixel makePixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
) -> CGImage {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let p = makePixel(x, y)
            bytes.append(contentsOf: [p.0, p.1, p.2, p.3])
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func pixel(_ image: CGImage, x: Int, y: Int) -> Pixel {
    let bytes = [UInt8](image.dataProvider!.data! as Data)
    let i = y * image.bytesPerRow + x * 4
    return Pixel(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
}
