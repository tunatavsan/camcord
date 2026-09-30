import Foundation

@MainActor
protocol StudioPreviewResource: AnyObject, Sendable { func stop() async }

/// Ownership around non-cooperative preview starts. Generation and resource identity
/// are both checked; retiring A can only stop A, even after B has been installed.
@MainActor
final class StudioPreviewOwner {
    private(set) var generation = UUID()
    private(set) var capture: (any StudioPreviewResource)?

    func invalidatePending() { generation = UUID() }

    func detach() -> (any StudioPreviewResource)? {
        generation = UUID()
        let old = capture
        capture = nil
        return old
    }

    func install(_ candidate: any StudioPreviewResource, generation token: UUID,
                 start: @MainActor () async throws -> Void) async throws -> Bool {
        guard generation == token, capture == nil, !Task.isCancelled else { return false }
        capture = candidate
        do { try await start() } catch {
            if generation == token, capture === candidate { capture = nil }
            await candidate.stop()
            throw error
        }
        guard !Task.isCancelled, generation == token, capture === candidate else {
            await candidate.stop()
            return false
        }
        return true
    }
}
