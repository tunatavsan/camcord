import Foundation
import Testing
import os
@testable import Camcord

@MainActor @Suite("Microphone probe owners")
struct MicrophoneOwnershipTests {
    @Test("passive rehearsal never asks permission, cannot steal pending/active owners, and respects recording locks")
    func passiveAuthorizationAndOwnership() async {
        var permissions = 0, made = 0, authorized = false
        let monitor = MicrophoneMonitor(operations: .init(authorize: { permissions += 1; return true },
            makeProbe: { made += 1; return Probe() }, isAuthorized: { authorized }))
        let studio = UUID(), foreign = UUID()
        await monitor.start(owner: studio, deviceID: nil, gainDB: 0, requestPermission: false)
        #expect(permissions == 0 && made == 0 && !monitor.isRunning)
        await monitor.release(owner: studio)
        authorized = true
        await monitor.start(owner: studio, deviceID: nil, gainDB: 0, requestPermission: false)
        #expect(permissions == 0 && made == 1 && monitor.isRunning)
        await monitor.start(owner: foreign, deviceID: "foreign", gainDB: 0)
        #expect(permissions == 1 && made == 2 && monitor.owns(foreign))
        await monitor.start(owner: studio, deviceID: nil, gainDB: 0, requestPermission: false)
        await monitor.release(owner: studio)
        #expect(permissions == 1 && made == 2 && monitor.owns(foreign) && monitor.isRunning)
        await monitor.prepareForRecording()
        await monitor.start(owner: studio, deviceID: nil, gainDB: 0, requestPermission: false)
        #expect(permissions == 1 && made == 2 && !monitor.owns(studio))
    }

    @Test("passive intent cannot supersede a foreign permission request before it completes")
    func passiveRefusesPendingAuthorization() async {
        var continuation: CheckedContinuation<Bool, Never>?
        var probes = 0
        let monitor = MicrophoneMonitor(operations: .init(authorize: {
            await withCheckedContinuation { continuation = $0 }
        }, makeProbe: { probes += 1; return Probe() }, isAuthorized: { true }))
        let foreign = UUID(), studio = UUID()
        let request = Task { await monitor.start(owner: foreign, deviceID: nil, gainDB: 0) }
        while continuation == nil { await Task.yield() }
        await monitor.start(owner: studio, deviceID: nil, gainDB: 0, requestPermission: false)
        #expect(monitor.owns(foreign) && probes == 0)
        continuation?.resume(returning: true)
        await request.value
        #expect(monitor.owns(foreign) && probes == 1)
        await monitor.release(owner: foreign)
    }

    private final class Probe: MicrophoneProbe, @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (stopped: 0, gain: 0.0))
        private let startBlock: @MainActor () async -> Void
        private let stopBlock: @MainActor () async -> Void
        var stopped: Int { state.withLock { $0.stopped } }
        var gain: Double { state.withLock { $0.gain } }
        init(startBlock: @escaping @MainActor () async -> Void = {}, stopBlock: @escaping @MainActor () async -> Void = {}) {
            self.startBlock = startBlock
            self.stopBlock = stopBlock
        }
        func start(deviceID: String?, gainDB: Double) async throws {
            state.withLock { $0.gain = gainDB }
            await startBlock()
        }
        func stop() async { state.withLock { $0.stopped += 1 }; await stopBlock() }
        func updateGain(_ value: Double) { state.withLock { $0.gain = value } }
        func snapshot() -> MicrophoneProbeSnapshot { .init() }
    }

    @Test("late physical start and stop completions cannot clear a replacement owner", arguments: [false, true])
    func stalePhysicalOperation(delayedStop: Bool) async throws {
        var probes: [Probe] = []
        var pending: CheckedContinuation<Void, Never>?
        let monitor = MicrophoneMonitor(operations: .init(authorize: { true }, makeProbe: {
            let first = probes.isEmpty
            let probe = Probe(startBlock: {
                if first && !delayedStop { await withCheckedContinuation { pending = $0 } }
            }, stopBlock: {
                if first && delayedStop { await withCheckedContinuation { pending = $0 } }
            })
            probes.append(probe)
            return probe
        }))
        let a = UUID(), b = UUID()
        let first = Task { await monitor.start(owner: a, deviceID: "A", gainDB: 1) }
        if delayedStop { await first.value }
        let stopTask = delayedStop ? Task { await monitor.release(owner: a) } : nil
        let deadline = ContinuousClock.now + .seconds(2)
        while pending == nil, ContinuousClock.now < deadline { await Task.yield() }
        try #require(pending != nil)
        await monitor.start(owner: b, deviceID: "B", gainDB: 2)
        pending?.resume()
        await first.value
        await stopTask?.value
        #expect(monitor.owns(b) && monitor.isRunning)
        #expect(probes[1].stopped == 0)
        await monitor.release(owner: b)
    }

    @Test("releasing a superseded owner cannot stop or change the newest explicit probe")
    func independentReleaseAndGain() async {
        var probes: [Probe] = []
        let monitor = MicrophoneMonitor(operations: .init(authorize: { true }, makeProbe: {
            let probe = Probe(); probes.append(probe); return probe
        }))
        let a = UUID(), b = UUID()
        await monitor.start(owner: a, deviceID: "A", gainDB: 1)
        await monitor.start(owner: b, deviceID: "B", gainDB: 2)
        monitor.updateGain(9, owner: a)
        await monitor.release(owner: a)
        #expect(monitor.owns(b))
        #expect(!monitor.owns(a))
        #expect(monitor.isRunning)
        #expect(probes.count == 2)
        #expect(probes[1].stopped == 0)
        #expect(probes[1].gain == 2)
        await monitor.release(owner: b)
        #expect(probes[1].stopped == 1)
    }

    @Test("late authorization from a released owner cannot replace a newer probe")
    func staleAuthorization() async {
        var pending: [CheckedContinuation<Bool, Never>] = []
        var probes: [Probe] = []
        let monitor = MicrophoneMonitor(operations: .init(authorize: {
            await withCheckedContinuation { pending.append($0) }
        }, makeProbe: { let probe = Probe(); probes.append(probe); return probe }))
        let a = UUID(), b = UUID()
        let first = Task { await monitor.start(owner: a, deviceID: "A", gainDB: 1) }
        while pending.count < 1 { await Task.yield() }
        await monitor.release(owner: a)
        let newer = Task { await monitor.start(owner: b, deviceID: "B", gainDB: 2) }
        while pending.count < 2 { await Task.yield() }
        pending[0].resume(returning: true)
        await first.value
        #expect(monitor.isStarting)
        #expect(probes.isEmpty)
        pending[1].resume(returning: true)
        await newer.value
        #expect(monitor.owns(b) && monitor.isRunning)
        #expect(probes.count == 1)
        await monitor.release(owner: b)
    }

    @Test("recording clears probe owners and unlock never restarts them")
    func recorderClearsOwnership() async {
        let probe = Probe()
        let monitor = MicrophoneMonitor(operations: .init(authorize: { true }, makeProbe: { probe }))
        let owner = UUID()
        await monitor.start(owner: owner, deviceID: nil, gainDB: 0)
        await monitor.prepareForRecording()
        #expect(monitor.recordingLocked)
        #expect(!monitor.owns(owner) && !monitor.isRunning)
        #expect(probe.stopped == 1)
        monitor.recordingEnded()
        #expect(!monitor.recordingLocked && !monitor.isRunning)
        #expect(probe.stopped == 1)
    }
}
