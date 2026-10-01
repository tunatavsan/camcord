import AppKit
import AVFoundation
import Foundation
import Testing
import SwiftUI
@testable import Camcord

@Suite("Studio presentation and completion actions")
struct StudioUITests {
    @Test("recording clock drops fractional seconds and preserves hours")
    func displayedClock() {
        #expect(StudioDisplayTime.clock("04:26.87") == "00:04:26")
        #expect(StudioDisplayTime.clock("01:02:03.50") == "01:02:03")
        #expect(StudioDisplayTime.clock("100:02") == "01:40:02")
    }

    @MainActor @Test("hidden and superseded noncooperative file readers cannot publish stale facts")
    func fileFactsEpoch() async {
        let loader = HeldStudioMediaLoader()
        let state = StudioFinishedFileState(loader: loader)
        let older = URL(fileURLWithPath: "/isolated/older.mov"), newer = URL(fileURLWithPath: "/isolated/newer.mov")
        let first = Task { await state.load(older) }
        await loader.wait(older)
        state.hide()
        let second = Task { await state.load(newer) }
        await loader.wait(newer)
        loader.release(newer); await second.value
        #expect(state.file?.url == newer)
        loader.release(older); await first.value
        #expect(state.file?.url == newer)
        state.hide(); #expect(state.file == nil)
    }

    @MainActor @Test("the slim slider keeps native continuous input, rounded binding and disabled state")
    func continuousSlider() throws {
        var gain = 0.0
        let binding = Binding(get: { gain }, set: { gain = min(24, max(-24, $0.rounded())) })
        for disabled in [false, true] {
            let host = NSHostingView(rootView: CamcordSlider(value: binding, range: -24...24)
                .frame(width: 200, height: Theme.Studio.gainHeight).disabled(disabled))
            host.frame = CGRect(x: 0, y: 0, width: 200, height: Theme.Studio.gainHeight)
            host.layoutSubtreeIfNeeded()
            func sliders(_ view: NSView) -> [NSSlider] {
                (view as? NSSlider).map { [$0] } ?? view.subviews.flatMap(sliders)
            }
            let slider = try #require(sliders(host).first)
            #expect(slider.isEnabled == !disabled)
            #expect(slider.isContinuous)
            #expect(slider.numberOfTickMarks == 0)
            #expect(!slider.allowsTickMarkValuesOnly)
            #expect(slider.accessibilityRole() == .slider)
            if !disabled {
                let target = try #require(slider.target as? NSObject)
                let action = try #require(slider.action)
                slider.doubleValue = 7.49
                _ = target.perform(action, with: slider)
                #expect(gain == 7)
            }
        }
    }

    @Test("occlusion, another module and a capture transition each close the visible gate")
    func visibleGate() {
        let visible = StudioViewGate(moduleVisible: true, windowAllowsPreview: true, captureTransition: false)
        #expect(visible.allowsPreview)
        #expect(!StudioViewGate(moduleVisible: false, windowAllowsPreview: true, captureTransition: false).allowsPreview)
        #expect(!StudioViewGate(moduleVisible: true, windowAllowsPreview: false, captureTransition: false).allowsPreview)
        #expect(!StudioViewGate(moduleVisible: true, windowAllowsPreview: true, captureTransition: true).allowsPreview)
    }

    @MainActor @Test("only writer-safe edits remain live while recording or paused", arguments: [RecordingController.UIState.idle, .recording, .paused])
    func editingPolicy(_ state: RecordingController.UIState) {
        let policy = StudioEditingPolicy(state: state, isStarting: false, isFinishing: false, isArmed: false,
                                         controllerBusy: state != .idle, allowsPreview: true)
        #expect(!policy.liveEditsLocked)
        #expect(policy.bindingsLocked == (state != .idle))
        #expect(StudioEditingPolicy(state: state, isStarting: true, isFinishing: false, isArmed: false,
                                   controllerBusy: true, allowsPreview: true).liveEditsLocked)
        #expect(StudioEditingPolicy(state: state, isStarting: false, isFinishing: true, isArmed: false,
                                   controllerBusy: true, allowsPreview: true).liveEditsLocked)
        #expect(StudioEditingPolicy(state: state, isStarting: false, isFinishing: false, isArmed: true,
                                   controllerBusy: true, allowsPreview: true).liveEditsLocked)
        #expect(StudioEditingPolicy(state: state, isStarting: false, isFinishing: false, isArmed: false,
                                   controllerBusy: state != .idle, allowsPreview: false).liveEditsLocked)
    }

    @Test("an enabled recording channel is never represented as an idle test")
    func audioOwnershipLabels() {
        let signal = AudioLevels(rmsDBFS: -18, peakDBFS: -6, limited: false)
        #expect(StudioAudioStatus.resolve(enabled: true, recording: false, paused: false, ownsTest: false, levels: signal) == .ready)
        #expect(StudioAudioStatus.resolve(enabled: true, recording: false, paused: false, ownsTest: true, levels: nil) == .noSignal)
        #expect(StudioAudioStatus.resolve(enabled: true, recording: true, paused: false, ownsTest: true, levels: signal) == .recording)
        #expect(StudioAudioStatus.resolve(enabled: true, recording: true, paused: true, ownsTest: false, levels: signal) == .paused)
        #expect(StudioAudioStatus.resolve(enabled: false, recording: true, paused: false, ownsTest: false, levels: signal) == .off)
    }

    @Test("layer and camera top corners agree after aspect fitting while their conventions differ")
    func destinationGeometry() {
        let canvas = CGSize(width: 1920, height: 1080)
        let fitted = StudioStageGeometry.fittedCanvas(canvas, in: CGRect(x: 12, y: 18, width: 640, height: 500))
        let options = CameraOptions(enabled: true, corner: .topLeft)
        let camera = StudioStageGeometry.cameraRect(options, canvas: canvas, contentRect: CGRect(origin: .zero, size: canvas), fitted: fitted)
        #expect(camera.minX > fitted.minX)
        #expect(camera.minY > fitted.minY)
        #expect(camera.midY < fitted.midY)
        let topLayer = StudioStageGeometry.layerRect(CGRect(x: 0, y: 0, width: 0.2, height: 0.1), in: fitted)
        #expect(topLayer.minY == fitted.minY)
        let moved = StudioStageGeometry.movedLayer(CGRect(x: 0.8, y: 0.7, width: 0.2, height: 0.3), translation: CGSize(width: 400, height: 400), canvas: fitted)
        #expect(abs(moved.maxX - 1) < 0.00001)
        #expect(abs(moved.maxY - 1) < 0.00001)
        // Down on a SwiftUI stage means less bottom-left travel for the camera.
        let free = CameraOptions(enabled: true, position: CameraPosition(x: 0.5, y: 0.5))
        let translated = StudioStageGeometry.movedCamera(free, translation: CGSize(width: 0, height: 30), canvas: canvas,
                                                          contentRect: CGRect(origin: .zero, size: canvas), fitted: fitted)
        #expect((translated.position?.y ?? 1) < 0.5)
    }

    @Test("a camera belongs to actual square or tall window content inside a wide canvas", arguments: [
        CGRect(x: 420, y: 0, width: 1080, height: 1080),
        CGRect(x: 656.25, y: 0, width: 607.5, height: 1080)
    ])
    func letterboxedCameraContent(_ content: CGRect) {
        let canvas = CGSize(width: 1920, height: 1080)
        let fitted = CGRect(x: 12, y: 88, width: 640, height: 360)
        let options = CameraOptions(enabled: true, corner: .topLeft, widthFraction: 0.20)
        let rect = StudioStageGeometry.cameraRect(options, canvas: canvas, contentRect: content, fitted: fitted)
        let margin = min(content.width, content.height) * 0.03
        // Independent expected output geometry: actual content origin plus shared 3% inset,
        // one third destination-to-stage scale; whole-canvas geometry changes both width and x.
        #expect(abs(rect.minX - (12 + (content.minX + margin) / 3)) < 0.000001)
        #expect(abs(rect.minY - (88 + (content.minY + margin) / 3)) < 0.000001)
        #expect(abs(rect.width - content.width * 0.20 / 3) < 0.000001)
        let wrongWholeCanvas = StudioStageGeometry.cameraRect(options, canvas: canvas,
            contentRect: CGRect(origin: .zero, size: canvas), fitted: fitted)
        #expect(abs(rect.width - wrongWholeCanvas.width) > 20)
        let wholeCanvasLayer = StudioStageGeometry.layerRect(CGRect(x: 0, y: 0, width: 0.2, height: 0.1), in: fitted)
        #expect(wholeCanvasLayer.minX == fitted.minX)
        #expect(wholeCanvasLayer.minY == fitted.minY)

        let free = CameraOptions(enabled: true, widthFraction: 0.20, position: CameraPosition(x: 0.5, y: 0.5))
        let original = StudioStageGeometry.cameraRect(free, canvas: canvas, contentRect: content, fitted: fitted)
        let moved = StudioStageGeometry.movedCamera(free, translation: CGSize(width: 24, height: 15),
            canvas: canvas, contentRect: content, fitted: fitted)
        let movedRect = StudioStageGeometry.cameraRect(moved, canvas: canvas, contentRect: content, fitted: fitted)
        #expect(abs(movedRect.minX - original.minX - 24) < 0.000001)
        #expect(abs(movedRect.minY - original.minY - 15) < 0.000001)

        // 18×10.125 points follows the existing 16:9 resize diagonal. The opposite
        // top-left corner must stay fixed in content, with physical pointer travel preserved.
        let resized = StudioStageGeometry.resizedCamera(free, translation: CGSize(width: 18, height: 10.125),
            corner: .bottomRight, canvas: canvas, contentRect: content, fitted: fitted)
        let resizedRect = StudioStageGeometry.cameraRect(resized, canvas: canvas, contentRect: content, fitted: fitted)
        #expect(abs(resizedRect.minX - original.minX) < 0.000001)
        #expect(abs(resizedRect.minY - original.minY) < 0.000001)
        #expect(abs(resizedRect.width - original.width - 18) < 0.000001)
        #expect(abs(resizedRect.height - original.height - 10.125) < 0.000001)
    }

    @Test("all camera resize grips preserve the opposite content corner", arguments: CameraCorner.allCases)
    func allCameraCorners(_ corner: CameraCorner) {
        let canvas = CGSize(width: 1920, height: 1080)
        let content = CGRect(x: 420, y: 0, width: 1080, height: 1080)
        let fitted = CGRect(x: 12, y: 88, width: 640, height: 360)
        let start = CameraOptions(enabled: true, widthFraction: 0.20, position: CameraPosition(x: 0.5, y: 0.5))
        let original = StudioStageGeometry.cameraRect(start, canvas: canvas, contentRect: content, fitted: fitted)
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topLeft || corner == .topRight
        let next = StudioStageGeometry.resizedCamera(start,
            translation: CGSize(width: right ? 18 : -18, height: top ? -10.125 : 10.125),
            corner: corner, canvas: canvas, contentRect: content, fitted: fitted)
        let resized = StudioStageGeometry.cameraRect(next, canvas: canvas, contentRect: content, fitted: fitted)
        #expect(abs(resized.width - original.width - 18) < 0.000001)
        #expect(abs(resized.height - original.height - 10.125) < 0.000001)
        #expect(abs((right ? resized.minX : resized.maxX) - (right ? original.minX : original.maxX)) < 0.000001)
        #expect(abs((top ? resized.maxY : resized.minY) - (top ? original.maxY : original.minY)) < 0.000001)
        let encoded = next.rect(in: content.size)
        #expect(abs(encoded.width - resized.width * 3) < 0.000001)
        #expect(abs(encoded.height - resized.height * 3) < 0.000001)
    }

    @Test("camera movement attracts each edge independently in stage points", arguments: CameraCorner.allCases)
    func edgeMagnets(_ corner: CameraCorner) {
        let canvas = CGSize(width: 1920, height: 1080)
        let content = CGRect(x: 656.25, y: 0, width: 607.5, height: 1080)
        let fitted = CGRect(x: 12, y: 88, width: 640, height: 360)
        let start = CameraOptions(enabled: true, widthFraction: 0.20, position: CameraPosition(x: 0.5, y: 0.5))
        let original = start.rect(in: content.size)
        let margin = CameraOptions.margin(in: content.size)
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topLeft || corner == .topRight
        // Five stage points from one edge, with the other axis left at center.
        let targetX = right ? content.width - margin - original.width - 15 : margin + 15
        let horizontal = StudioStageGeometry.movedCamera(start,
            translation: CGSize(width: (targetX - original.minX) / 3, height: 0),
            canvas: canvas, contentRect: content, fitted: fitted)
        #expect(horizontal.position?.x == (right ? 1 : 0))
        #expect(abs((horizontal.position?.y ?? 0) - 0.5) < 0.000001)
        let targetY = top ? content.height - margin - original.height - 15 : margin + 15
        let vertical = StudioStageGeometry.movedCamera(start,
            translation: CGSize(width: 0, height: -(targetY - original.minY) / 3),
            canvas: canvas, contentRect: content, fitted: fitted)
        #expect(vertical.position?.y == (top ? 1 : 0))
        #expect(abs((vertical.position?.x ?? 0) - 0.5) < 0.000001)
        let outside = StudioStageGeometry.edgeMagnet(original.offsetBy(dx: 20, dy: 20), in: content.size, distance: 24)
        #expect(outside == original.offsetBy(dx: 20, dy: 20))
    }

    @MainActor @Test("native host attaches before a frame, changes only its viewport and detaches its own lease")
    func nativeHostLease() throws {
        let session = StudioHostSessionSpy()
        let host = StudioNativePreviewHost()
        host.configure(session: session)
        #expect(session.attachments.isEmpty)
        host.frame = CGRect(x: 0, y: 0, width: 301, height: 169)
        host.layout()
        let attachment = try #require(session.attachments.first)
        #expect(attachment.layer === host.displayLayer)
        #expect(host.displayLayer.superlayer === host.layer)
        let initialBacking = host.convertToBacking(host.bounds).size
        let initialPixels = CGSize(width: (initialBacking.width / 2).rounded(.down) * 2,
                                   height: (initialBacking.height / 2).rounded(.down) * 2)
        #expect(attachment.viewport.pixelSize == initialPixels)
        host.configure(session: session)
        host.layout()
        #expect(session.attachments.count == 1 && session.updates.isEmpty)
        host.frame.size = CGSize(width: 401, height: 225)
        host.layout()
        #expect(session.updates.count == 1)
        #expect(session.updates.first?.owner == attachment.owner)
        let resizedBacking = host.convertToBacking(host.bounds).size
        let resizedPixels = CGSize(width: (resizedBacking.width / 2).rounded(.down) * 2,
                                   height: (resizedBacking.height / 2).rounded(.down) * 2)
        #expect(session.updates.first?.viewport.pixelSize == resizedPixels)
        host.detachSession()
        host.layout() // A delayed layout must not publish to a retired session.
        #expect(session.detachments == [attachment.owner])
        #expect(session.updates.count == 1)
        #expect(host.displayLayer.superlayer === host.layer)
    }

    @MainActor @Test("two Studio hosts cannot detach or update the other host, and replacement retires the old session")
    func nativeHostIsolation() throws {
        let session = StudioHostSessionSpy(), replacement = StudioHostSessionSpy()
        let first = StudioNativePreviewHost(), second = StudioNativePreviewHost()
        for host in [first, second] {
            host.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
            host.configure(session: session)
        }
        #expect(session.attachments.count == 2)
        let firstOwner = try #require(session.attachments.first?.owner)
        let secondOwner = try #require(session.attachments.last?.owner)
        #expect(firstOwner != secondOwner)
        first.detachSession()
        second.frame.size.width = 640
        second.layout()
        #expect(session.detachments == [firstOwner])
        #expect(session.updates.last?.owner == secondOwner)
        second.configure(session: replacement)
        #expect(session.detachments == [firstOwner, secondOwner])
        #expect(replacement.attachments.count == 1)
        #expect(replacement.attachments.first?.layer === second.displayLayer)
        second.layout()
        #expect(session.updates.count == 1)
        #expect(replacement.attachments.count == 1)
        second.detachSession()
    }

    @MainActor @Test("native viewport uses even backing pixels and the current display refresh class")
    func nativeViewport() {
        #expect(StudioNativePreviewHost.viewport(backingSize: CGSize(width: 601, height: 339), maximumFramesPerSecond: 120)
            == StudioPreviewViewport(pixelSize: CGSize(width: 600, height: 338), refreshRate: 120))
        #expect(StudioNativePreviewHost.viewport(backingSize: CGSize(width: 300, height: 168), maximumFramesPerSecond: 60)?.refreshRate == 60)
        #expect(StudioNativePreviewHost.viewport(backingSize: .zero, maximumFramesPerSecond: 120) == nil)
        #expect(StudioNativePreviewHost.viewport(backingSize: CGSize(width: CGFloat.infinity, height: 100), maximumFramesPerSecond: 120) == nil)
    }

    @MainActor @Test("the coordinator is claimed before validation, and a newer capture prevents clipboard publication")
    func clipboardEpochWins() async {
        let validator = HeldStudioFileValidation()
        var events: [String] = []
        var owner = 0
        let actions = StudioFileActions(operations: .init(validate: { await validator.validate($0) },
            open: { _ in true }, reveal: { _ in }, publish: { _, current in events.append("publish"); return current() }))
        let file = URL(fileURLWithPath: "/isolated/movie.mp4")
        let task = Task { @MainActor in
            await actions.perform(.copy, url: file, claimClipboard: {
                owner += 1
                let claimed = owner
                events.append("claim")
                return { owner == claimed }
            })
        }
        await validator.waitFor(file)
        #expect(events == ["claim"])
        owner += 1 // a newly accepted screenshot owns the shared coordinator epoch
        await validator.release(file, result: file)
        await task.value
        #expect(events == ["claim"])
        #expect(actions.issue == nil)
    }

    @MainActor @Test("out of order file validation cannot overwrite a later local action")
    func localNewestWins() async {
        let validator = HeldStudioFileValidation()
        var published: [URL] = []
        let actions = StudioFileActions(operations: .init(validate: { await validator.validate($0) },
            open: { _ in true }, reveal: { _ in }, publish: { file, current in if current() { published.append(file); return true }; return false }))
        let older = URL(fileURLWithPath: "/isolated/older.mp4"), newer = URL(fileURLWithPath: "/isolated/newer.mp4")
        let first = Task { @MainActor in await actions.perform(.copy, url: older) }
        await validator.waitFor(older)
        let second = Task { @MainActor in await actions.perform(.copy, url: newer) }
        await validator.waitFor(newer)
        await validator.release(newer, result: newer)
        await second.value
        await validator.release(older, result: older)
        await first.value
        #expect(published == [newer])
    }

    @MainActor @Test("leaving the module invalidates a pending Open and never launches another application")
    func cancelPendingOpen() async {
        let validator = HeldStudioFileValidation()
        var opened = false
        let actions = StudioFileActions(operations: .init(validate: { await validator.validate($0) },
            open: { _ in opened = true; return true }, reveal: { _ in }, publish: { _, _ in false }))
        let file = URL(fileURLWithPath: "/isolated/recording.mp4")
        let task = Task { @MainActor in await actions.perform(.open, url: file) }
        await validator.waitFor(file)
        actions.cancel()
        await validator.release(file, result: file)
        await task.value
        #expect(!opened)
        #expect(!actions.isWorking)
    }

    @MainActor @Test("invalid completion files never clear or write the clipboard")
    func invalidFileDoesNotPublish() async {
        var published = false
        let actions = StudioFileActions(operations: .init(validate: { _ in nil }, open: { _ in false }, reveal: { _ in },
                                                        publish: { _, _ in published = true; return true }))
        await actions.perform(.copy, url: URL(fileURLWithPath: "/isolated/missing.mp4"))
        #expect(!published)
        #expect(actions.issue != nil)
    }

    @MainActor @Test("native validation rejects directories and nonmovie files, accepting an explicit readable movie file")
    func nativeValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder.mp4")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let text = root.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: text)
        let movie = root.appendingPathComponent("recording.mov")
        try Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20]).write(to: movie)
        let validate = StudioFileActions.Operations().validate
        #expect(await validate(folder) == nil)
        #expect(await validate(text) == nil)
        #expect(await validate(URL(string: "https://example.com/movie.mp4")!) == nil)
        #expect(await validate(movie) == movie)
    }
}

private actor HeldStudioFileValidation {
    private var held: [URL: CheckedContinuation<URL?, Never>] = [:]
    private var waiting: [URL: CheckedContinuation<Void, Never>] = [:]
    func validate(_ url: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            held[url] = continuation
            waiting.removeValue(forKey: url)?.resume()
        }
    }
    func waitFor(_ url: URL) async {
        if held[url] != nil { return }
        await withCheckedContinuation { waiting[url] = $0 }
    }
    func release(_ url: URL, result: URL?) { held.removeValue(forKey: url)?.resume(returning: result) }
}


@MainActor private final class HeldStudioMediaLoader: StudioFinishedFileLoading {
    var pending: [URL: CheckedContinuation<StudioFinishedFilePresentation, Never>] = [:]
    func load(_ url: URL) async throws -> StudioFinishedFilePresentation {
        await withCheckedContinuation { pending[url] = $0 }
    }
    func wait(_ url: URL) async { while pending[url] == nil { await Task.yield() } }
    func release(_ url: URL) {
        pending.removeValue(forKey: url)?.resume(returning: .init(url: url, thumbnail: nil, dimensions: nil, duration: nil, byteCount: nil))
    }
}

@MainActor private final class StudioHostSessionSpy: StudioPreviewHostSession {
    struct Attachment { let owner: UUID; let viewport: StudioPreviewViewport; let layer: AVSampleBufferDisplayLayer }
    struct Update { let owner: UUID; let viewport: StudioPreviewViewport }
    var attachments: [Attachment] = []
    var updates: [Update] = []
    var detachments: [UUID] = []
    func attachPreviewHost(_ layer: AVSampleBufferDisplayLayer, viewport: StudioPreviewViewport) -> UUID {
        let owner = UUID()
        attachments.append(Attachment(owner: owner, viewport: viewport, layer: layer))
        return owner
    }
    func updatePreviewViewport(_ viewport: StudioPreviewViewport, owner: UUID) { updates.append(Update(owner: owner, viewport: viewport)) }
    func detachPreviewHost(owner: UUID) { detachments.append(owner) }
}
