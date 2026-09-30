import AppKit
import SwiftUI
import Testing

@testable import Camcord

/// The panel's shape, and the rule the whole round is about: it grows sideways, never
/// downward. Set CAMCORD_RENDER_SHOTS=<dir> to also drop a PNG of every state somewhere
/// lookable — the same escape hatch `BadgeRenderPreview` uses.
@Suite("Panel layout")
@MainActor
struct PanelLayoutTests {
    @Test("the capture palette stays compact in every recording state")
    func sizeTable() {
        #expect(CapturePanelView.panelWidth == 320)
        #expect(CapturePanelView.panelHeight == 428)
        // Recording status uses the same compact palette footprint as idle capture.
        #expect(CapturePanelView.activeHeight == CapturePanelView.panelHeight)
        for height in [CapturePanelView.panelHeight, CapturePanelView.activeHeight,
                       CapturePanelView.finishingHeight, CapturePanelView.finishedHeight] {
            #expect(height <= CapturePanelView.panelHeight)
        }

    }

    @Test("only a press on the camera rectangle moves it; the recording itself is not a control")
    func stageHitRule() {
        let frameSize = CGSize(width: 1600, height: 1000)
        let thumbnail = CGRect(x: 12, y: 20, width: 224, height: 140)
        var options = CameraOptions(enabled: true, corner: .bottomRight, widthFraction: 0.22)
        options.position = CameraPosition(x: 0.5, y: 0.5)

        let rect = StageView.cameraRect(options: options, frameSize: frameSize, thumbnail: thumbnail)
        #expect(!rect.isEmpty)

        // Dead centre of the rectangle: a move, no corner.
        let centre = StageView.hit(at: CGPoint(x: rect.midX, y: rect.midY),
                                   options: options, frameSize: frameSize, thumbnail: thumbnail)
        #expect(centre.movesCamera)
        #expect(centre.corner == nil)

        // Its corners resize.
        let bottomRight = StageView.hit(at: CGPoint(x: rect.maxX - 1, y: rect.maxY - 1),
                                        options: options, frameSize: frameSize, thumbnail: thumbnail)
        #expect(bottomRight.movesCamera)
        #expect(bottomRight.corner == .bottomRight)
        let topLeft = StageView.hit(at: CGPoint(x: rect.minX + 1, y: rect.minY + 1),
                                    options: options, frameSize: frameSize, thumbnail: thumbnail)
        #expect(topLeft.corner == .topLeft)

        // The far side of the stage is the recording, not a control.
        let elsewhere = StageView.hit(at: CGPoint(x: thumbnail.minX + 2, y: thumbnail.maxY - 2),
                                      options: options, frameSize: frameSize, thumbnail: thumbnail)
        #expect(!elsewhere.movesCamera)
        #expect(elsewhere.corner == nil)

        // A camera that is not composited has no rectangle to catch a press.
        var off = options
        off.enabled = false
        #expect(!StageView.hit(at: CGPoint(x: rect.midX, y: rect.midY),
                               options: off, frameSize: frameSize, thumbnail: thumbnail).movesCamera)
        // Neither does a stage that has not been given a frame yet.
        #expect(!StageView.hit(at: CGPoint(x: rect.midX, y: rect.midY),
                               options: options, frameSize: .zero, thumbnail: thumbnail).movesCamera)
    }

    @Test("stage grips: a press on a grip resizes, in the body moves, outside does nothing")
    func stageGripHitTest() {
        let frameSize = CGSize(width: 1600, height: 1000)
        let thumbnail = CGRect(x: 0, y: 0, width: 1600, height: 1000)   // 1:1, so points are easy
        var options = CameraOptions(enabled: true, corner: .bottomRight, widthFraction: 0.125)
        options.position = CameraPosition(x: 0.5, y: 0.5)
        let rect = StageView.cameraRect(options: options, frameSize: frameSize, thumbnail: thumbnail)
        #expect(abs(rect.width - 200) < 0.01 && abs(rect.height - 112.5) < 0.01)
        func hit(_ x: CGFloat, _ y: CGFloat) -> StageHit {
            StageView.hit(at: CGPoint(x: x, y: y), options: options, frameSize: frameSize, thumbnail: thumbnail)
        }

        // On a grip, just inside each corner: resize that corner (thumbnail space is y-down).
        #expect(hit(rect.minX + 4, rect.minY + 4) == StageHit(corner: .topLeft, movesCamera: true))
        #expect(hit(rect.maxX - 4, rect.minY + 4) == StageHit(corner: .topRight, movesCamera: true))
        #expect(hit(rect.minX + 4, rect.maxY - 4) == StageHit(corner: .bottomLeft, movesCamera: true))
        #expect(hit(rect.maxX - 4, rect.maxY - 4) == StageHit(corner: .bottomRight, movesCamera: true))
        // The zone is 22% of each side: 44 × 24.75 here. 30 pt down from a corner is body — the
        // old 44 pt square zones made it a resize.
        #expect(hit(rect.minX + 30, rect.minY + 30) == StageHit(corner: nil, movesCamera: true))
        #expect(hit(rect.midX, rect.midY) == StageHit(corner: nil, movesCamera: true))
        // Outside the rectangle — even right next to a corner — nothing.
        #expect(hit(rect.maxX + 2, rect.maxY + 2) == StageHit(corner: nil, movesCamera: false))
        #expect(hit(rect.minX - 1, rect.midY) == StageHit(corner: nil, movesCamera: false))
    }

    @Test("stage corner zones are max(12 pt, 22% of the side), never more than half of it")
    func stageGripZones() {
        let small = CGRect(x: 0, y: 0, width: 54, height: 31)
        #expect(StageGrip.zone(.topLeft, in: small).size == CGSize(width: 12, height: 12))
        let large = CGRect(x: 0, y: 0, width: 200, height: 112.5)
        #expect(StageGrip.zone(.bottomRight, in: large) == CGRect(x: 156, y: 0, width: 44, height: 24.75))
        let tiny = CGRect(x: 0, y: 0, width: 20, height: 10)
        #expect(StageGrip.zone(.topRight, in: tiny).size == CGSize(width: 10, height: 5))
        // y-down puts the top zones at the small y.
        #expect(StageGrip.zone(.topLeft, in: large, yDown: true).minY == 0)
        #expect(StageGrip.zone(.topLeft, in: large, yDown: false).maxY == large.maxY)
        // The grips sit inside the rectangle.
        for corner in CameraCorner.allCases {
            #expect(large.contains(StageGrip.arc(corner, in: large).boundingRect))
        }
        // Cursor: open hand on the body, a resize arrow on a grip, nothing outside.
        #expect(StageGrip.cursor(for: StageHit(corner: nil, movesCamera: true)) == .move)
        #expect(StageGrip.cursor(for: StageHit(corner: .topLeft, movesCamera: true)) == .resize(.topLeft))
        #expect(StageGrip.cursor(for: StageHit(corner: nil, movesCamera: false)) == nil)
    }

    @Test("the stage renders at twice its canvas points, so a Retina panel is not upscaled")
    func stageRenderWidth() {
        // The rule the sink actually applies — reverting it to the old fixed 360 fails here.
        #expect(StageView.renderWidth(canvasPoints: CapturePanelView.contextColumnWidth) == 496)
        #expect(StageView.renderWidth(canvasPoints: 200) == 400)
        // Floored, so a canvas that has not been measured yet still gets a usable image.
        #expect(StageView.renderWidth(canvasPoints: 0) == 320)
        #expect(StageView.renderWidth(canvasPoints: 100) == 320)
        // Capped: a 248 pt viewport has no use for 4K.
        #expect(StageView.renderWidth(canvasPoints: 1200) == 960)
        // Exactly 2x through the whole usable range.
        for canvas in stride(from: CGFloat(200), through: 480, by: 40) {
            #expect(StageView.renderWidth(canvasPoints: canvas) == canvas * 2)
        }
    }

    @Test("pausing does not tear down the stage's source")
    func stageSourceSurvivesAPause() {
        // The veil sits ON the last composited frame. Re-keying the source task on pause
        // cleared the image, so the veil had nothing to cover and the stage fell back to
        // "Kayıt görüntüsü bekleniyor…" for the whole pause.
        #expect(StageView.sourceKey(isArmed: false, state: .recording)
            == StageView.sourceKey(isArmed: false, state: .paused))
        // Everything else IS a change of what the stage shows.
        #expect(StageView.sourceKey(isArmed: false, state: .idle)
            != StageView.sourceKey(isArmed: false, state: .recording))
        #expect(StageView.sourceKey(isArmed: true, state: .idle)
            != StageView.sourceKey(isArmed: false, state: .idle))
        // Arming wins over the state it is armed from.
        #expect(StageView.sourceKey(isArmed: true, state: .idle)
            == StageView.sourceKey(isArmed: true, state: .recording))
    }

    /// Every state the panel can be in composes and rasterises. The rendered size is the
    /// `.frame` modifier and proves nothing on its own, so what this asserts is that each
    /// state produces a real, non-empty image — and it writes the PNGs when
    /// CAMCORD_RENDER_SHOTS is set, which is how the layout itself gets looked at.
    @Test("every panel state composes and rasterises")
    func rendersEveryState() throws {
        _ = NSApplication.shared
        let shots = ProcessInfo.processInfo.environment["CAMCORD_RENDER_SHOTS"]
        let model = RecordingStateModel()
        let finished = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("camcord-render-preview.mov")

        let states: [(String, () -> Void)] = [
            ("idle", { model.state = .idle; model.isArmed = false; model.finishedURL = nil; model.isFinishing = false }),
            ("armed", { model.state = .idle; model.isArmed = true }),
            ("recording", { model.isArmed = false; model.state = .recording; model.elapsed = "1:24" }),
            ("paused", { model.state = .paused }),
            ("finishing", { model.state = .idle; model.isFinishing = true }),
            ("finished", { model.isFinishing = false; model.finishedURL = finished }),
        ]

        for (name, apply) in states {
            apply()
            let renderer = ImageRenderer(
                content: CapturePanelView(model: model, actions: PanelActions())
                    .environment(\.camcordDesignPreview, true)
                    .environment(\.camcordOpaqueMaterialPreview, true)
            )
            renderer.scale = 2
            let image = try #require(renderer.nsImage, "\(name) rendered nothing")
            let tiff = try #require(image.tiffRepresentation)
            let rep = try #require(NSBitmapImageRep(data: tiff))
            #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0, "\(name) rasterised empty")
            // Not a blank sheet: the panel's own surface has to have painted something.
            let sampled = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
            #expect(sampled.alphaComponent > 0, "\(name) painted nothing at its centre")
            if let shots, let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "\(shots)/panel-\(name).png"))
            }
        }
    }
}
