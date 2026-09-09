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
        // The rule the sink applies, kept here so the sharpness is a decision, not a
        // constant someone edits by feel.
        for canvas in [CapturePanelView.contextColumnWidth, 320, 600] {
            let width = min(960, max(320, canvas * 2))
            #expect(width >= canvas * 2 || width == 960)
        }
        #expect(min(960, max(320, CapturePanelView.contextColumnWidth * 2)) == 496)
    }

    @Test("every panel state lays out inside its own frame")
    func rendersEveryState() throws {
        _ = NSApplication.shared
        let shots = ProcessInfo.processInfo.environment["CAMCORD_RENDER_SHOTS"]
        let model = RecordingStateModel()

        let states: [(String, () -> Void, CGFloat)] = [
            ("idle", { model.state = .idle; model.isArmed = false; model.finishedURL = nil; model.isFinishing = false },
             CapturePanelView.panelHeight),
            ("armed", { model.state = .idle; model.isArmed = true }, CapturePanelView.panelHeight),
            ("recording", { model.isArmed = false; model.state = .recording; model.elapsed = "1:24" },
             CapturePanelView.activeHeight),
            ("paused", { model.state = .paused }, CapturePanelView.activeHeight),
        ]

        for (name, apply, expectedHeight) in states {
            apply()
            let renderer = ImageRenderer(
                content: CapturePanelView(model: model, actions: PanelActions())
                    .environment(\.camcordDesignPreview, true)
                    .environment(\.camcordOpaqueMaterialPreview, true)
            )
            renderer.scale = 2
            let image = try #require(renderer.nsImage, "\(name) rendered nothing")
            #expect(image.size.width == CapturePanelView.panelWidth, "\(name) width")
            #expect(image.size.height == expectedHeight, "\(name) height")
            if let shots, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "\(shots)/panel-\(name).png"))
            }
        }
    }
}
