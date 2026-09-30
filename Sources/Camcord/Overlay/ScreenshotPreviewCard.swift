import AppKit
import Darwin
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// One visible immutable capture; late save events can update only its UUID.
@MainActor final class ScreenshotPreviewCard {
    typealias Presenter = @MainActor (NSPanel) -> Void
    var onEdit: (@MainActor (CapturedScreenshot) -> Void)?
    var onPin: (@MainActor (CapturedScreenshot) -> Void)?
    var claimClipboardPublication: (@MainActor () -> (@MainActor () -> Bool))?
    private var panel: NSPanel?
    private(set) var model: ScreenshotCardModel?
    private var dismissTask: Task<Void, Never>?
    private let presenter: Presenter
    private let screenFrame: @MainActor () -> CGRect?
    private let operations: ScreenshotCardModel.Operations
    private var hovering = false
    private let quickLook = EditorQuickLook()
    private static var hasCleanedExports = false
    static func cardCornerRadius(for size: CGSize) -> CGFloat { Theme.Radius.floating }
    static func shadowInset(for size: CGSize) -> CGFloat { Theme.Space.m }
    init(presenter: Presenter? = nil, screenFrame: (@MainActor () -> CGRect?)? = nil,
         operations: ScreenshotCardModel.Operations = .init()) {
        self.presenter = presenter ?? { $0.orderFrontRegardless() }
        self.screenFrame = screenFrame ?? {
            (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame
        }
        self.operations = operations
    }
    func show(capture: CapturedScreenshot) {
        if !Self.hasCleanedExports {
            Self.hasCleanedExports = true
            let exports = operations.exports
            Task.detached(priority: .background) { exports.cleanup() }
        }
        hide()
        guard HUDToast.isEnabled(), let visible = screenFrame() else { return }
        let model = ScreenshotCardModel(capture: capture, operations: operations)
        model.claimClipboardPublication = { [weak self, weak model] in self?.claimClipboardPublication?() ?? model?.claimLocalPublication() ?? { false } }
        model.onBusyChange = { [weak self, weak model] in
            guard let self, self.model === model else { return }
            self.armDismiss()
        }
        let content = ScreenshotCardContent(model: model,
            edit: { [weak self] in self?.onEdit?(capture); self?.hide() },
            pin: { [weak self] in self?.onPin?(capture) },
            quickLook: { [weak self] url in self?.quickLook.show(url) },
            dismiss: { [weak self] in self?.hide() },
            canEdit: onEdit != nil, canPin: onPin != nil,
            hover: { [weak self] hover in self?.hovering = hover; self?.armDismiss() })
        let size = CGSize(width: 344, height: 316)
        let origin = CGPoint(x: visible.minX + Theme.Space.l, y: visible.minY + Theme.Space.l)
        let panel = ScreenshotCardPanel(contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar; panel.animationBehavior = .none; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = ScreenshotCardHost(rootView: content)
        host.onCancel = { [weak self] in self?.hide() }
        panel.contentView = host
        self.panel = panel; self.model = model; hovering = false
        presenter(panel); armDismiss()
    }
    func saved(id: UUID, to url: URL) { model?.saved(id: id, to: url) }
    func hide() {
        dismissTask?.cancel(); dismissTask = nil
        model?.invalidate(); model = nil
        panel?.orderOut(nil); panel = nil; hovering = false
    }
    private func armDismiss() {
        dismissTask?.cancel(); dismissTask = nil
        guard !hovering, model?.isBusy == false else { return }
        let id = model?.capture.id
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, self?.model?.capture.id == id else { return }
            self?.hide()
        }
    }
}

private final class ScreenshotCardPanel: NSPanel { override var canBecomeKey: Bool { true } }
private final class ScreenshotCardHost: NSHostingView<ScreenshotCardContent> {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The async boundary is independent of native presentation for real named-pasteboard tests.
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
    @Published private(set) var savedURL: URL?
    @Published private(set) var isBusy = false
    @Published var error: String?
    private var isAlive = true
    private var exportURL: URL?
    private var exportTask: Task<URL, Error>?
    private var localRequests = LatestRequestGate()
    private let operations: Operations
    var claimClipboardPublication: (@MainActor () -> (@MainActor () -> Bool))?
    var onBusyChange: (@MainActor () -> Void)?
    init(capture: CapturedScreenshot, operations: Operations = .init()) { self.capture = capture; self.operations = operations }
    func saved(id: UUID, to url: URL) { guard isAlive, capture.id == id else { return }; savedURL = url }
    func invalidate() { isAlive = false; exportTask?.cancel(); exportTask = nil; _ = localRequests.begin() }
    func claimLocalPublication() -> @MainActor () -> Bool {
        let token = localRequests.begin()
        return { [weak self] in self?.isAlive == true && self?.localRequests.isCurrent(token) == true }
    }
    func copy(to board: NSPasteboard = .general) async -> Bool {
        guard isAlive, !isBusy else { return false }
        // Claim the shared epoch synchronously, before the first encoding suspension.
        let mayPublish = claimClipboardPublication?() ?? claimLocalPublication()
        setBusy(true); defer { setBusy(false) }
        let result = await operations.copy(capture, board, { [weak self] in self?.isAlive == true && !Task.isCancelled && mayPublish() })
        if !result, isAlive, !Task.isCancelled, mayPublish() { error = String(localized: "The screenshot could not be copied.") }
        return result
    }
    func exportedFileURL() async throws -> URL {
        guard isAlive else { throw CancellationError() }
        if let exportURL, operations.exports.owns(exportURL) { return exportURL }
        if let exportTask {
            let url = try await exportTask.value
            guard isAlive, !Task.isCancelled else { throw CancellationError() }
            return url
        }
        setBusy(true)
        let capture = capture, exports = operations.exports, encode = operations.encode
        let task = Task {
            let png = try await encode(capture)
            try Task.checkCancellation()
            return try await Task.detached { try exports.write(png) }.value
        }
        exportTask = task
        defer { exportTask = nil; setBusy(false) }
        let url = try await task.value
        guard isAlive, !Task.isCancelled else { throw CancellationError() }
        exportURL = url
        return url
    }
    private func setBusy(_ busy: Bool) { isBusy = busy; onBusyChange?() }
    func dragProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = String(localized: "Screenshot.png")
        let capture = capture, exports = operations.exports, encode = operations.encode
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            let task = Task {
                do {
                    let png = try await encode(capture)
                    try Task.checkCancellation()
                    let url = try await Task.detached { try exports.write(png) }.value
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

private struct ScreenshotCardContent: View {
    @ObservedObject var model: ScreenshotCardModel
    let edit: () -> Void, pin: () -> Void, quickLook: (URL) -> Void, dismiss: () -> Void
    let canEdit: Bool, canPin: Bool
    let hover: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Label("Copied", systemImage: "checkmark").font(Theme.Font.bodyStrong)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss screenshot")
            }
            Image(nsImage: NSImage(cgImage: model.capture.image, size: model.capture.pointSize))
                .resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Palette.well.color)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.well))
                .onDrag { model.dragProvider() }
                .accessibilityLabel("Screenshot preview")
                .help("Drag the screenshot to another app")
            Text(verbatim: "\(model.capture.image.width) × \(model.capture.image.height)")
                .font(Theme.Font.data).foregroundStyle(Theme.Palette.ink2.color)
            HStack {
                Button("Edit", action: edit).disabled(!canEdit)
                Button("Pin", action: pin).disabled(!canPin)
                Button("Copy") { Task { _ = await model.copy() } }
                Button("Quick Look") { Task { do { quickLook(try await model.exportedFileURL()) } catch { model.error = error.localizedDescription } } }
                ScreenshotCardShareButton(model: model).frame(width: 24, height: 24)
            }
            .font(Theme.Font.caption).buttonStyle(.bordered).disabled(model.isBusy)
            if let error = model.error { Text(error).font(Theme.Font.caption).foregroundStyle(Theme.Palette.record.color).lineLimit(2) }
            if model.isBusy { ProgressView().controlSize(.mini).accessibilityLabel("Preparing screenshot") }
        }
        .padding(Theme.Space.m).foregroundStyle(Theme.Palette.ink.color).tint(Theme.Palette.ink.color)
        .camcordGlass(.chrome, in: RoundedRectangle(cornerRadius: Theme.Radius.floating))
        .opacity(appeared ? 1 : 0)
        .scaleEffect(reduceMotion || appeared ? 1 : Theme.Motion.condenseScale)
        .onAppear { withAnimation(Theme.Motion.resolve(Theme.Motion.panel, reduceMotion: reduceMotion)) { appeared = true } }
        .onHover(perform: hover)
    }
}

private struct ScreenshotCardShareButton: NSViewRepresentable {
    let model: ScreenshotCardModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: String(localized: "Share"))!, target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.isBordered = false; button.contentTintColor = Theme.Palette.ink.ns
        button.setAccessibilityLabel(String(localized: "Share")); return button
    }
    func updateNSView(_ view: NSButton, context: Context) { context.coordinator.model = model; view.isEnabled = !model.isBusy }
    @MainActor final class Coordinator: NSObject {
        var model: ScreenshotCardModel
        private var picker: NSSharingServicePicker?
        init(model: ScreenshotCardModel) { self.model = model }
        @objc func share(_ button: NSButton) {
            let snapshot = model
            Task {
                do {
                    let url = try await snapshot.exportedFileURL()
                    let picker = NSSharingServicePicker(items: [url]); self.picker = picker
                    picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                } catch { snapshot.error = error.localizedDescription }
            }
        }
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
