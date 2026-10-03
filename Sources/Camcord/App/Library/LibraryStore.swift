import AppKit
import Observation

@MainActor @Observable
final class LibraryStore: CaptureLibraryStore {
    private(set) var items = [CaptureItem]()
    private(set) var isLoading = false
    private(set) var loadingIssue: String?
    var issue: String?
    var selection = Set<String>()
    var search = ""
    var filter: CaptureItem.Kind?
    var showsInspector = true
    var usesGrid = true
    /// Return only after the editor has accepted the document. Nil is an honest unavailable state.
    @ObservationIgnored var onOpenScreenshot: (@MainActor (URL) async throws -> Void)?
    @ObservationIgnored var claimClipboardPublication: (@MainActor () -> (@MainActor () -> Bool))?
    @ObservationIgnored private var localClipboardRequests = LatestRequestGate()
    @ObservationIgnored private var openRequests = LatestRequestGate()
    @ObservationIgnored private let validateOpen: @Sendable (URL, CaptureItem.Kind) async -> Bool
    @ObservationIgnored let thumbnails = LibraryThumbnails()
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let cacheDirectory: URL
    @ObservationIgnored private let fixedRoots: [LibraryFiles.Root]?
    @ObservationIgnored private let disk: LibraryDisk
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let scanner: @Sendable ([LibraryFiles.Root]) async throws -> [CaptureItem]
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var scanTask: Task<[CaptureItem], Error>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var watchers = [DispatchSourceFileSystemObject]()
    @ObservationIgnored private var visibleTokens = Set<UUID>()
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private var delivery = [UUID: DeliveryState]()
    @ObservationIgnored private var deliveryOrder = [UUID]()
    @ObservationIgnored private var cacheTasks = [UUID: Task<Void, Never>]()
    @ObservationIgnored private var pendingPixels = [UUID: Int]()
    @ObservationIgnored private var lastConfiguration: Configuration?
    private struct Configuration: Equatable { let paths: [String]; let settings: LibrarySettings }
    private var configuration: Configuration {
        Configuration(paths: roots.map { $0.origin.rawValue + ":" + $0.url.path }, settings: LibrarySettings.load(from: defaults))
    }
    private struct DeliveryState { var saved = false; var failed = false; var scheduled = false }

    init(defaults: UserDefaults, roots: [LibraryFiles.Root]? = nil,
         cacheDirectory: URL = LibrarySettings.cacheDirectory(), operations: LibraryDisk.Operations = .init(),
         clock: @escaping @Sendable () -> Date = { Date() },
         scanner: @escaping @Sendable ([LibraryFiles.Root]) async throws -> [CaptureItem] = { try await LibraryFiles.scan($0) },
         onOpenScreenshot: (@MainActor (URL) async throws -> Void)? = nil,
         validateOpen: @escaping @Sendable (URL, CaptureItem.Kind) async -> Bool = { url, kind in
             await Task.detached(priority: .userInitiated) {
                 guard (try? LibraryFiles.regularFile(url, in: url.deletingLastPathComponent())) == true else { return false }
                 if kind == .recording { return true }
                 guard let bytes = try? LibraryFiles.byteSize(url), bytes > 0,
                       Int64(bytes) <= LibraryFiles.maxSourceBytes else { return false }
                 return LibraryFiles.imageSize(url, pixelLimit: LibraryFiles.maxFullImagePixels) != nil
             }.value
         }) {
        self.defaults = defaults
        self.fixedRoots = roots
        self.cacheDirectory = cacheDirectory
        self.disk = LibraryDisk(operations: operations)
        self.clock = clock
        self.scanner = scanner
        self.onOpenScreenshot = onOpenScreenshot
        self.validateOpen = validateOpen
        lastConfiguration = configuration
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object: defaults, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.defaultsChanged() }
            }
    }
    isolated deinit {
        scanTask?.cancel(); refreshTask?.cancel()
        for task in cacheTasks.values { task.cancel() }
        for watcher in watchers { watcher.cancel() }
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }
    var roots: [LibraryFiles.Root] {
        let saved: [LibraryFiles.Root]
        if let fixedRoots { saved = fixedRoots } else {
            let dirs = CaptureLibrary.directories(recordingSettings: RecordingSettings.load(from: defaults),
                                                  screenshotSettings: ScreenshotSettings.load(from: defaults))
            saved = [.init(url: dirs.screenshot, origin: .savedFile), .init(url: dirs.recording, origin: .savedFile)]
        }
        // Cache origin takes precedence if a user selects the cache as a saved destination.
        var seen = Set<String>()
        return ([LibraryFiles.Root(url: cacheDirectory, origin: .clipboardCache)] + saved).compactMap {
            let root = LibraryFiles.Root(url: $0.url, origin: $0.origin)
            return seen.insert(root.url.path).inserted ? root : nil
        }
    }
    var filteredItems: [CaptureItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { (filter == nil || $0.kind == filter) && (query.isEmpty || $0.title.localizedStandardContains(query)) }
    }
    var selectedItems: [CaptureItem] { items.filter { selection.contains($0.id) } }

    func refresh() async {
        generation &+= 1
        let revision = generation
        scanTask?.cancel()
        isLoading = true
        let roots = roots, scanner = scanner, disk = disk, cache = cacheDirectory, now = clock()
        let settings = LibrarySettings.load(from: defaults)
        lastConfiguration = configuration
        let task = Task.detached(priority: .utility) { () async throws -> [CaptureItem] in
            try await disk.retain(directory: cache, settings: settings, now: now)
            return try await scanner(roots)
        }
        scanTask = task
        do {
            let snapshot = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard revision == generation, !Task.isCancelled else { return }
            loadingIssue = nil
            items = snapshot
            selection.formIntersection(Set(snapshot.map(\.id)))
            isLoading = false
        } catch {
            guard revision == generation else { return }
            isLoading = false
            if !(error is CancellationError) { loadingIssue = error.localizedDescription; issue = error.localizedDescription }
        }
        if revision == generation { scanTask = nil; rebuildWatchers() }
    }
    private func defaultsChanged() {
        let current = configuration
        guard current != lastConfiguration else { return }
        lastConfiguration = current
        scheduleRefresh()
    }
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self else { return }
            await self.refresh()
        }
    }
    /// The view's visibility owns the watch subscription; capture events still refresh while hidden.
    @discardableResult func acquireVisibility() -> UUID {
        let token = UUID(); visibleTokens.insert(token)
        if visibleTokens.count == 1 { rebuildWatchers(); scheduleRefresh() }
        return token
    }
    func releaseVisibility(_ token: UUID) {
        visibleTokens.remove(token)
        if visibleTokens.isEmpty { for watcher in watchers { watcher.cancel() }; watchers.removeAll(); Task { await thumbnails.removeAll() } }
    }
    var watcherCount: Int { watchers.count }
    private func rebuildWatchers() {
        for watcher in watchers { watcher.cancel() }
        watchers.removeAll()
        guard !visibleTokens.isEmpty else { return }
        for root in roots {
            guard (try? LibraryFiles.validateDirectory(root.url)) != nil else { continue }
            let descriptor = Darwin.open(root.url.path, O_EVTONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
            source.setCancelHandler { close(descriptor) }
            watchers.append(source); source.resume()
        }
    }
    func ingest(_ event: ScreenshotDeliveryEvent) {
        let capture: CapturedScreenshot
        switch event { case .ready(let value), .saved(let value, _), .saveFailed(let value): capture = value }
        if delivery[capture.id] == nil { delivery[capture.id] = DeliveryState(); deliveryOrder.append(capture.id) }
        var state = delivery[capture.id]!
        switch event {
        case .saved:
            state.saved = true
            delivery[capture.id] = state
            scheduleRefresh()
        case .ready:
            if !capture.saveToDiskRequested || state.failed { scheduleCache(capture, state: &state) }
            delivery[capture.id] = state
        case .saveFailed:
            state.failed = true
            issue = String(localized: "Couldn't save the screenshot. Camcord will keep a Library copy if copied captures are enabled.")
            scheduleCache(capture, state: &state)
            delivery[capture.id] = state
        }
        // Keep delivery dedup state bounded without evicting in-flight tasks.
        pruneDeliveryState()
    }
    private func pruneDeliveryState() {
        while deliveryOrder.count > 512, let index = deliveryOrder.firstIndex(where: { cacheTasks[$0] == nil }) {
            let id = deliveryOrder.remove(at: index); delivery.removeValue(forKey: id)
        }
    }
    var pendingCacheWriteCount: Int { cacheTasks.count }
    func waitForPendingCacheWrites() async {
        while !cacheTasks.isEmpty { for task in Array(cacheTasks.values) { await task.value } }
    }
    /// The screenshot card's Add to Library: keeps this one capture even when copied
    /// captures are not kept by themselves.
    func keep(_ capture: CapturedScreenshot) {
        if delivery[capture.id] == nil { delivery[capture.id] = DeliveryState(); deliveryOrder.append(capture.id) }
        var state = delivery[capture.id]!
        scheduleCache(capture, state: &state, force: true)
        delivery[capture.id] = state
        pruneDeliveryState()
    }
    private func scheduleCache(_ capture: CapturedScreenshot, state: inout DeliveryState, force: Bool = false) {
        guard !state.saved, !state.scheduled else { return }
        let settings = LibrarySettings.load(from: defaults)
        guard force || settings.keepCopied else { return }
        guard capture.image.width > 0, capture.image.height > 0,
              capture.image.width <= LibraryFiles.maxFullImagePixels / capture.image.height else {
            issue = LibraryFiles.Failure.unsupportedImage.localizedDescription; return
        }
        let pixels = capture.image.width * capture.image.height
        guard cacheTasks.count < 4, pixels <= 100_000_000 - pendingPixels.values.reduce(0, +) else {
            issue = String(localized: "The Library is busy keeping recent captures. This capture is still on the clipboard."); return
        }
        state.scheduled = true
        pendingPixels[capture.id] = pixels
        let directory = cacheDirectory, disk = disk, now = clock()
        cacheTasks[capture.id] = Task { [weak self] in
            do {
                _ = try await disk.cache(id: capture.id, image: capture.image, pointSize: capture.pointSize,
                                         kind: capture.kind, directory: directory, settings: settings, now: now)
                await self?.refresh()
            } catch { self?.issue = error.localizedDescription }
            self?.cacheTasks.removeValue(forKey: capture.id)
            self?.pendingPixels.removeValue(forKey: capture.id)
            self?.pruneDeliveryState()
        }
    }
    func enforceRetention() async {
        do { try await disk.retain(directory: cacheDirectory, settings: LibrarySettings.load(from: defaults), now: clock()) }
        catch { issue = error.localizedDescription }
        await refresh()
    }
    func delete(_ ids: Set<String>) async throws {
        let targets = items.filter { ids.contains($0.id) }, roots = roots
        var errors = [String]()
        for item in targets {
            do { try await disk.delete(item, roots: roots) }
            catch { errors.append(item.title + ": " + error.localizedDescription) }
        }
        await refresh()
        if !errors.isEmpty { throw ActionFailure(message: errors.joined(separator: "\n")) }
    }
    func rename(_ id: String, to name: String) async throws {
        guard let item = items.first(where: { $0.id == id }) else { throw LibraryFiles.Failure.unsafePath }
        let wasSelected = selection.contains(id)
        let destination = try await disk.rename(item, name: name, roots: roots)
        let nextID = CaptureFileRules.id(for: destination, origin: item.origin)
        await refresh()
        if wasSelected { selection.remove(id); selection.insert(nextID) }
    }
    func open(_ item: CaptureItem) async {
        let token = openRequests.begin()
        do {
            let valid = await validateOpen(item.url, item.kind)
            guard !Task.isCancelled, openRequests.isCurrent(token) else { return }
            guard valid else { throw LibraryFiles.Failure.unsupportedImage }
            if item.kind == .recording {
                guard NSWorkspace.shared.open(item.url) else { throw LibraryFiles.Failure.unsafePath }
            } else {
                guard let onOpenScreenshot else {
                    issue = String(localized: "The screenshot editor is not available yet. Use Quick Look to preview this capture.")
                    return
                }
                try await onOpenScreenshot(item.url)
            }
        } catch { if !Task.isCancelled, openRequests.isCurrent(token) { issue = error.localizedDescription } }
    }
    func openDroppedImage(_ url: URL) async {
        let token = openRequests.begin()
        do {
            let accepted = await validateOpen(url, .screenshot)
            guard !Task.isCancelled, openRequests.isCurrent(token) else { return }
            guard accepted else { throw LibraryFiles.Failure.unsupportedImage }
            guard let onOpenScreenshot else {
                issue = String(localized: "The screenshot editor is not available yet. Use Quick Look to preview this capture.")
                return
            }
            try await onOpenScreenshot(url)
        } catch { if !Task.isCancelled, openRequests.isCurrent(token) { issue = error.localizedDescription } }
    }
    func copySelection(to pasteboard: NSPasteboard = .general) async {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        let publish: @MainActor () -> Bool
        if let claimClipboardPublication { publish = claimClipboardPublication() }
        else {
            let token = localClipboardRequests.begin()
            publish = { [weak self] in self?.localClipboardRequests.isCurrent(token) == true }
        }
        let safe = await Task.detached(priority: .userInitiated) {
            targets.allSatisfy { (try? LibraryFiles.regularFile($0.url, in: $0.url.deletingLastPathComponent())) == true }
        }.value
        guard !Task.isCancelled, publish() else { return }
        guard safe else { issue = LibraryFiles.Failure.unsafePath.localizedDescription; return }
        if targets.count == 1, let item = targets.first, item.kind != .recording {
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard (try? LibraryFiles.regularFile(item.url, in: item.url.deletingLastPathComponent())) == true,
                      let bytes = try? LibraryFiles.byteSize(item.url),
                      bytes > 0, Int64(bytes) <= LibraryFiles.maxSourceBytes,
                      LibraryFiles.imageSize(item.url, pixelLimit: LibraryFiles.maxFullImagePixels) != nil else { return nil }
                return try? Data(contentsOf: item.url, options: .mappedIfSafe)
            }.value
            guard !Task.isCancelled, publish() else { return }
            guard let data else { issue = LibraryFiles.Failure.unsupportedImage.localizedDescription; return }
            pasteboard.clearContents()
            guard pasteboard.setData(data, forType: .png) else { issue = String(localized: "Couldn't copy the selected captures."); return }
        } else {
            guard !Task.isCancelled, publish() else { return }
            pasteboard.clearContents()
            if !pasteboard.writeObjects(targets.map { $0.url as NSURL }) { issue = String(localized: "Couldn't copy the selected captures.") }
        }
    }
    struct ActionFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
