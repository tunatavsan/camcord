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
    @Test("last capture dates preserve past/future direction in English and Turkish")
    func relativeCaptureDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let past = now.addingTimeInterval(-60), future = now.addingTimeInterval(60)
        let english = Locale(identifier: "en_US"), turkish = Locale(identifier: "tr_TR")
        let pastEnglish = PanelRelativeDate.string(for: past, relativeTo: now, locale: english)
        let futureEnglish = PanelRelativeDate.string(for: future, relativeTo: now, locale: english)
        let pastTurkish = PanelRelativeDate.string(for: past, relativeTo: now, locale: turkish)
        let futureTurkish = PanelRelativeDate.string(for: future, relativeTo: now, locale: turkish)
        #expect(pastEnglish.contains("ago"))
        #expect(futureEnglish.hasPrefix("in "))
        #expect(pastTurkish.contains("önce"))
        #expect(futureTurkish.contains("sonra"))
        #expect(pastEnglish != pastTurkish && futureEnglish != futureTurkish)
        #expect(!pastEnglish.contains("sec") && !pastTurkish.contains("sn"))
    }

    @Test("the capture palette stays compact in every recording state")
    func sizeTable() {
        #expect(CapturePanelView.panelWidth == 320)
        #expect(CapturePanelView.panelHeight == 370)
        // Recording status uses the same compact palette footprint as idle capture.
        #expect(CapturePanelView.activeHeight == CapturePanelView.panelHeight)
        for height in [CapturePanelView.panelHeight, CapturePanelView.activeHeight,
                       CapturePanelView.finishingHeight, CapturePanelView.finishedHeight] {
            #expect(height <= CapturePanelView.finishedHeight)
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

@Suite("Panel actual Library context", .serialized, .timeLimit(.minutes(1))) @MainActor
struct PanelContextTests {
    @Test("last capture uses canonical newest despite the Library's filter and opens its existing route")
    func canonicalNewestAndOpen() async throws {
        let f = try PanelContextFixture(); defer { f.close() }
        let old = try f.png("old.png"), newest = try f.png("new.png")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: newest.path)
        var opened: URL?
        let store = f.store(); store.onOpenScreenshot = { opened = $0 }
        await store.refresh(); store.search = "not a capture"; store.filter = .recording
        let context = PanelPresentation(library: store, defaults: f.defaults)
        context.synchronize(visible: true, reloadSettings: true)
        let item = try #require(context.latest)
        #expect(item.url == newest)
        #expect(store.filteredItems.isEmpty)
        await context.open(item)
        #expect(opened == newest)
        #expect(store.selection.isEmpty)
        context.synchronize(visible: false)
    }

    @Test("panel visibility leases once, releases while retained, and reloads supplied saved intent")
    func visibleLifetime() async throws {
        let f = try PanelContextFixture(); defer { f.close() }
        _ = try f.png("capture.png")
        let store = f.store(); await store.refresh()
        let context = PanelPresentation(library: store, defaults: f.defaults)
        #expect(store.watcherCount == 0)
        context.synchronize(visible: true, reloadSettings: true)
        context.synchronize(visible: true)
        #expect(store.watcherCount == 2)
        var settings = RecordingSettings(); settings.microphone = true; settings.camera.enabled = true
        settings.save(to: f.defaults)
        context.synchronize(visible: false)
        #expect(store.watcherCount == 0)
        #expect(context.thumbnail == nil)
        context.synchronize(visible: true, reloadSettings: true)
        #expect(context.settings?.microphone == true)
        #expect(context.settings?.camera.enabled == true)
        context.synchronize(visible: false)
        #expect(store.watcherCount == 0)
        let absent = PanelPresentation(library: nil, defaults: nil)
        absent.synchronize(visible: true, reloadSettings: true)
        #expect(absent.latest == nil && absent.settings == nil)
    }

    @Test("a late thumbnail from a hidden lifetime never enters the retained panel")
    func lateThumbnail() async throws {
        let f = try PanelContextFixture(); defer { f.close() }
        _ = try f.png("capture.png")
        let store = f.store(); await store.refresh()
        let gate = PanelThumbnailGate()
        let context = PanelPresentation(library: store, defaults: f.defaults, loadThumbnail: { _ in await gate.wait() })
        context.synchronize(visible: true)
        while !gate.started { try Task.checkCancellation(); await Task.yield() }
        context.synchronize(visible: false)
        gate.resume(try f.image())
        for _ in 0..<20 { await Task.yield() }
        #expect(context.thumbnail == nil)
        #expect(store.watcherCount == 0)
    }

    @Test("a superseded thumbnail cannot replace the new canonical capture")
    func supersededThumbnail() async throws {
        let f = try PanelContextFixture(); defer { f.close() }
        _ = try f.png("old.png")
        let store = f.store(); await store.refresh()
        let old = try #require(store.items.first)
        let gate = PanelThumbnailGate(), fresh = try f.image()
        let context = PanelPresentation(library: store, defaults: f.defaults, loadThumbnail: { item in
            item.id == old.id ? await gate.wait() : fresh
        })
        context.synchronize(visible: true)
        while !gate.started { try Task.checkCancellation(); await Task.yield() }
        let newest = try f.png("new.png")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: newest.path)
        await store.refresh()
        context.synchronize(visible: true)
        while context.thumbnail == nil { try Task.checkCancellation(); await Task.yield() }
        #expect(context.latest?.url == newest)
        gate.resume(try f.image())
        for _ in 0..<20 { await Task.yield() }
        #expect(context.thumbnail === fresh)
        context.synchronize(visible: false)
    }

    @Test("registered drag provider validates its frozen URL when the consumer requests it")
    func requestedDragValidation() async throws {
        let f = try PanelContextFixture(); defer { f.close() }
        let source = try f.png("capture.png")
        let store = f.store(); await store.refresh()
        let item = try #require(store.items.first)
        let drag = try #require(PanelCaptureDrag(item: item))
        let provider = drag.provider(), secondProvider = drag.provider()
        #expect(provider.suggestedName == "capture.png")
        #expect(provider.hasItemConformingToTypeIdentifier(drag.type.identifier))
        try FileManager.default.removeItem(at: source)
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<(URL?, Bool), Never>) in
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: drag.type.identifier) { url, _, error in
                continuation.resume(returning: (url, error != nil))
            }
        }
        #expect(result.0 == nil && result.1)
        let other = try f.png("other.png", directory: f.root)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: other)
        let replacement = await withCheckedContinuation { (continuation: CheckedContinuation<(URL?, Bool), Never>) in
            secondProvider.loadInPlaceFileRepresentation(forTypeIdentifier: drag.type.identifier) { url, _, error in
                continuation.resume(returning: (url, error != nil))
            }
        }
        #expect(replacement.0 == nil && replacement.1)
    }

    @Test("immutable drag requests reject a deleted file or replacement symlink")
    func validatedDrag() async throws {
        let f = try PanelContextFixture(); defer { f.close() }
        let source = try f.png("capture.png"), other = try f.png("outside.png", directory: f.root)
        let store = f.store(); await store.refresh()
        let item = try #require(store.items.first)
        let drag = try #require(PanelCaptureDrag(item: item))
        #expect(try drag.validatedURL() == source)
        try FileManager.default.removeItem(at: source)
        #expect(throws: (any Error).self) { try drag.validatedURL() }
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: other)
        #expect(throws: (any Error).self) { try drag.validatedURL() }
        #expect(drag.url == source)
        #expect(drag.type.identifier == "public.png")
    }
}

@MainActor private final class PanelThumbnailGate {
    var started = false
    var continuation: CheckedContinuation<CGImage?, Never>?
    func wait() async -> CGImage? {
        await withCheckedContinuation { continuation = $0; started = true }
    }
    func resume(_ image: CGImage) { continuation?.resume(returning: image); continuation = nil }
}

@MainActor private struct PanelContextFixture {
    let root: URL, saved: URL, cache: URL
    let suite = "camcord.panel-context." + UUID().uuidString
    let defaults: UserDefaults
    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: try #require(LibraryFiles.physicalPath(raw)))
        saved = root.appendingPathComponent("saved"); cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }
    func close() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    func store() -> LibraryStore { LibraryStore(defaults: defaults, roots: [.init(url: saved, origin: .savedFile)], cacheDirectory: cache) }
    func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
        return try #require(context.makeImage())
    }
    func png(_ name: String, directory: URL? = nil) throws -> URL {
        let url = (directory ?? saved).appendingPathComponent(name)
        try EditorRendered(image: image(), pointSize: CGSize(width: 16, height: 8)).png.write(to: url)
        return url
    }
}
