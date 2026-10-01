import AppKit
import Observation
import UniformTypeIdentifiers

/// Read-only panel context. A retained popover host is not evidence of visibility.
@MainActor @Observable
final class PanelPresentation {
    let library: LibraryStore?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let loadThumbnail: @MainActor (CaptureItem) async -> CGImage?
    @ObservationIgnored private var lease: UUID?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var requestItem: CaptureItem?
    @ObservationIgnored private var revision: UInt64 = 0
    private(set) var visible = false
    private(set) var settings: RecordingSettings?
    private(set) var thumbnail: CGImage?

    var latest: CaptureItem? { visible ? library?.items.first : nil }

    init(library: LibraryStore?, defaults: UserDefaults?,
         loadThumbnail: (@MainActor (CaptureItem) async -> CGImage?)? = nil) {
        self.library = library
        self.defaults = defaults
        self.loadThumbnail = loadThumbnail ?? { [weak library] item in
            await library?.thumbnails.image(for: item, edge: 240)
        }
    }

    isolated deinit {
        request?.cancel()
        if let lease { library?.releaseVisibility(lease) }
    }

    func synchronize(visible: Bool, reloadSettings: Bool = false) {
        self.visible = visible
        if visible {
            if lease == nil { lease = library?.acquireVisibility() }
            if reloadSettings { settings = defaults.map { RecordingSettings.load(from: $0) } }
        } else if let lease {
            library?.releaseVisibility(lease)
            self.lease = nil
        }
        let item = latest
        guard item != requestItem else { return }
        revision &+= 1
        request?.cancel()
        request = nil
        requestItem = item
        thumbnail = nil
        guard let item else { return }
        let token = revision, loader = loadThumbnail
        request = Task { [weak self] in
            let image = await loader(item)
            guard let self, !Task.isCancelled, self.visible,
                  self.revision == token, self.latest == item else { return }
            self.thumbnail = image
        }
    }

    func open(_ item: CaptureItem) async { await library?.open(item) }
}

/// A drag freezes its file identity; later Library selection and refreshes cannot redirect it.
struct PanelCaptureDrag: Sendable {
    let url: URL
    let type: UTType
    let suggestedName: String

    init?(item: CaptureItem) {
        guard let type = UTType(filenameExtension: item.url.pathExtension), !type.isDynamic,
              type.conforms(to: .image) || type.conforms(to: .movie) else { return nil }
        url = item.url
        self.type = type
        suggestedName = item.url.lastPathComponent
    }

    func validatedURL() throws -> URL {
        guard try LibraryFiles.regularFile(url, in: url.deletingLastPathComponent()) else {
            throw LibraryFiles.Failure.unsafePath
        }
        return url
    }

    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = suggestedName
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier,
                                            fileOptions: .openInPlace, visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            let task = Task.detached {
                do {
                    try Task.checkCancellation()
                    let file = try validatedURL()
                    try Task.checkCancellation()
                    guard !progress.isCancelled else { throw CancellationError() }
                    completion(file, true, nil)
                    progress.completedUnitCount = 1
                } catch { completion(nil, false, error) }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }
}
