import AppKit
import Observation
import UniformTypeIdentifiers

/// Clipboard ownership is claimed at user intent, before the file check suspends.
/// Both the local generation and the coordinator epoch must remain current when publishing.
@MainActor @Observable
final class StudioFileActions {
    typealias Claim = @MainActor () -> (@MainActor () -> Bool)
    struct Operations {
        var validate: @Sendable (URL) async -> URL? = { url in
            await Task.detached(priority: .userInitiated) {
                guard url.isFileURL else { return nil }
                let file = url.standardizedFileURL.resolvingSymlinksInPath()
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .contentTypeKey]),
                      values.isRegularFile == true, values.isReadable == true,
                      values.contentType?.conforms(to: .movie) == true else { return nil }
                return file
            }.value
        }
        var open: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
        var reveal: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        var publish: @MainActor (URL, @MainActor () -> Bool) -> Bool = { url, current in
            guard current() else { return false }
            let board = NSPasteboard.general
            // No await between the guard and publication; newer requests cannot interleave.
            board.clearContents()
            return board.writeObjects([url as NSURL])
        }
    }
    private var requests = LatestRequestGate()
    private let operations: Operations
    private(set) var issue: LocalizedStringResource?
    private(set) var isWorking = false
    private(set) var shareURL: URL?
    init(operations: Operations = .init()) { self.operations = operations }
    func dismissIssue() { issue = nil }
    func cancel() { requests.invalidate(); isWorking = false; shareURL = nil }
    func perform(_ action: Action, url: URL, claimClipboard: Claim? = nil) async {
        let token = requests.begin()
        let externallyCurrent = action == .copy ? claimClipboard?() : nil
        let current = { @MainActor [weak self] in
            self?.requests.isCurrent(token) == true && !Task.isCancelled && (externallyCurrent?() ?? true)
        }
        isWorking = true
        issue = nil
        shareURL = nil
        defer { if requests.isCurrent(token) { isWorking = false } }
        guard let file = await operations.validate(url) else {
            if current() { issue = "The recording file is unavailable. Check that it has not been moved or deleted." }
            return
        }
        guard current() else { return }
        switch action {
        case .open:
            if !operations.open(file) { issue = "The recording could not be opened." }
        case .reveal: operations.reveal(file)
        case .share: shareURL = file
        case .copy:
            if !operations.publish(file, current) { issue = "The recording could not be copied." }
        }
    }
    enum Action: Equatable { case open, reveal, copy, share }
}
