import Foundation
import CoreMedia
import os

/// Controller-owned registration, with immutable queue snapshots. A lease's tiny
/// locked liveness flag prevents an already-enqueued snapshot from calling retired UI.
@MainActor
final class StudioStageRegistry {
    private final class Lease: Sendable {
        let handler: @Sendable (PixelBufferBox) -> Void
        private struct State {
            var live = true
            var lastPTS: CMTime = .invalid
            var lastUptime = -Double.infinity
            var epoch: UUID?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let interval: Double?
        private let uptime: @Sendable () -> Double
        init(maximumFramesPerSecond: Double?, uptime: @escaping @Sendable () -> Double,
             handler: @escaping @Sendable (PixelBufferBox) -> Void) {
            self.handler = handler
            self.uptime = uptime
            interval = maximumFramesPerSecond.map { 1 / ($0.isFinite && $0 > 0 ? $0 : 10) }
        }
        func invalidate() { state.withLock { $0.live = false } }
        func deliver(_ frame: PixelBufferBox) {
            let admitted = state.withLock { state -> Bool in
                guard state.live else { return false }
                guard let interval else { return true }
                if state.epoch != frame.epoch {
                    state.epoch = frame.epoch
                    state.lastPTS = .invalid
                    state.lastUptime = -Double.infinity
                }
                if frame.pts.isNumeric {
                    if state.lastPTS.isNumeric,
                       CMTimeSubtract(frame.pts, state.lastPTS) < CMTime(seconds: interval, preferredTimescale: 60_000) {
                        return false
                    }
                    state.lastPTS = frame.pts
                } else {
                    let now = uptime()
                    guard now - state.lastUptime >= interval else { return false }
                    state.lastUptime = now
                }
                return true
            }
            guard admitted else { return }
            handler(frame)
        }
    }
    private var owners: [UUID: Lease] = [:]
    private let uptime: @Sendable () -> Double

    init(uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    func subscribe(owner: UUID, maximumFramesPerSecond: Double? = 10,
                   handler: @escaping @Sendable (PixelBufferBox) -> Void) {
        owners[owner]?.invalidate()
        owners[owner] = Lease(maximumFramesPerSecond: maximumFramesPerSecond, uptime: uptime, handler: handler)
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
