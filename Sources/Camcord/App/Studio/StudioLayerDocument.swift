import CoreGraphics
import Foundation
import Observation

@MainActor @Observable
final class StudioLayerDocument {
    private(set) var layers: [StudioLayer] = []
    var selectedID: UUID?
    private(set) var isRasterizing = false
    private(set) var issue: StudioIssue?
    private(set) var isReady = true
    private(set) var snapshot = StudioLayerSnapshot.empty
    @ObservationIgnored var onSnapshot: ((StudioLayerSnapshot) -> Void)?
    @ObservationIgnored var onReadinessChange: ((Bool) -> Void)?
    @ObservationIgnored private let rasterizer: StudioLayerRasterizer
    @ObservationIgnored private var assets: [UUID: CGImage] = [:]
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var rasterTask: Task<Void, Never>?
    @ObservationIgnored private var rasterTicket: StudioRasterTicket?

    init(rasterizer: StudioLayerRasterizer = .init()) { self.rasterizer = rasterizer }
    func dismissIssue() { issue = nil }

    func addText(_ text: String = String(localized: "Text", comment: "Studio new text layer")) {
        guard layers.count < rasterizer.limits.maximumLayers else { issue = .layerLimit; return }
        guard text.count <= rasterizer.limits.maximumTextCharacters else { issue = .textTooLong; return }
        let layer = StudioLayer(kind: .text, name: text.isEmpty ? String(localized: "Text", comment: "Studio new text layer") : String(text.prefix(160)), text: text)
        layers.append(layer)
        selectedID = layer.id
        changed()
    }

    func importImage(from url: URL, kind: StudioLayer.Kind = .image) async {
        guard kind != .text else { issue = .invalidImage; return }
        guard layers.count < rasterizer.limits.maximumLayers else { issue = .layerLimit; return }
        let token = revision
        do {
            let image = try await rasterizer.importImage(from: url)
            guard !Task.isCancelled, revision == token else { return }
            guard layers.count < rasterizer.limits.maximumLayers else { issue = .layerLimit; return }
            let used = assets.values.reduce(0) { $0 + $1.bytesPerRow * $1.height }
            let size = image.bytesPerRow * image.height
            guard size <= rasterizer.limits.maximumSnapshotBytes - used else { issue = .imageTooLarge; return }
            let layer = StudioLayer(kind: kind, name: String(url.deletingPathExtension().lastPathComponent.prefix(160)),
                                    rect: CGRect(x: 0.05, y: 0.05, width: 0.25, height: 0.25))
            assets[layer.id] = image
            layers.append(layer)
            selectedID = layer.id
            changed()
        } catch {
            guard revision == token else { return }
            issue = (error as? StudioIssue) ?? .invalidImage
        }
    }

    func update(_ id: UUID, _ change: (inout StudioLayer) -> Void) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        var layer = layers[index]
        change(&layer)
        guard layer.text.count <= rasterizer.limits.maximumTextCharacters else { issue = .textTooLong; return }
        layers[index] = layer.resolved()
        changed()
    }

    func remove(_ id: UUID) {
        layers.removeAll { $0.id == id }
        assets[id] = nil
        if selectedID == id { selectedID = nil }
        changed()
    }

    func move(_ id: UUID, to index: Int) {
        guard let old = layers.firstIndex(where: { $0.id == id }) else { return }
        let layer = layers.remove(at: old)
        layers.insert(layer, at: min(layers.count, max(0, index)))
        changed()
    }

    private func changed() {
        issue = nil
        revision = UUID()
        let token = revision
        rasterTask?.cancel()
        rasterTicket?.cancel()
        guard !layers.isEmpty else {
            isRasterizing = false
            isReady = true
            snapshot = .empty
            onSnapshot?(.empty)
            onReadinessChange?(true)
            return
        }
        isRasterizing = true
        isReady = false
        onReadinessChange?(false)
        let documentLayers = layers, documentAssets = assets
        let rasterizer = rasterizer
        let ticket = StudioRasterTicket()
        rasterTicket = ticket
        rasterTask = Task { [weak self] in
            do {
                let snapshot = try await rasterizer.snapshot(layers: documentLayers, assets: documentAssets,
                                                             shouldContinue: { ticket.isCurrent })
                guard let self, !Task.isCancelled, self.revision == token else { return }
                self.isRasterizing = false
                self.snapshot = snapshot
                self.onSnapshot?(snapshot)
                self.isReady = true
                self.onReadinessChange?(true)
            } catch {
                guard let self, !Task.isCancelled, self.revision == token else { return }
                self.isRasterizing = false
                self.issue = (error as? StudioIssue) ?? .invalidImage
            }
        }
    }
}
