import CoreGraphics
import Foundation
import Testing
import CoreVideo
import os
@testable import Camcord

@Suite("Studio layer and source values")
struct StudioModelTests {
    @Test("actual main display wins sorted order, and manual intent permanently consumes default eligibility")
    func defaultDisplayPolicy() {
        func choice(_ id: StudioSourceChoice.ID) -> StudioSourceChoice {
            .init(id: id, title: "Value", frame: CGRect(x: 0, y: 0, width: 80, height: 48), pixelSize: CGSize(width: 80, height: 48))
        }
        let choices = [choice(.display(1)), choice(.display(9)), choice(.window(2))]
        var policy = StudioDefaultSourcePolicy()
        let empty = policy.choose(from: [], mainDisplayID: 9)
        #expect(empty == nil && policy.eligible)
        let windowOnly = policy.choose(from: [choice(.window(2))], mainDisplayID: 9)
        #expect(windowOnly == nil && policy.eligible)
        let main = policy.choose(from: choices, mainDisplayID: 9)
        #expect(main?.id == .display(9))
        let repeated = policy.choose(from: choices, mainDisplayID: 1)
        #expect(repeated == nil)
        let busy = policy.sourceDisappeared(.display(9), idle: false)
        #expect(!busy)
        let lost = policy.sourceDisappeared(.display(9), idle: true)
        #expect(lost)
        let fallback = policy.choose(from: choices, mainDisplayID: 42)
        #expect(fallback?.id == .display(1))
        policy.manualIntent()
        let manualLost = policy.sourceDisappeared(.display(1), idle: true)
        #expect(!manualLost)
        let afterManual = policy.choose(from: choices, mainDisplayID: 9)
        #expect(afterManual == nil)
        var cleared = StudioDefaultSourcePolicy()
        cleared.manualIntent()
        let afterClear = cleared.choose(from: choices, mainDisplayID: 9)
        #expect(afterClear == nil)
    }

    @MainActor @Test("source thumbnail raster budget bounds both portrait and landscape before capture")
    func thumbnailRasterBudget() {
        #expect(StudioSourceThumbnails.rasterSize(CGSize(width: 3840, height: 2160), maximum: 240) == CGSize(width: 240, height: 135))
        #expect(StudioSourceThumbnails.rasterSize(CGSize(width: 1080, height: 1920), maximum: 240) == CGSize(width: 135, height: 240))
        #expect(StudioSourceThumbnails.rasterSize(CGSize(width: CGFloat.nan, height: 400), maximum: 240) == .zero)
    }

    @MainActor @Test("hidden and disappeared thumbnail generations reject a noncooperative batch", arguments: [false, true])
    func thumbnailStaleCompletion(disappeared: Bool) async throws {
        let choice = StudioSourceChoice(id: .display(1), title: "Value", frame: CGRect(x: 0, y: 0, width: 80, height: 48), pixelSize: CGSize(width: 80, height: 48))
        var pending: CheckedContinuation<[StudioSourceChoice.ID: CGImage], Never>?
        var calls = 0
        let thumbnails = StudioSourceThumbnails(operations: .init(batch: { choices, budget in
            calls += 1
            #expect(choices.map(\.id) == [choice.id] && budget == 240)
            return await withCheckedContinuation { pending = $0 }
        }))
        thumbnails.update(choices: [choice], visible: false)
        thumbnails.setTileVisible(choice.id, true)
        await Task.yield()
        #expect(calls == 0)
        thumbnails.update(choices: [choice], visible: true)
        while pending == nil { await Task.yield() }
        thumbnails.update(choices: disappeared ? [] : [choice], visible: disappeared)
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pending?.resume(returning: [choice.id: try #require(context.makeImage())])
        pending = nil
        for _ in 0..<20 { await Task.yield() }
        #expect(thumbnails.images.isEmpty && calls == 1)
        thumbnails.update(choices: [], visible: false)
    }

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
