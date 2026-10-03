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
        thumbnails = [:]
        guard !items.isEmpty else { return }
        let token = revision, loader = loadThumbnail
        request = Task { [weak self] in
            for item in items {
                let image = await loader(item)
                guard let self, !Task.isCancelled, self.visible,
                      self.revision == token, self.recent == items else { return }
                if let image { self.thumbnails[item.id] = image }
            }
        }
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
