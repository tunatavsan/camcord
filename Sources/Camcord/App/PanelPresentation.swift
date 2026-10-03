import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum PanelRecordingSource: String, CaseIterable, Identifiable {
    case region, window, screen
    var id: Self { self }
    var label: LocalizedStringKey {
        switch self { case .region: "Region"; case .window: "Window"; case .screen: "Screen" }
    }
    var symbol: String {
        switch self { case .region: "rectangle.dashed"; case .window: "macwindow"; case .screen: "display" }
    }
    @MainActor func start(using actions: PanelActions) {
        switch self {
        case .region: actions.toggleRecording()
        case .window: actions.recordWindow()
        case .screen: actions.recordFullScreen()
        }
    }
}

/// Panel-local setup and recent captures. A retained host is not evidence of visibility.
@MainActor @Observable
final class PanelPresentation {
    let library: LibraryStore?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let loadThumbnail: @MainActor (CaptureItem) async -> CGImage?
    @ObservationIgnored private var lease: UUID?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var requestedItems = [CaptureItem]()
    @ObservationIgnored private var revision: UInt64 = 0
    /// Thumbnails outlive the panel: reopening shows them at once and loads only what is new.
    @ObservationIgnored private var cache = [String: CGImage]()
    private(set) var visible = false
    private(set) var settings: RecordingSettings?
    private(set) var thumbnails = [String: CGImage]()
    private(set) var recordingSource: PanelRecordingSource = .region

    var latest: CaptureItem? { visible ? library?.items.first : nil }
    static let recentLimit = 12
    var recent: [CaptureItem] { visible ? Array(library?.items.prefix(Self.recentLimit) ?? []) : [] }
    var thumbnail: CGImage? { latest.flatMap { thumbnails[$0.id] } }

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
        let items = recent
        guard items != requestedItems else { return }
        revision &+= 1
        request?.cancel()
        request = nil
        requestedItems = items
        thumbnails = Dictionary(uniqueKeysWithValues: items.compactMap { item in cache[item.id].map { (item.id, $0) } })
        let missing = items.filter { cache[$0.id] == nil }
        guard !missing.isEmpty else { return }
        let token = revision
        request = Task { [weak self] in
            await self?.load(missing) { [weak self] item, image in
                guard let self, self.visible, self.revision == token, self.recent == items else { return }
                self.thumbnails[item.id] = image
            }
        }
    }

    /// Loads in parallel, newest first, into the cache; `arrived` sees each one as it lands.
    private func load(_ items: [CaptureItem], arrived: @escaping @MainActor (CaptureItem, CGImage) -> Void) async {
        let loader = loadThumbnail
        // Started in order on the main actor, so the newest is asked for first.
        let requests = items.map { item in Task { @MainActor in (item, await loader(item)) } }
        for request in requests {
            let (item, image) = await request.value
            guard !Task.isCancelled else { return }
            guard let image else { continue }
            cache[item.id] = image
            arrived(item, image)
        }
        trimCache()
    }

    /// Keeps the cache to the captures the panel could show soon.
    private func trimCache() {
        let keep = Set(library?.items.prefix(Self.recentLimit * 2).map(\.id) ?? [])
        cache = cache.filter { keep.contains($0.key) }
    }

    /// Before the panel ever opens: thumbnails for the newest captures, ready in the cache.
    func prewarm() async {
        guard let items = library?.items.prefix(Self.recentLimit) else { return }
        await load(items.filter { cache[$0.id] == nil }) { _, _ in }
    }

    func selectSource(_ source: PanelRecordingSource, canConfigure: Bool) {
        guard visible, canConfigure else { return }
        recordingSource = source
    }

    func startRecording(using actions: PanelActions) {
        guard visible else { return }
        recordingSource.start(using: actions)
    }

    func toggleCamera(canConfigure: Bool) {
        guard visible, canConfigure, let defaults else { return }
        var settings = RecordingSettings.load(from: defaults)
        settings.camera.enabled.toggle()
        settings.save(to: defaults)
        self.settings = settings
    }

    func toggleMicrophone(canConfigure: Bool) {
        guard visible, canConfigure, let defaults else { return }
        var settings = RecordingSettings.load(from: defaults)
        settings.microphone.toggle()
        settings.save(to: defaults)
        self.settings = settings
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
