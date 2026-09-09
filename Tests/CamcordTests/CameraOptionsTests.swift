import Foundation
import Testing

@testable import Camcord

@Suite("Camera options")
struct CameraOptionsTests {
    @Test("defaults match the integration contract")
    func defaults() {
        let options = CameraOptions()
        #expect(!options.enabled)
        #expect(options.deviceID == nil)
        #expect(options.corner == .bottomRight)
        #expect(options.widthFraction == 0.22)
        #expect(options.mirrored)
    }

    @Test("resolution trims device IDs and clamps unsafe widths")
    func resolvesInvalidValues() {
        #expect(CameraOptions(deviceID: "  camera-id  ", widthFraction: .infinity).resolved()
            == CameraOptions(deviceID: "camera-id", widthFraction: 0.22))
        #expect(CameraOptions(deviceID: "  ", widthFraction: -8).resolved().deviceID == nil)
        #expect(CameraOptions(widthFraction: -8).resolved().widthFraction == 0.08)
        #expect(CameraOptions(widthFraction: 8).resolved().widthFraction == 0.60)
        #expect(CameraOptions(widthFraction: .nan).resolved().widthFraction == 0.22)
    }

    @Test("camera can grow beyond the old cap and shrink to a compact overlay")
    func usefulResizeRange() {
        let area = CGSize(width: 1800, height: 1100)
        let compact = CameraOptions(widthFraction: 0.08).rect(in: area)
        let large = CameraOptions(widthFraction: 0.60).rect(in: area)
        #expect(abs(compact.width - 144) < 0.01)
        #expect(abs(large.width - 1080) < 0.01)
        #expect(abs(large.width / large.height - 16.0 / 9.0) < 0.001)
    }

    @Test("full-frame preview points and compositor pixels preserve placement scale")
    func fullFramePreviewMatchesCompositorScale() {
        let previewFrame = CGSize(width: 1512, height: 982)
        let pixelScale: CGFloat = 2
        let options = CameraOptions(
            enabled: true,
            widthFraction: 0.37,
            position: CameraPosition(x: 0.23, y: 0.71)
        )
        let previewRect = options.rect(in: previewFrame)
        let compositorRect = options.rect(in: CGSize(width: previewFrame.width * pixelScale,
                                                     height: previewFrame.height * pixelScale))
        let scaledPreview = CGRect(x: previewRect.minX * pixelScale, y: previewRect.minY * pixelScale,
                                   width: previewRect.width * pixelScale, height: previewRect.height * pixelScale)
        #expect(zip([compositorRect.minX, compositorRect.minY, compositorRect.width, compositorRect.height],
                    [scaledPreview.minX, scaledPreview.minY, scaledPreview.width, scaledPreview.height])
            .allSatisfy { abs($0 - $1) < 1e-9 })
    }

    @Test("all corners round-trip through Codable")
    func codableRoundTrip() throws {
        for corner in CameraCorner.allCases {
            let original = CameraOptions(
                enabled: true,
                deviceID: "camera",
                corner: corner,
                widthFraction: 0.31,
                mirrored: false
            )
            let decoded = try JSONDecoder().decode(
                CameraOptions.self,
                from: JSONEncoder().encode(original)
            )
            #expect(decoded == original)
        }
    }

    @Test("free placement survives resizing and corners snap only nearby")
    func placementAndSnap() throws {
        let screen = CGSize(width: 1800, height: 1100)
        var options = CameraOptions(enabled: true, widthFraction: 0.22)
        options.place(CGRect(x: 650, y: 370, width: 396, height: 222.75), in: screen, snapDistance: 32)
        let rect = options.rect(in: screen)
        #expect(abs(rect.minX - 650) < 0.01)
        #expect(abs(rect.minY - 370) < 0.01)
        #expect(try JSONDecoder().decode(CameraOptions.self, from: JSONEncoder().encode(options)) == options)
        options.place(CGRect(x: 24, y: 23, width: 396, height: 222.75), in: screen, snapDistance: 32)
        #expect(options.position == CameraPosition(corner: .bottomLeft))
        options.widthFraction = 0.4
        let resized = options.rect(in: screen)
        #expect(resized.width > rect.width)
        #expect(resized.maxX <= screen.width && resized.maxY <= screen.height)
        #expect(abs(resized.width / resized.height - 16.0 / 9.0) < 0.001)
        #expect(CameraOptions(position: CameraPosition(x: .nan, y: -1)).resolved().position == CameraPosition(x: 1, y: 0))
    }

    @Test("missing and unknown fields decode to safe defaults")
    func decodingDefaults() throws {
        let missing = try JSONDecoder().decode(CameraOptions.self, from: Data("{}".utf8))
        #expect(missing == CameraOptions())
        let unknownCorner = try JSONDecoder().decode(
            CameraOptions.self,
            from: Data(#"{"enabled":true,"corner":"futureCorner"}"#.utf8)
        )
        #expect(unknownCorner.enabled)
        #expect(unknownCorner.corner == .bottomRight)
    }

    @Test("magnet attracts inside the recording area, releases away, and preserves an inset")
    func magnetWithinCaptureArea() throws {
        for size in [CGSize(width: 1800, height: 1100), CGSize(width: 720, height: 480)] {
            for corner in CameraCorner.allCases {
                let options = CameraOptions(enabled: true, corner: corner)
                let rest = options.rect(in: size)
                let signX: CGFloat = corner == .topLeft || corner == .bottomLeft ? 1 : -1
                let signY: CGFloat = corner == .bottomLeft || corner == .bottomRight ? 1 : -1
                let near = rest.offsetBy(dx: signX * 40, dy: signY * 25)
                let snap = try #require(CameraOptions.magnet(for: near, in: size, latched: nil))
                #expect(snap.corner == corner)
                #expect(snap.rect == rest)
                let inset = CameraOptions.margin(in: size)
                #expect(rest.minX >= inset && rest.minY >= inset)
                #expect(rest.maxX <= size.width - inset && rest.maxY <= size.height - inset)
                let retina = options.rect(in: CGSize(width: size.width * 2, height: size.height * 2))
                #expect(abs(retina.minX - rest.minX * 2) < 1e-9)
                #expect(abs(retina.minY - rest.minY * 2) < 1e-9)
                #expect(abs(retina.width - rest.width * 2) < 1e-9)
                #expect(abs(retina.height - rest.height * 2) < 1e-9)
                let far = rest.offsetBy(dx: signX * 150, dy: signY * 120)
                #expect(CameraOptions.magnet(for: far, in: size, latched: corner) == nil)
            }
        }
    }

    @Test("the camera tile keeps a light, scale-free corner and a visible hairline")
    func cameraTileEdgeGeometry() {
        let preview = CGSize(width: 320, height: 180)
        // A 320x180 self-view lands exactly on the app's one corner radius.
        #expect(abs(CameraOptions.cornerRadius(for: preview) - CamcordStyle.Radius.surface) < 0.01)
        // The same fraction at composite resolution, so the file matches what was placed.
        let composited = CGSize(width: 1280, height: 720)
        #expect(abs(CameraOptions.cornerRadius(for: composited) / composited.height
                    - CameraOptions.cornerRadius(for: preview) / preview.height) < 0.0001)
        // The hairline never falls below one physical line, and scales up with the tile.
        #expect(CameraOptions.edgeHighlightWidth(for: CGSize(width: 80, height: 45)) == 1)
        #expect(CameraOptions.edgeHighlightWidth(for: composited) > 1)
    }
}
