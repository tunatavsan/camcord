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
    @Test("the panel is two columns wide and never taller than its idle height")
    func sizeTable() {
        #expect(CapturePanelView.panelWidth == 560)
        #expect(CapturePanelView.panelHeight == 458)
        // A running recording is exactly as tall as an idle panel: the stage lives in the
        // context column, not in extra height.
        #expect(CapturePanelView.activeHeight == CapturePanelView.panelHeight)
        for height in [CapturePanelView.panelHeight, CapturePanelView.activeHeight,
                       CapturePanelView.finishingHeight, CapturePanelView.finishedHeight] {
            #expect(height <= 458)
        }
        // The two columns and the gap fill the width inside the padding exactly.
        #expect(CapturePanelView.controlColumnWidth + 12 + CapturePanelView.contextColumnWidth
            == CapturePanelView.panelWidth - 24)
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
