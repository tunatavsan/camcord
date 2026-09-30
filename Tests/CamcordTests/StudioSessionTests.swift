import AppKit
import Foundation
import Testing
import os
@testable import Camcord

@MainActor @Suite("Studio session intent and shared settings")
struct StudioSessionTests {
    private final class Probe: MicrophoneProbe, @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: 0)
        let levels: AudioLevels
        init(levels: AudioLevels) { self.levels = levels }
        var stops: Int { state.withLock { $0 } }
        func start(deviceID: String?, gainDB: Double) async throws {}
        func stop() async { state.withLock { $0 += 1 } }
        func updateGain(_ gainDB: Double) {}
        func snapshot() -> MicrophoneProbeSnapshot { .init(levels: levels) }
    }

    @Test("superseded meters do not impersonate Studio and hiding releases only its lease")
    func microphoneOwnershipAndVisibility() async throws {
        let defaults = try isolatedDefaults(), coordinator = CaptureCoordinator()
        let controller = RecordingController(coordinator: coordinator, defaults: defaults)
        let levels = AudioLevels(rmsDBFS: -12, peakDBFS: -6, limited: false)
        var probes: [Probe] = []
        let microphone = MicrophoneMonitor(operations: .init(authorize: { true }, makeProbe: {
            let probe = Probe(levels: levels); probes.append(probe); return probe
        }))
        let session = StudioSession(defaults: defaults, controller: controller, recordingState: .init(), coordinator: coordinator,
                                    microphoneMonitor: microphone)
        session.setVisibility(moduleVisible: true, windowAllowsPreview: true, captureTransition: false)
        await session.setMicrophoneTestRequested(true)
        try await wait { session.microphoneLevels == levels }
        #expect(session.ownsMicrophoneTest)
        let other = UUID()
        await microphone.start(owner: other, deviceID: "B", gainDB: 0)
        try await wait { !session.microphoneTestRequested }
        #expect(session.microphoneLevels == nil && !session.ownsMicrophoneTest)
        session.setVisibility(moduleVisible: true, windowAllowsPreview: false, captureTransition: false)
        await Task.yield()
        #expect(microphone.owns(other) && microphone.isRunning && probes[1].stops == 0)
        session.setVisibility(moduleVisible: true, windowAllowsPreview: true, captureTransition: false)
        await Task.yield()
        #expect(!session.microphoneTestRequested && probes.count == 2)
        await microphone.release(owner: other)
        await session.releaseVisibleResources()
    }
    @Test("an already rasterized injected document seeds the real controller snapshot")
    func primedDocument() async throws {
        let document = StudioLayerDocument()
        document.addText("Primed")
        try await wait { !document.isRasterizing }
        let defaults = try isolatedDefaults(), coordinator = CaptureCoordinator()
        let controller = RecordingController(coordinator: coordinator, defaults: defaults)
        let session = StudioSession(defaults: defaults, controller: controller, recordingState: .init(), coordinator: coordinator,
                                    layers: document)
        #expect(controller.studioLayerSnapshot.layers.map(\.id) == document.layers.map(\.id))
        #expect(!controller.studioLayerSnapshot.isEmpty)
        await session.releaseVisibleResources()
    }
    @Test("initialization and hidden refresh never query sources or acquire devices")
    func passiveSession() async throws {
        let defaults = try isolatedDefaults()
        var sourceCalls = 0, microphoneCalls = 0, cameraCalls = 0
        let microphone = MicrophoneMonitor(operations: .init(authorize: { microphoneCalls += 1; return false }))
        let camera = CameraPreviewMonitor(operations: .init(authorize: { _ in cameraCalls += 1; return false }))
        let coordinator = CaptureCoordinator()
        let controller = RecordingController(coordinator: coordinator, defaults: defaults)
        let session = StudioSession(defaults: defaults, controller: controller, recordingState: .init(), coordinator: coordinator,
                                    microphoneMonitor: microphone, cameraMonitor: camera,
                                    operations: .init(screenCaptureAuthorized: { true }, content: { _ in
                                        sourceCalls += 1; throw CancellationError()
                                    }))
        await session.refreshSources()
        #expect(sourceCalls == 0 && microphoneCalls == 0 && cameraCalls == 0)
        session.setVisibility(moduleVisible: true, windowAllowsPreview: true, captureTransition: false)
        await Task.yield()
        #expect(sourceCalls == 0 && microphoneCalls == 0 && cameraCalls == 0)
        #expect(session.previewState == .noSource)
        session.setVisibility(moduleVisible: false, windowAllowsPreview: true, captureTransition: false)
        await session.refreshSources()
        #expect(sourceCalls == 0 && !session.canStart)
    }

    @Test("explicit source refresh is throttled and stops when the visible gate closes")
    func sourceRefreshThrottle() async throws {
        let defaults = try isolatedDefaults(), coordinator = CaptureCoordinator()
        let controller = RecordingController(coordinator: coordinator, defaults: defaults)
        var calls = 0, time = 10.0
        let session = StudioSession(defaults: defaults, controller: controller, recordingState: .init(), coordinator: coordinator,
                                    operations: .init(screenCaptureAuthorized: { true }, content: { _ in
                                        calls += 1; throw CancellationError()
                                    }, uptime: { time }))
        session.setVisibility(moduleVisible: true, windowAllowsPreview: true, captureTransition: false)
        await session.refreshSources()
        time = 10.9
        await session.refreshSources()
        #expect(calls == 1)
        time = 11
        await session.refreshSources()
        #expect(calls == 2)
        session.setVisibility(moduleVisible: true, windowAllowsPreview: false, captureTransition: false)
        time = 20
        await session.refreshSources()
        #expect(calls == 2)
    }

    @Test("visible external settings refresh display, and delta writes preserve fresh fields without passive devices")
    func externalSettings() async throws {
        let defaults = try isolatedDefaults(), coordinator = CaptureCoordinator()
        let controller = RecordingController(coordinator: coordinator, defaults: defaults)
        var cameraCalls = 0, microphoneCalls = 0
        let microphone = MicrophoneMonitor(operations: .init(authorize: { microphoneCalls += 1; return false }))
        let camera = CameraPreviewMonitor(operations: .init(authorize: { _ in cameraCalls += 1; return false }))
        let session = StudioSession(defaults: defaults, controller: controller, recordingState: .init(), coordinator: coordinator,
                                    microphoneMonitor: microphone, cameraMonitor: camera)
        session.setVisibility(moduleVisible: true, windowAllowsPreview: true, captureTransition: false)
        var changed = RecordingSettings.load(from: defaults)
        changed.microphoneDeviceID = "ExternalInput"
        changed.camera.deviceID = "ExternalCamera"
        changed.camera.enabled = true
        changed.save(to: defaults)
        try await wait { session.settings.microphoneDeviceID == "ExternalInput" && session.settings.camera.enabled }
        session.updateSettings { $0.microphoneGainDB = 5 }
        let stored = RecordingSettings.load(from: defaults)
        #expect(stored.camera.deviceID == "ExternalCamera" && stored.microphoneDeviceID == "ExternalInput")
        #expect(stored.microphoneGainDB == 5 && cameraCalls == 0 && microphoneCalls == 0)
        session.setVisibility(moduleVisible: false, windowAllowsPreview: true, captureTransition: false)
        changed.microphoneDeviceID = "HiddenChange"
        changed.save(to: defaults)
        await Task.yield()
        #expect(session.settings.microphoneDeviceID == "ExternalInput")
        session.setVisibility(moduleVisible: true, windowAllowsPreview: true, captureTransition: false)
        #expect(session.settings.microphoneDeviceID == "HiddenChange")
        #expect(cameraCalls == 0 && microphoneCalls == 0)
    }

    @Test("the current document readiness gates the shared controller and an empty document restores it")
    func documentAuthority() async throws {
        let defaults = try isolatedDefaults(), coordinator = CaptureCoordinator()
        let controller = RecordingController(coordinator: coordinator, defaults: defaults,
                                             preparedStartOperations: .init(screenCaptureAuthorized: { true }))
        var limits = StudioLayerLimits()
        limits.maximumSnapshotBytes = 1
        let document = StudioLayerDocument(rasterizer: .init(limits: limits))
        let session = StudioSession(defaults: defaults, controller: controller, recordingState: .init(), coordinator: coordinator,
                                    layers: document)
        var calls = 0
        document.addText("Failed current text")
        let pending = await controller.performPreparedStart(countdownSeconds: 0, screenFrame: .zero) { calls += 1; return true }
        #expect(!pending && calls == 0)
        try await wait { !document.isRasterizing }
        document.dismissIssue()
        let failed = await controller.performPreparedStart(countdownSeconds: 0, screenFrame: .zero) { calls += 1; return true }
        #expect(!failed && calls == 0)
        document.remove(try #require(document.layers.first?.id))
        #expect(await controller.performPreparedStart(countdownSeconds: 0, screenFrame: .zero) { calls += 1; return true })
        #expect(calls == 1)
        await session.releaseVisibleResources()
    }

    private func isolatedDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "Camcord.StudioSession.\(UUID())"))
    }
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
}
