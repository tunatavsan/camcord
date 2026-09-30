import CoreGraphics
import Foundation
import Testing
import CoreVideo
import os
@testable import Camcord

@Suite("Studio layer and source values")
struct StudioModelTests {
    @MainActor @Test("the planned window canvas uses the selected output aspect before the first frame")
    func plannedDestinationCanvas() {
        let source = StudioSourceChoice(id: .window(1), title: "Fixture", frame: CGRect(x: 0, y: 0, width: 1920, height: 1200),
                                        pixelSize: CGSize(width: 1920, height: 1200))
        var settings = RecordingSettings()
        settings.canvasAspect = .wide16x9
        #expect(StudioSession.plannedCanvasSize(source: source, settings: settings) == CGSize(width: 1920, height: 1080))
        settings.canvasAspect = .matchWindow
        #expect(StudioSession.plannedCanvasSize(source: source, settings: settings) == source.pixelSize)
    }
    @MainActor @Test("camera travel maps the fitted window content into destination units instead of the full canvas")
    func mappedCameraTravel() {
        let buffer = CGSize(width: 160, height: 90), canvas = CGSize(width: 1920, height: 1080)
        let fit = CanvasFit(canvas: buffer, content: CGRect(x: 0, y: 0, width: 40, height: 90))
        let mapped = StudioSession.mappedCameraContentRect(fit.fitted, bufferSize: buffer, canvasSize: canvas)
        #expect(mapped == CGRect(x: 720, y: 0, width: 480, height: 1080))
        #expect(mapped.minX / canvas.width == fit.fitted.minX / buffer.width)
        #expect(mapped.width / canvas.width == fit.fitted.width / buffer.width)
        let options = CameraOptions(enabled: true, widthFraction: 0.3, position: .init(x: 1, y: 1))
        let tile = options.rect(in: mapped.size).offsetBy(dx: mapped.minX, dy: mapped.minY)
        #expect(mapped.contains(tile))
        #expect(tile.width == 144)
        #expect(tile.maxX < 1200 && options.rect(in: canvas).maxX > 1800)
        #expect(StudioSession.mappedCameraContentRect(nil, bufferSize: buffer, canvasSize: canvas)
                == CGRect(origin: .zero, size: canvas))
        #expect(StudioSession.mappedCameraContentRect(CGRect(x: -20, y: 0, width: 80, height: 90),
                                                     bufferSize: buffer, canvasSize: canvas)
                == CGRect(x: 0, y: 0, width: 720, height: 1080))
    }
    @Test("layer destination rectangles reject invalid input and stay inside the destination canvas")
    func normalizedDestination() {
        #expect(StudioLayer.normalized(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)) == .zero)
        #expect(StudioLayer.normalized(CGRect(x: 0, y: 0, width: -1, height: 1)) == .zero)
        let rect = StudioLayer.normalized(CGRect(x: 0.8, y: 0.7, width: 0.8, height: 0.8))
        #expect(abs(rect.width - 0.2) < 0.00001 && abs(rect.height - 0.3) < 0.00001)
    }

    @Test("each visibility boundary closes the preview gate", arguments: 0..<4)
    func allVisibilityBits(index: Int) {
        let gates = [StudioVisibility(moduleVisible: false, windowAllowsPreview: true),
                     StudioVisibility(moduleVisible: true, windowAllowsPreview: false),
                     StudioVisibility(moduleVisible: true, windowAllowsPreview: true, captureTransition: true),
                     StudioVisibility(moduleVisible: true, windowAllowsPreview: true)]
        #expect(gates[index].allowsPreview == (index == 3))
    }

    @MainActor @Test("retired stage owners reject queued frames without removing other owners")
    func retiredStageSnapshot() throws {
        let registry = StudioStageRegistry()
        let a = UUID(), b = UUID()
        let counts = OSAllocatedUnfairLock(initialState: [0, 0])
        let receivedRect = OSAllocatedUnfairLock<CGRect?>(initialState: nil)
        registry.subscribe(owner: a) { _ in counts.withLock { $0[0] += 1 } }
        registry.subscribe(owner: b) { box in
            counts.withLock { $0[1] += 1 }
            receivedRect.withLock { $0 = box.cameraContentRect }
        }
        let retained = try #require(registry.snapshot())
        registry.unsubscribe(owner: a)
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let content = CGRect(x: 0.5, y: 0, width: 1, height: 2)
        retained(PixelBufferBox(try #require(buffer), cameraContentRect: content))
        #expect(counts.withLock { $0 } == [0, 1])
        #expect(receivedRect.withLock { $0 } == content)
        #expect(registry.ownerCount == 1)
    }
}
