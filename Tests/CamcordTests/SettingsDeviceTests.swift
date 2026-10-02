import AVFoundation
import Testing
import os

@testable import Camcord

@MainActor
@Suite("Settings devices")
struct SettingsDeviceTests {
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }

    private final class Probe: MicrophoneProbe, @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (stops: 0, gain: 0.0))
        var stops: Int { state.withLock { $0.stops } }
        var gain: Double { state.withLock { $0.gain } }
        func start(deviceID: String?, gainDB: Double) async throws { updateGain(gainDB) }
        func stop() async { state.withLock { $0.stops += 1 } }
        func updateGain(_ value: Double) { state.withLock { $0.gain = value } }
        func snapshot() -> MicrophoneProbeSnapshot { .init() }
    }

    @Test("retained Settings stops metadata and its microphone on hide, reloads on return, and respects foreign owners")
    func retainedRecordingResources() async throws {
        let notifications = NotificationCenter()
        var loads = 0
        let inventory = SettingsDeviceInventory(kind: .microphone, notifications: notifications) {
            loads += 1
            return .init(devices: [], defaultID: nil)
        }
        var probes: [Probe] = []
        let monitor = MicrophoneMonitor(operations: .init(authorize: { true }, makeProbe: {
            let probe = Probe(); probes.append(probe); return probe
        }))
        let resources = SettingsRecordingResources(inputs: inventory, monitor: monitor)
        resources.updateActivity(SettingsActivity.allows(moduleActive: true, windowVisible: nil))
        #expect(loads == 1)
        await resources.startTest(deviceID: nil, gainDB: 4)?.value
        #expect(monitor.isRunning)
        let firstOwner = resources.owner
        let foreign = UUID()
        await monitor.start(owner: foreign, deviceID: "foreign", gainDB: 7)
        await resources.updateActivity(SettingsActivity.allows(moduleActive: false, windowVisible: true))?.value
        notifications.post(name: AVCaptureDevice.wasConnectedNotification, object: nil)
        #expect(loads == 1 && resources.owner != firstOwner)
        #expect(resources.startTest(deviceID: nil, gainDB: 20) == nil)
        #expect(monitor.owns(foreign) && monitor.isRunning && probes.last?.gain == 7)
        #expect(probes.last?.stops == 0)
        resources.updateActivity(true)
        #expect(loads == 2)
        await resources.startTest(deviceID: nil, gainDB: 5)?.value
        #expect(monitor.owns(resources.owner) && monitor.isRunning)
        let ownProbe = try #require(probes.last)
        // Release includes the retired probe's stop and the retained owner's restart.
        await resources.updateActivity(SettingsActivity.allows(moduleActive: true, windowVisible: false))?.value
        #expect(monitor.owns(foreign) && monitor.activeOwner == foreign && monitor.isRunning)
        #expect(ownProbe.stops == 1 && probes.last?.gain == 7)
        await monitor.prepareForRecording()
        resources.updateActivity(true)
        await resources.startTest(deviceID: nil, gainDB: 2)?.value
        #expect(monitor.recordingLocked && !monitor.owns(resources.owner) && !monitor.isRunning)
        await resources.updateActivity(false)?.value
    }

    @Test("a hidden Settings authorization cannot reclaim a microphone after rapid return")
    func pendingMicrophoneAuthorization() async throws {
        var pending: [CheckedContinuation<Bool, Never>] = []
        var probes = 0
        let monitor = MicrophoneMonitor(operations: .init(authorize: {
            await withCheckedContinuation { pending.append($0) }
        }, makeProbe: { probes += 1; return Probe() }))
        let inventory = SettingsDeviceInventory(kind: .microphone, notifications: NotificationCenter(),
                                               load: { .init(devices: [], defaultID: nil) })
        let resources = SettingsRecordingResources(inputs: inventory, monitor: monitor)
        resources.updateActivity(true)
        resources.startTest(deviceID: nil, gainDB: 1)
        try await eventually { pending.count == 1 }
        let oldOwner = resources.owner
        resources.updateActivity(false)
        resources.updateActivity(true)
        resources.startTest(deviceID: "new", gainDB: 2)
        try await eventually { pending.count == 2 }
        pending[0].resume(returning: true)
        await Task.yield()
        #expect(!monitor.owns(oldOwner) && probes == 0)
        pending[1].resume(returning: true)
        try await eventually { monitor.isRunning }
        #expect(monitor.owns(resources.owner) && probes == 1)
        resources.updateActivity(false)
        try await eventually { !monitor.isRunning }
    }

    @Test("Settings camera hide releases its display claim while other surfaces and recording retain capture")
    func cameraVisibilityOwnership() async throws {
        var starts = 0, stops = 0
        let monitor = CameraPreviewMonitor(operations: .init(authorize: { _ in true }, start: { _, _, _ in
            starts += 1
        }, waitForFirstFrame: { _ in }, stop: { _ in stops += 1 }))
        let resources = SettingsCameraPreviewResources(monitor: monitor)
        resources.updateActivity(true)
        resources.togglePreview(options: .init(enabled: true))
        try await eventually { monitor.isRunning }
        monitor.setVisible(true, owner: "foreign")
        resources.updateActivity(false)
        await Task.yield()
        #expect(monitor.isObserved && monitor.isRunning && stops == 0)
        resources.togglePreview(options: .init(enabled: true))
        await Task.yield()
        #expect(starts == 1 && stops == 0)
        monitor.setVisible(false, owner: "foreign")
        await monitor.stopIfUnobserved()
        #expect(!monitor.isObserved && !monitor.isRunning && stops == 1)
        resources.updateActivity(true)
        #expect(!monitor.isRunning && starts == 1, "returning never starts hardware without a new Preview action")
        resources.togglePreview(options: .init(enabled: true))
        try await eventually { monitor.isRunning }
        let capture = await monitor.prepareForRecording(options: .init(enabled: true))
        _ = try #require(capture)
        monitor.useRecordingSource(capture)
        resources.updateActivity(false)
        await Task.yield()
        #expect(monitor.recordingLocked && monitor.isRunning && !monitor.isObserved && stops == 1)
        monitor.recordingEnded()
    }

    @Test("cancelled permission polling retires its wait and performs no further reads")
    func permissionPollCancellation() async throws {
        var reads = 0
        let poll = Task { await SettingsActivity.poll(interval: .seconds(60)) { reads += 1 } }
        try await eventually { reads == 1 }
        poll.cancel()
        await poll.value
        #expect(reads == 1)
        let cancelledBeforeStart = Task { await SettingsActivity.poll(interval: .seconds(60)) { reads += 1 } }
        cancelledBeforeStart.cancel()
        await cancelledBeforeStart.value
        #expect(reads == 1)
    }

    @Test("late camera start completion after hide cannot stop the new visible preview")
    func pendingCameraStart() async throws {
        var pending: CheckedContinuation<Void, Never>?
        var starts = 0, stops = 0
        let monitor = CameraPreviewMonitor(operations: .init(authorize: { _ in true }, start: { _, _, _ in
            starts += 1
            if starts == 1 { await withCheckedContinuation { pending = $0 } }
        }, waitForFirstFrame: { _ in }, stop: { _ in stops += 1 }))
        let resources = SettingsCameraPreviewResources(monitor: monitor)
        resources.updateActivity(true)
        resources.togglePreview(options: .init(enabled: true, deviceID: "old"))
        try await eventually { pending != nil }
        resources.updateActivity(false)
        try await eventually { !monitor.isStarting && stops == 1 }
        resources.updateActivity(true)
        resources.togglePreview(options: .init(enabled: true, deviceID: "new"))
        try await eventually { monitor.isRunning }
        pending?.resume()
        try await eventually { stops == 2 }
        #expect(starts == 2 && monitor.isRunning && monitor.isObserved)
        resources.updateActivity(false)
        try await eventually { !monitor.isRunning && stops == 3 }
    }

    @Test("hotplug refreshes cached choices only while the Settings page is visible")
    func hotplugAndLifecycle() {
        let notifications = NotificationCenter()
        let format = CameraFormatDescriptor(width: 1920, height: 1080, fpsRanges: [24...60])
        var connected = true
        var loads = 0
        let inventory = SettingsDeviceInventory(kind: .camera, notifications: notifications) {
            loads += 1
            return .init(devices: connected ? [.init(id: "camera", name: "Fixture camera", formats: [format])] : [],
                         defaultID: connected ? "camera" : nil)
        }
        #expect(loads == 0)
        inventory.start()
        inventory.start()
        #expect(loads == 1)
        #expect(inventory.formats(for: nil) == [format])
        #expect(!inventory.missing("camera"))
        connected = false
        notifications.post(name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        #expect(loads == 2)
        #expect(inventory.missing("camera"))
        #expect(inventory.formats(for: "camera").isEmpty)
        inventory.stop()
        connected = true
        notifications.post(name: AVCaptureDevice.wasConnectedNotification, object: nil)
        #expect(loads == 2)
        inventory.start()
        #expect(loads == 3)
        #expect(!inventory.missing("camera"))
        #expect(inventory.formats(for: "camera") == [format])
        #expect(inventory.formats(for: "disconnected-other-camera").isEmpty)
        inventory.stop()
    }

    @Test("discarding a visible page removes its notification observers")
    func releasesObservers() {
        let notifications = NotificationCenter()
        var loads = 0
        var inventory: SettingsDeviceInventory? = SettingsDeviceInventory(kind: .microphone, notifications: notifications) {
            loads += 1
            return .init(devices: [], defaultID: nil)
        }
        weak let released = inventory
        inventory?.start()
        inventory = nil
        #expect(released == nil)
        notifications.post(name: AVCaptureDevice.wasConnectedNotification, object: nil)
        #expect(loads == 1)
    }
}
