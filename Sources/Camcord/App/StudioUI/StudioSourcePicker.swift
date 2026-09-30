import AppKit
import Observation
@preconcurrency import ScreenCaptureKit

/// The picker owns only accepted user intent. Its ordinary step-aside transition is expected;
/// closing/reopening the window, replacing the source or changing modules invalidates the result.
@MainActor @Observable
final class StudioSourcePicker {
    struct Context: Equatable {
        let windowIdentity: ObjectIdentifier
        let presentationEpoch: UInt64
        let sourceID: StudioSourceChoice.ID?
        let sourceFrame: CGRect?
    }
    enum Pick: Sendable { case region(CGRect), window(UInt32) }
    enum Resolved: Sendable { case region(CGRect, UInt32), source(StudioSourceChoice) }
    @MainActor struct Operations {
        var context: () -> Context?
        var observeModuleChange: (@escaping @MainActor () -> Void) -> Void
        var stepAside: (@escaping @MainActor () async -> Void) async -> Void
        var choose: () async -> Pick?
        var resolve: (Pick) async throws -> Resolved
        var apply: (Resolved) async -> Void
    }

    private let operations: Operations
    @ObservationIgnored private var requests = LatestRequestGate()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var taskToken: UInt64?
    @ObservationIgnored private var overlayPending = false
    private(set) var isSelecting = false
    private(set) var issue: StudioIssue?

    init(operations: Operations) { self.operations = operations }

    convenience init(session: StudioSession, coordinator: CaptureCoordinator,
                     mainWindow: @escaping @MainActor () -> MainWindowController?) {
        self.init(operations: Operations(
            context: {
                guard let window = mainWindow(), window.model.selection == .studio,
                      window.lifecycle.allowsLivePreview, !session.isBusy,
                      !session.recordingState.isArmed, !coordinator.captureTransition.isActive else { return nil }
                return Context(windowIdentity: ObjectIdentifier(window), presentationEpoch: window.presentationEpoch,
                               sourceID: session.selectedSource?.id, sourceFrame: session.selectedSource?.frame)
            },
            observeModuleChange: { invalidate in
                withObservationTracking { _ = mainWindow()?.model.selection } onChange: {
                    Task { @MainActor in invalidate() }
                }
            },
            stepAside: { work in
                guard let window = mainWindow() else { return }
                await window.stepAside(during: work)
            },
            choose: {
                switch await coordinator.selectCaptureTarget() {
                case .region(let rect): return .region(rect)
                case .window(let window): return .window(window.windowID)
                case nil: return nil
                }
            },
            resolve: { pick in
                guard CGPreflightScreenCaptureAccess() else { throw StudioIssue.screenPermissionRequired }
                let content = try await coordinator.contentCache.content(forceRefresh: true)
                switch pick {
                case .window(let id):
                    guard let choice = StudioSourceResolver.choices(in: content, settings: session.settings)
                        .first(where: { $0.id == .window(id) }) else { throw StudioIssue.sourceUnavailable }
                    return .source(choice)
                case .region(let rect):
                    let displays = content.displays.map {
                        StudioPickerDisplay(id: $0.displayID, frame: $0.frame, scale: StudioSourceResolver.scale($0))
                    }
                    guard let result = StudioPickerGeometry.resolve(rect, displays: displays) else { throw StudioIssue.sourceUnavailable }
                    return .region(result.rect, result.displayID)
                }
            },
            apply: { resolved in
                switch resolved {
                case .source(let source): session.selectSource(source)
                case .region(let rect, let id): await session.selectRegion(rect, displayID: id)
                }
            }
        ))
    }

    func dismissIssue() { issue = nil }
    func cancel() { requests.invalidate(); task?.cancel() }

    func select() async {
        guard !overlayPending, let initial = operations.context() else { return }
        task?.cancel()
        let token = requests.begin()
        taskToken = token
        overlayPending = true
        issue = nil
        isSelecting = true
        operations.observeModuleChange { [weak self] in
            guard let self, self.requests.isCurrent(token) else { return }
            self.cancel()
        }
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.perform(initial: initial, token: token)
        }
        task = work
        await work.value
        if taskToken == token {
            task = nil
            taskToken = nil
            overlayPending = false
            isSelecting = false
        }
    }

    private func perform(initial: Context, token: UInt64) async {
        var picked: Pick?
        await operations.stepAside {
            guard self.requests.isCurrent(token), !Task.isCancelled else { return }
            picked = await self.operations.choose()
        }
        if taskToken == token { overlayPending = false }
        guard let picked, accepts(initial, token: token) else { return }
        do {
            let result = try await operations.resolve(picked)
            guard accepts(initial, token: token) else { return }
            await operations.apply(result)
        } catch {
            guard accepts(initial, token: token) else { return }
            issue = (error as? StudioIssue) ?? .sourceListUnavailable
        }
    }

    private func accepts(_ initial: Context, token: UInt64) -> Bool {
        guard requests.isCurrent(token), !Task.isCancelled, let current = operations.context() else { return false }
        return current.windowIdentity == initial.windowIdentity
            && current.presentationEpoch == (initial.presentationEpoch &+ 1)
            && current.sourceID == initial.sourceID && current.sourceFrame == initial.sourceFrame
    }
}

struct StudioPickerDisplay: Sendable {
    let id: UInt32
    let frame: CGRect
    let scale: CGFloat
}

enum StudioPickerGeometry {
    struct Region: Equatable { let rect: CGRect; let displayID: UInt32 }
    static func resolve(_ rect: CGRect, displays: [StudioPickerDisplay]) -> Region? {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width > 1, rect.size.height > 1, rect.maxX.isFinite, rect.maxY.isFinite else { return nil }
        let valid = displays.filter {
            $0.id != 0 && $0.frame.origin.x.isFinite && $0.frame.origin.y.isFinite && $0.frame.size.width.isFinite
                && $0.frame.size.height.isFinite && $0.frame.size.width > 1 && $0.frame.size.height > 1
                && $0.frame.maxX.isFinite && $0.frame.maxY.isFinite
                && $0.scale.isFinite && $0.scale > 0
                && ($0.frame.width * $0.scale).isFinite && ($0.frame.height * $0.scale).isFinite
                && $0.frame.width * $0.scale < CGFloat(Int.max) && $0.frame.height * $0.scale < CGFloat(Int.max)
        }.sorted { $0.id < $1.id }
        guard let clamp = RegionClamp.clamp(region: rect, displays: valid.map { .init(frame: $0.frame, scale: $0.scale) }),
              clamp.pixelWidth >= 2, clamp.pixelHeight >= 2 else { return nil }
        return Region(rect: clamp.clampedRegion, displayID: valid[clamp.displayIndex].id)
    }
}
