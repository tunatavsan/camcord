import AppKit
import Observation
@preconcurrency import ScreenCaptureKit

/// One bounded batch at a time. A cancelled, noncooperative screenshot can never publish
/// into a newer source/visibility epoch, nor can hiding start a replacement batch.
@MainActor @Observable
final class StudioSourceThumbnails {
    struct Operations {
        var batch: ([StudioSourceChoice], Int) async -> [StudioSourceChoice.ID: CGImage]
        var pause: () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }
    }

    static let maximumDimension = 240
    private(set) var images: [StudioSourceChoice.ID: NSImage] = [:]
    @ObservationIgnored private let operations: Operations
    @ObservationIgnored private var choices: [StudioSourceChoice] = []
    @ObservationIgnored private var visibleIDs = Set<StudioSourceChoice.ID>()
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var lastBatch: ContinuousClock.Instant?

    init(operations: Operations) { self.operations = operations }

    func update(choices: [StudioSourceChoice], visible: Bool) {
        let ids = Set(choices.map(\.id))
        self.choices = choices
        self.visible = visible
        visibleIDs.formIntersection(ids)
        images = visible ? images.filter { ids.contains($0.key) } : [:]
        invalidate()
    }

    func setTileVisible(_ id: StudioSourceChoice.ID, _ shown: Bool) {
        let before = visibleIDs
        if shown, choices.contains(where: { $0.id == id }) { visibleIDs.insert(id) }
        else { visibleIDs.remove(id) }
        if before != visibleIDs { invalidate() }
    }

    private func invalidate() {
        generation = UUID()
        worker?.cancel()
        // Keep the slot until a noncooperative operation has actually returned.
        if worker == nil { startIfNeeded() }
    }

    private func startIfNeeded() {
        guard visible, !visibleIDs.isEmpty, worker == nil else { return }
        let token = generation
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.visible, self.generation == token {
                let selected = self.choices.filter { self.visibleIDs.contains($0.id) }
                guard !selected.isEmpty else { break }
                if let lastBatch = self.lastBatch {
                    do { try await Task.sleep(until: lastBatch + .seconds(2)) } catch { break }
                }
                guard !Task.isCancelled, self.visible, self.generation == token else { break }
                self.lastBatch = ContinuousClock.now
                let result = await self.operations.batch(selected, Self.maximumDimension)
                guard !Task.isCancelled, self.visible, self.generation == token else { break }
                for choice in selected where self.visibleIDs.contains(choice.id)
                    && self.choices.contains(where: { $0.id == choice.id }) {
                    if let raster = result[choice.id], raster.width <= Self.maximumDimension,
                       raster.height <= Self.maximumDimension {
                        self.images[choice.id] = NSImage(cgImage: raster, size: .zero)
                    } else { self.images[choice.id] = nil }
                }
                do { try await self.operations.pause() } catch { break }
            }
            self.worker = nil
            self.startIfNeeded()
        }
    }

    static func rasterSize(_ size: CGSize, maximum: Int) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(1, CGFloat(maximum) / max(size.width, size.height))
        return CGSize(width: max(2, floor(size.width * scale)), height: max(2, floor(size.height * scale)))
    }

    /// Filters and source rectangles come only from the accepted content cache snapshot.
    static func capture(_ choices: [StudioSourceChoice], content: SCShareableContent,
                        maximum: Int) async -> [StudioSourceChoice.ID: CGImage] {
        var result: [StudioSourceChoice.ID: CGImage] = [:]
        let ownApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        for choice in choices {
            guard !Task.isCancelled else { break }
            let filter: SCContentFilter
            let configuration = SCStreamConfiguration()
            switch choice.id {
            case .window(let id):
                guard let window = content.windows.first(where: { $0.windowID == id }) else { continue }
                filter = SCContentFilter(desktopIndependentWindow: window)
                configuration.ignoreShadowsSingleWindow = true
            case .display(let id), .region(let id):
                guard let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                filter = ownApp.map { SCContentFilter(display: display, excludingApplications: [$0], exceptingWindows: []) }
                    ?? SCContentFilter(display: display, excludingWindows: [])
                if case .region = choice.id {
                    let crop = choice.frame.intersection(display.frame)
                    guard !crop.isEmpty else { continue }
                    configuration.sourceRect = crop.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                }
            }
            let size = rasterSize(configuration.sourceRect.isEmpty ? filter.contentRect.size : configuration.sourceRect.size,
                                  maximum: maximum)
            guard size.width >= 2, size.height >= 2 else { continue }
            configuration.width = Int(size.width)
            configuration.height = Int(size.height)
            configuration.showsCursor = false
            configuration.capturesAudio = false
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                result[choice.id] = image
            }
        }
        return result
    }
}
