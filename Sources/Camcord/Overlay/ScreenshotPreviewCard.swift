import AppKit
import Darwin
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// Each immutable capture owns its own presentation and active dismissal budget.
@MainActor final class ScreenshotPreviewCard {
    typealias Presenter = @MainActor (NSWindow) -> Void
    typealias HostFactory = @MainActor (CGRect) -> NSWindow
    typealias DisplayFrames = @MainActor () -> [(id: CGDirectDisplayID, visibleFrame: CGRect)]
    typealias Animator = @MainActor (ScreenshotCardPresentation, Bool, Bool, @escaping @MainActor () -> Void) -> Void
    struct Timing {
        var now: @MainActor () -> TimeInterval = { CACurrentMediaTime() }
        var sleep: @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    }
    final class Entry {
        let model: ScreenshotCardModel
        let generation: UInt64
        let window: NSWindow
        let host: ScreenshotCardPresentation
        let visibleFrame: CGRect
        var dwell = ScreenshotCardDwell()
        var task: Task<Void, Never>?
        var shownAt: TimeInterval
        var enteredAt: TimeInterval?
        var exitAt: TimeInterval?
        var orderedOutAt: TimeInterval?
        var dismissReason: String?
        init(model: ScreenshotCardModel, generation: UInt64, window: NSWindow,
             host: ScreenshotCardPresentation, visibleFrame: CGRect, now: TimeInterval) {
            self.model = model; self.generation = generation; self.window = window
            self.host = host; self.visibleFrame = visibleFrame; shownAt = now
        }
    }
    var onEdit: (@MainActor (CapturedScreenshot) -> Void)?
    /// Keeps a capture in the Library when screenshots are not kept by themselves.
    var onKeep: (@MainActor (CapturedScreenshot) -> Void)?
    var claimClipboardPublication: (@MainActor () -> (@MainActor () -> Bool))?
    private(set) var entries: [Entry] = []
    var model: ScreenshotCardModel? { entries.last?.model }
    private var nextGeneration: UInt64 = 0
    private let presenter: Presenter
    private let hostFactory: HostFactory
    private let animator: Animator
    private let screenFrame: @MainActor () -> CGRect?
    private let displayFrames: DisplayFrames
    private let usesFixtureFrame: Bool
    private let enabled: @MainActor () -> Bool
    private let reduceMotion: @MainActor () -> Bool
    private let timing: Timing
    private let operations: ScreenshotCardModel.Operations
    private let keepsInLibrary: @MainActor () -> Bool
    let preview = ScreenshotPreviewWindow()
    private static var hasCleanedExports = false
    /// Visible space between stacked cards; their shadow margins overlap.
    static let stackGap: CGFloat = 10
    static func capacity(for visible: CGRect) -> Int {
        let card = ScreenshotCardGeometry.card.height, inset = ScreenshotCardGeometry.shadowInset
        return max(1, min(3, Int((visible.height - 2 * inset + stackGap) / (card + stackGap))))
    }
    init(presenter: Presenter? = nil, screenFrame: (@MainActor () -> CGRect?)? = nil,
         operations: ScreenshotCardModel.Operations = .init(), hostFactory: HostFactory? = nil,
         animator: Animator? = nil, timing: Timing = .init(), displayFrames: DisplayFrames? = nil,
         enabled: @escaping @MainActor () -> Bool = { HUDToast.isEnabled() },
         reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         keepsInLibrary: @escaping @MainActor () -> Bool = { LibrarySettings.load(from: .standard).keepCopied }) {
        self.keepsInLibrary = keepsInLibrary
        self.presenter = presenter ?? { $0.orderFrontRegardless() }
        self.hostFactory = hostFactory ?? { frame in
            let panel = ScreenshotCardPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            return panel
        }
        self.animator = animator ?? { host, entering, reduced, completion in host.animate(entering: entering, reduceMotion: reduced, completion: completion) }
        self.screenFrame = screenFrame ?? {
            (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame
        }
        self.displayFrames = displayFrames ?? {
            NSScreen.screens.compactMap { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                return (number.uint32Value, screen.visibleFrame)
            }
        }
        usesFixtureFrame = screenFrame != nil && displayFrames == nil
        self.operations = operations; self.timing = timing; self.enabled = enabled; self.reduceMotion = reduceMotion
    }
    func show(capture: CapturedScreenshot) {
        guard enabled(), let visible = visibleFrame(for: capture) else { return }
        if !Self.hasCleanedExports {
            Self.hasCleanedExports = true
            let exports = operations.exports
            Task.detached(priority: .background) { exports.cleanup(); ScreenshotDragFiles.cleanup() }
        }
        // A repeated delivery never resets an existing capture's clock.
        guard !entries.contains(where: { $0.model.capture.id == capture.id }) else { return }
        // Every card keeps its size: the oldest leaves when the display has no room for another.
        let capacity = Self.capacity(for: visible)
        while let oldest = entries.first(where: { $0.visibleFrame == visible }),
              entries.filter({ $0.visibleFrame == visible }).count >= capacity {
            dismiss(oldest, reason: "evicted", animated: false)
        }
        if entries.count == 3 { dismiss(entries[0], reason: "evicted", animated: false) }
        nextGeneration &+= 1
        let generation = nextGeneration
        let model = ScreenshotCardModel(capture: capture, operations: operations)
        let size = ScreenshotCardGeometry.window
        let frame = CGRect(x: visible.maxX - size.width, y: visible.minY, width: size.width, height: size.height)
        let window = hostFactory(frame)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.animationBehavior = .none; window.isReleasedWhenClosed = false
        // A capture saved to disk is in the Library through its folder, whatever the Library keeps.
        let host = ScreenshotCardPresentation(model: model, copied: capture.copiedToClipboard,
                                              kept: capture.saveToDiskRequested || keepsInLibrary(), canEdit: onEdit != nil)
        let entry = Entry(model: model, generation: generation, window: window, host: host, visibleFrame: visible, now: timing.now())
        let current: @MainActor () -> Bool = { [weak self, weak entry] in
            guard let self, let entry else { return false }
            return self.isCurrent(entry, generation: generation)
        }
        model.claimClipboardPublication = { [weak self, weak model] in self?.claimClipboardPublication?() ?? model?.claimLocalPublication() ?? { false } }
        model.onBusyChange = { [weak self, weak entry] in
            guard current(), let self, let entry else { return }
            self.pause(entry, reason: .busy, active: model.isBusy)
            self.reflow()
        }
        model.onContentChange = { [weak self] in if current() { self?.reflow() } }
        host.onPause = { [weak self, weak entry] reason, active in
            guard current(), let self, let entry else { return }
            self.pause(entry, reason: reason, active: active)
        }
        host.onDismiss = { [weak self, weak entry] reason in
            guard current(), let self, let entry else { return }
            self.dismiss(entry, reason: reason)
        }
        host.onEdit = { [weak self, weak entry] in
            guard current(), let self, let entry, let edit = self.onEdit else { return }
            edit(capture); self.dismiss(entry, reason: "edit")
        }
        host.onKeep = { [weak self] in if current() { self?.onKeep?(capture) } }
        host.onOpen = { [weak self, weak entry] in
            guard current(), let self, let entry else { return }
            self.openPreview(capture, on: entry.visibleFrame, from: Self.cardRect(of: entry))
            self.dismiss(entry, reason: "preview")
        }
        host.onPin = { [weak self, weak entry] in
            guard current(), let self, let entry else { return }
            self.openPreview(capture, on: entry.visibleFrame, pinned: true, from: Self.cardRect(of: entry))
            self.dismiss(entry, reason: "pin")
        }
        window.contentView = host
        entries.append(entry)
        reflow()
        presenter(window)
        fly(capture, into: entry)
        animator(host, true, reduceMotion()) { [weak self, weak entry] in
            guard current(), let self, let entry else { return }
            entry.enteredAt = self.timing.now()
            entry.dwell.enter(at: self.timing.now())
            self.arm(entry)
        }
    }
    private func visibleFrame(for capture: CapturedScreenshot) -> CGRect? {
        // Explicit legacy fixture geometry overrides native displays. In production the
        // request's frozen display ID selects its current visible frame, including Dock changes.
        if !usesFixtureFrame, let id = capture.originDisplayID,
           let matching = displayFrames().first(where: { $0.id == id }) { return matching.visibleFrame }
        // Imports and a display removed during capture retain the documented cursor fallback.
        return screenFrame()
    }
    func saved(id: UUID, to url: URL) { entries.first { $0.model.capture.id == id }?.model.saved(id: id, to: url) }
    func saveFailed(id: UUID) { entries.first { $0.model.capture.id == id }?.model.saveFailed(id: id) }
    func hide() { for entry in entries { dismiss(entry, reason: "hidden", animated: false) } }
    func isCurrent(_ entry: Entry, generation: UInt64) -> Bool {
        entry.generation == generation && entries.contains { $0 === entry } && entry.dwell.phase != .leaving
    }
    private func pause(_ entry: Entry, reason: ScreenshotCardDwell.Pause, active: Bool) {
        guard entry.dwell.setPaused(reason, active: active, at: timing.now()) else { return }
        arm(entry)
    }
    private func arm(_ entry: Entry) {
        entry.task?.cancel(); entry.task = nil
        guard let deadline = entry.dwell.deadline else { return }
        let generation = entry.generation, sleep = timing.sleep
        entry.task = Task { [weak self, weak entry] in
            guard let self, let entry else { return }
            do { try await sleep(max(0, deadline - self.timing.now())) } catch { return }
            guard !Task.isCancelled, self.isCurrent(entry, generation: generation),
                  entry.dwell.deadline == deadline, self.timing.now() >= deadline else { return }
            self.dismiss(entry, reason: "timeout")
        }
    }
    private func dismiss(_ entry: Entry, reason: String, animated: Bool = true) {
        guard entries.contains(where: { $0 === entry }) else { return }
        entry.task?.cancel(); entry.task = nil
        entry.dwell.leave(at: timing.now()); entry.exitAt = timing.now(); entry.dismissReason = reason
        entry.model.invalidate(); entry.host.invalidate()
        entries.removeAll { $0 === entry }
        reflow()
        let finish: @MainActor () -> Void = { [entry, timing] in
            entry.window.orderOut(nil); entry.orderedOutAt = timing.now()
        }
        if animated { animator(entry.host, false, reduceMotion(), finish) } else { finish() }
    }
    private func reflow() {
        let displays = Set(entries.map { ScreenshotCardDisplayFrame($0.visibleFrame) })
        let size = ScreenshotCardGeometry.window
        let step = ScreenshotCardGeometry.card.height + Self.stackGap
        for display in displays {
            var y = display.frame.minY
            for entry in entries where entry.visibleFrame == display.frame {
                let frame = CGRect(x: display.frame.maxX - size.width, y: y, width: size.width, height: size.height)
                entry.host.reposition(from: entry.window.frame, to: frame, reduceMotion: reduceMotion())
                entry.window.setFrame(frame, display: true)
                y += step
            }
        }
    }
    func openPreview(_ capture: CapturedScreenshot, on visible: CGRect, pinned: Bool = false, from card: CGRect? = nil) {
        preview.onEdit = onEdit
        preview.show(capture, operations: operations, on: visible, claim: claimClipboardPublication, pinned: pinned, from: card)
    }
    /// The capture flies from where it was taken into the card sliding in to meet it. Not for a
    /// scroll capture, whose page is far taller than the place it was taken.
    private func fly(_ capture: CapturedScreenshot, into entry: Entry) {
        guard !usesFixtureFrame, !reduceMotion(), capture.kind != .scrollCapture, let source = capture.sourceRect,
              let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let well = Self.cardRect(of: entry).insetBy(dx: ScreenshotCardGeometry.ring, dy: ScreenshotCardGeometry.ring)
        let shown = ScreenshotCardGeometry(sourceSize: capture.pointSize).imageRect.offsetBy(dx: well.minX, dy: well.minY)
        CaptureFlight.fly(capture.image, from: Geometry.cgToAppKit(source, primaryScreenHeight: primaryHeight), to: shown)
    }
    /// The card itself on screen, without its shadow margin.
    private static func cardRect(of entry: Entry) -> CGRect {
        entry.window.frame.insetBy(dx: ScreenshotCardGeometry.shadowInset, dy: ScreenshotCardGeometry.shadowInset)
    }
}

private final class ScreenshotCardPanel: NSPanel { override var canBecomeKey: Bool { true } }
private struct ScreenshotCardDisplayFrame: Hashable {
    let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
    init(_ frame: CGRect) { x = frame.minX; y = frame.minY; width = frame.width; height = frame.height }
    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// A monotonic active budget: each pause reason is independent and duplicate callbacks are inert.
struct ScreenshotCardDwell {
    enum Phase: String { case entering, visible, leaving }
    enum Pause: String, Hashable { case hover, busy, sharing, saving, gesture, dragging }
    private(set) var phase: Phase = .entering
    private(set) var remaining: TimeInterval = 5
    private(set) var pauses: Set<Pause> = []
    private(set) var deadline: TimeInterval?
    func remaining(at now: TimeInterval) -> TimeInterval { deadline.map { max(0, $0 - now) } ?? remaining }
    mutating func enter(at now: TimeInterval) {
        guard phase == .entering else { return }
        phase = .visible
        if pauses.isEmpty { deadline = now + remaining }
    }
    @discardableResult mutating func setPaused(_ reason: Pause, active: Bool, at now: TimeInterval) -> Bool {
        guard phase != .leaving, pauses.contains(reason) != active else { return false }
        if let deadline { remaining = max(0, deadline - now); self.deadline = nil }
        if active { pauses.insert(reason) } else { pauses.remove(reason) }
        if phase == .visible, pauses.isEmpty { deadline = now + remaining }
        return true
    }
    mutating func leave(at now: TimeInterval) { remaining = remaining(at: now); deadline = nil; phase = .leaving }
}

/// Export ownership outlives a dismissed card when an external drag has already been accepted.
actor ScreenshotCardExport {
    private let capture: CapturedScreenshot
    private let exports: ScreenshotTemporaryExports
    private let encode: @Sendable (CapturedScreenshot) async throws -> Data
    private var completed: URL?
    private var pending: Task<URL, Error>?
    init(capture: CapturedScreenshot, exports: ScreenshotTemporaryExports,
         encode: @escaping @Sendable (CapturedScreenshot) async throws -> Data) {
        self.capture = capture; self.exports = exports; self.encode = encode
    }
    func fileURL() async throws -> URL {
        if let completed, exports.owns(completed) { return completed }
        if let pending { return try await pending.value }
        let capture = capture, exports = exports, encode = encode
        let task = Task {
            let png = try await encode(capture)
            try Task.checkCancellation()
            return try await Task.detached { try exports.write(png) }.value
        }
        pending = task
        do {
            let url = try await task.value
            completed = url; pending = nil
            return url
        } catch { pending = nil; throw error }
    }
}

/// The async boundary is independent of native presentation for named-pasteboard tests.
@MainActor final class ScreenshotCardModel: ObservableObject {
    @MainActor struct Operations {
        var encode: @Sendable (CapturedScreenshot) async throws -> Data = { capture in
            try await Task.detached(priority: .userInitiated) {
                try EditorRendered(image: capture.image, pointSize: capture.pointSize).png
            }.value
        }
        var exports = ScreenshotTemporaryExports()
        var copy: @MainActor (CapturedScreenshot, NSPasteboard, @escaping @MainActor () -> Bool) async -> Bool = { capture, board, mayPublish in
            await EditorClipboardPublisher.copyPNG(capture.image, pointSize: capture.pointSize, to: board, shouldPublish: mayPublish)
        }
    }
    let capture: CapturedScreenshot
    let export: ScreenshotCardExport
    @Published private(set) var savedURL: URL?
    @Published private(set) var preparedExportURL: URL?
    @Published private(set) var preparedExportPNG: Data?
    @Published private(set) var isBusy = false
    @Published var error: String? { didSet { onContentChange?() } }
    private(set) var isAlive = true
    private var localRequests = LatestRequestGate()
    private var busyCount = 0
    /// A real, well-named file for dragging out: apps that refuse file promises accept it.
    @Published private(set) var dragFile: URL?
    private(set) var dragFileFailed = false
    private var dragPreparation: Task<Void, Never>?
    private let createdAt = Date()
    private let operations: Operations
    var claimClipboardPublication: (@MainActor () -> (@MainActor () -> Bool))?
    var onBusyChange: (@MainActor () -> Void)?
    var onContentChange: (@MainActor () -> Void)?
    init(capture: CapturedScreenshot, operations: Operations = .init()) {
        self.capture = capture; self.operations = operations
        export = ScreenshotCardExport(capture: capture, exports: operations.exports, encode: operations.encode)
    }
    func saved(id: UUID, to url: URL) { guard isAlive, capture.id == id else { return }; savedURL = url }
    func saveFailed(id: UUID) { guard isAlive, capture.id == id else { return }; error = String(localized: "The screenshot could not be saved.") }
    func invalidate() { isAlive = false; _ = localRequests.begin(); onBusyChange = nil; onContentChange = nil }
    func claimLocalPublication() -> @MainActor () -> Bool {
        let token = localRequests.begin()
        return { [weak self] in self?.isAlive == true && self?.localRequests.isCurrent(token) == true }
    }
    func copy(to board: NSPasteboard = .general) async -> Bool {
        guard isAlive, !isBusy else { return false }
        let mayPublish = claimClipboardPublication?() ?? claimLocalPublication()
        beginBusy(); defer { endBusy() }
        let result = await operations.copy(capture, board, { [weak self] in self?.isAlive == true && !Task.isCancelled && mayPublish() })
        if !result, isAlive, !Task.isCancelled, mayPublish() { error = String(localized: "The screenshot could not be copied.") }
        return result
    }
    /// Save is an explicit user-selected destination; encoding retains the capture's
    /// pixel dimensions and point density, using the same PNG representation as export.
    func save(to url: URL) async -> Bool {
        guard isAlive, !isBusy else { return false }
        beginBusy(); defer { endBusy() }
        do {
            let png = try await operations.encode(capture)
            guard isAlive, !Task.isCancelled else { return false }
            try await Task.detached(priority: .userInitiated) { try png.write(to: url, options: .atomic) }.value
            guard isAlive, !Task.isCancelled else { return false }
            savedURL = url
            return true
        } catch {
            if isAlive, !Task.isCancelled, !(error is CancellationError) { self.error = error.localizedDescription }
            return false
        }
    }
    func exportedFileURL() async throws -> URL {
        guard isAlive else { throw CancellationError() }
        beginBusy(); defer { endBusy() }
        let url = try await export.fileURL()
        guard isAlive, !Task.isCancelled else { throw CancellationError() }
        let png = try await Task.detached { try Data(contentsOf: url) }.value
        guard isAlive, !Task.isCancelled else { throw CancellationError() }
        preparedExportURL = url; preparedExportPNG = png
        return url
    }
    private func beginBusy() { busyCount += 1; if !isBusy { isBusy = true; onBusyChange?() } }
    private func endBusy() { busyCount -= 1; if busyCount == 0, isBusy { isBusy = false; onBusyChange?() } }
    /// Starts on the press that may become a drag, never for a card that is only shown.
    func prepareDragFile() {
        guard isAlive, dragFile == nil, dragPreparation == nil else { return }
        let export = export
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "\(String(localized: "Screenshot")) \(formatter.string(from: createdAt)).png"
        dragPreparation = Task { [weak self] in
            do {
                let url = try await export.fileURL()
                let named = await Task.detached { ScreenshotDragFiles.link(url, named: name) }.value
                guard let self, self.isAlive else { return }
                self.dragFile = named ?? url
            } catch {
                self?.dragFileFailed = true
            }
        }
    }
    func dragProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = String(localized: "Screenshot.png")
        let export = export
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            let task = Task {
                do {
                    let url = try await export.fileURL()
                    try Task.checkCancellation()
                    completion(url, false, nil); progress.completedUnitCount = 1
                } catch { completion(nil, false, error) }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }
}

/// Raw injected roots must already name their physical directory. The trusted system temp
/// root is canonicalized once. Checks bound ordinary filesystem races, not hostile syscalls.
struct ScreenshotTemporaryExports: Sendable {
    let directory: URL
    private let identity: RootIdentity
    private static let marker = "dev.tavsan.camcord.preview-export"
    private static let trustedDirectory: URL = {
        let root = physicalPath(FileManager.default.temporaryDirectory) ?? FileManager.default.temporaryDirectory.path
        return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("dev.tavsan.camcord.preview-exports", isDirectory: true)
    }()
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.trustedDirectory
        identity = RootIdentity(directory: self.directory)
    }
    private static func physicalPath(_ url: URL) -> String? {
        guard url.isFileURL else { return nil }
        return url.withUnsafeFileSystemRepresentation { raw in
            guard let raw, let resolved = Darwin.realpath(raw, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
    private static func fingerprint(_ url: URL, directory: Bool) -> FileIdentity? {
        guard physicalPath(url) == url.path else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }
    private func rootIsSafe() -> Bool { identity.validate(directory) }
    func owns(_ url: URL) -> Bool {
        guard rootIsSafe(), url.isFileURL, url.deletingLastPathComponent().path == directory.path,
              url.pathExtension == "png", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
              Self.fingerprint(url, directory: false) != nil else { return false }
        var marker: UInt8 = 0
        return getxattr(url.path, Self.marker, &marker, 1, 0, XATTR_NOFOLLOW) == 1 && marker == 1
    }
    func write(_ data: Data) throws -> URL {
        guard identity.prepare(directory), rootIsSafe() else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = directory.appendingPathComponent(UUID().uuidString + ".png")
        guard rootIsSafe() else { throw CocoaError(.fileWriteInvalidFileName) }
        try data.write(to: url, options: [.atomic])
        guard rootIsSafe(), Self.fingerprint(url, directory: false) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        var marker: UInt8 = 1
        guard setxattr(url.path, Self.marker, &marker, 1, 0, XATTR_NOFOLLOW) == 0, owns(url) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
    func cleanup(now: Date = Date()) {
        guard rootIsSafe(), let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let threshold = now.addingTimeInterval(-24 * 3600)
        for url in urls {
            guard owns(url), let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate, date < threshold, owns(url) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
    private struct FileIdentity: Equatable, Sendable { let device: dev_t; let inode: ino_t }
    private final class RootIdentity: @unchecked Sendable {
        private let lock = NSLock()
        private var root: FileIdentity?
        private let parent: FileIdentity?
        init(directory: URL) {
            root = ScreenshotTemporaryExports.fingerprint(directory, directory: true)
            parent = ScreenshotTemporaryExports.fingerprint(directory.deletingLastPathComponent(), directory: true)
        }
        func validate(_ directory: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let root, let parent else { return false }
            return ScreenshotTemporaryExports.fingerprint(directory, directory: true) == root && ScreenshotTemporaryExports.fingerprint(directory.deletingLastPathComponent(), directory: true) == parent
        }
        func prepare(_ directory: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let parent, directory.isFileURL,
                  ScreenshotTemporaryExports.fingerprint(directory.deletingLastPathComponent(), directory: true) == parent else { return false }
            if let root { return ScreenshotTemporaryExports.fingerprint(directory, directory: true) == root }
            // lstat sees dangling links too; never follow or create through one.
            var entry = stat()
            guard lstat(directory.path, &entry) != 0, errno == ENOENT,
                  directory.path == directory.standardizedFileURL.path else { return false }
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) } catch { return false }
            root = ScreenshotTemporaryExports.fingerprint(directory, directory: true)
            return root != nil
        }
    }
}

/// Named links to exported screenshots, one folder each, for drags out of the card.
enum ScreenshotDragFiles {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dev.tavsan.camcord.drag", isDirectory: true)
    static func link(_ source: URL, named name: String) -> URL? {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            do { try FileManager.default.linkItem(at: source, to: target) }
            catch { try FileManager.default.copyItem(at: source, to: target) }
            return target
        } catch { return nil }
    }
    static func cleanup(now: Date = Date()) {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            guard let date = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(date) > 24 * 3600 else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
