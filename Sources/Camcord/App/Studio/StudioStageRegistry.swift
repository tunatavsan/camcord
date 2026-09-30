import Foundation
import os

/// Controller-owned registration, with immutable queue snapshots. A lease's tiny
/// locked liveness flag prevents an already-enqueued snapshot from calling retired UI.
@MainActor
final class StudioStageRegistry {
    private final class Lease: Sendable {
        let handler: @Sendable (PixelBufferBox) -> Void
        let live = OSAllocatedUnfairLock(initialState: true)
        init(handler: @escaping @Sendable (PixelBufferBox) -> Void) { self.handler = handler }
        func invalidate() { live.withLock { $0 = false } }
        func deliver(_ frame: PixelBufferBox) {
            guard live.withLock({ $0 }) else { return }
            handler(frame)
        }
    }
    private var owners: [UUID: Lease] = [:]

    func subscribe(owner: UUID, handler: @escaping @Sendable (PixelBufferBox) -> Void) {
        owners[owner]?.invalidate()
        owners[owner] = Lease(handler: handler)
    }

    func unsubscribe(owner: UUID) {
        owners.removeValue(forKey: owner)?.invalidate()
    }

    func snapshot() -> (@Sendable (PixelBufferBox) -> Void)? {
        guard !owners.isEmpty else { return nil }
        let leases = Array(owners.values)
        return { frame in for lease in leases { lease.deliver(frame) } }
    }

    var ownerCount: Int { owners.count }
}
