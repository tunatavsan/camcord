import AppKit
import Foundation
import Observation
@preconcurrency import ScreenCaptureKit
import Testing
import os
@testable import Camcord

@MainActor @Suite("Studio session intent and shared settings")
struct StudioSessionTests {
    @Test("native camera observers retain the device while image-owner handoffs alone control image polling")
    func nativeCameraImageOwnership() async throws {
        var starts = 0, stops = 0
        let monitor = CameraPreviewMonitor(operations: .init(authorize: { _ in true },
            start: { _, _, _ in starts += 1 }, waitForFirstFrame: { _ in }, stop: { _ in stops += 1 }))
        monitor.setVisible(true, owner: "native", rendersImage: false)
        await monitor.start(deviceID: "native", format: .auto)
        let original = try #require(monitor.currentPreviewSource() as? CameraCapture)
        #expect(monitor.isObserved && monitor.isRunning && !monitor.isRenderingImagePreview)
        monitor.setVisible(true, owner: "native", rendersImage: true)
        #expect(monitor.isRenderingImagePreview)
        #expect((monitor.currentPreviewSource() as? CameraCapture) === original)
        monitor.setVisible(true, owner: "foreign")
        monitor.setVisible(true, owner: "native", rendersImage: false)
        #expect(monitor.isRenderingImagePreview)
        monitor.setVisible(false, owner: "foreign")
        #expect(!monitor.isRenderingImagePreview && monitor.isObserved)
        await monitor.stopIfUnobserved()
        #expect(monitor.isRunning && stops == 0 && starts == 1)
        #expect((monitor.currentPreviewSource() as? CameraCapture) === original)
        monitor.setVisible(false, owner: "native", rendersImage: false)
        await monitor.stopIfUnobserved()
        #expect(!monitor.isObserved && !monitor.isRunning && stops == 1)
    }

    @Test("enabled authorized idle meters start without prompting, hide/disable retire only Studio and stolen leases stay retired")
    func automaticMicrophoneLifecycle() async throws {
        let defaults = try isolatedDefaults(), coordinator = CaptureCoordinator()
        var settings = RecordingSettings(); settings.microphone = true; settings.save(to: defaults)
        let controller = RecordingController(coordinator: coordinator, defaults: defaults)
        var prompts = 0, probes: [Probe] = []
        let signal = AudioLevels(rmsDBFS: -18, peakDBFS: -6, limited: false)
        let microphone = MicrophoneMonitor(operations: .init(authorize: { prompts += 1; return true }, makeProbe: {
            let probe = Probe(levels: signal); probes.append(probe); return probe
        }, isAuthorized: { true }))
        let session = StudioSession(defaults: defaults, controller: controller, recordingState: .init(), coordinator: coordinator,
                                    microphoneMonitor: microphone,
                                    operations: .init(screenCaptureAuthorized: { false }, content: { _ in throw CancellationError() }))
        await Task.yield()
        #expect(probes.isEmpty && prompts == 0)
        session.setVisibility(moduleVisible: true, windowAllowsPreview: true, captureTransition: false)
        try await wait { session.microphoneLevels == signal }
        #expect(probes.count == 1 && prompts == 0)
        let foreign = UUID()
        await microphone.start(owner: foreign, deviceID: "foreign", gainDB: 0)
        try await wait { !session.microphoneTestRequested }
        await microphone.release(owner: foreign)
        for _ in 0..<20 { await Task.yield() }
        #expect(probes.count == 2 && !microphone.isRunning && session.microphoneLevels == nil)
        session.setVisibility(moduleVisible: false, windowAllowsPreview: true, captureTransition: false)
        session.setVisibility(moduleVisible: true, windowAllowsPreview: true, captureTransition: false)
        try await wait { session.ownsMicrophoneTest && probes.count == 3 }
        #expect(prompts == 1)
        session.updateSettings { $0.microphone = false }
        try await wait { !microphone.isRunning && probes[2].stops == 1 }
        #expect(probes[2].stops == 1)
        await session.releaseVisibleResources()
    }

    @Test("an enabled camera uses the passive permission mode and refuses incompatible visible owners")
    func passiveCameraLifecycle() async throws {
        let defaults = try isolatedDefaults(), coordinator = CaptureCoordinator()
        var settings = RecordingSettings(); settings.camera.enabled = true; settings.camera.deviceID = "studio"; settings.save(to: defaults)
        let controller = RecordingController(coordinator: coordinator, defaults: defaults)
        var permissions: [Bool] = [], starts = 0, stops = 0
        // Camera readiness must not wait for the enabled default microphone's hardware.
        let microphone = MicrophoneMonitor(operations: .init(authorize: { false }, makeProbe: {
            Probe(levels: .init(rmsDBFS: -18, peakDBFS: -6, limited: false))
        }, isAuthorized: { true }))
        let monitor = CameraPreviewMonitor(operations: .init(authorize: { permission in permissions.append(permission); return true },
            start: { _, _, _ in starts += 1 }, waitForFirstFrame: { _ in }, stop: { _ in stops += 1 }))
        let session = StudioSession(defaults: defaults, controller: controller, recordingState: .init(), coordinator: coordinator,
                                    microphoneMonitor: microphone,
                                    cameraMonitor: monitor,
                                    operations: .init(screenCaptureAuthorized: { false }, content: { _ in throw CancellationError() },
                                                      cameraAuthorized: { true }))
        await session.setVisibility(moduleVisible: true, windowAllowsPreview: true, captureTransition: false)?.value
        #expect(session.cameraPreviewRequested && monitor.isRunning)
        #expect(permissions == [false] && starts == 1)
        await session.setVisibility(moduleVisible: false, windowAllowsPreview: true, captureTransition: false)?.value
        #expect(!monitor.isRunning)
        monitor.setVisible(true, owner: "foreign")
        await monitor.start(deviceID: "foreign", format: .auto, requestPermission: true)
        await session.setVisibility(moduleVisible: true, windowAllowsPreview: true, captureTransition: false)?.value
        #expect(!session.cameraPreviewRequested && starts == 2 && stops == 1)
        #expect(permissions == [false, true] && monitor.isRunning)
        await session.releaseVisibleResources()
        #expect(monitor.isRunning && stops == 1)
        monitor.setVisible(false, owner: "foreign")
        await monitor.stopIfUnobserved()
    }

    @Test("manual Clear invalidates an in-flight refresh immediately and stale errors cannot restore its spinner")
    func clearDuringRefresh() async throws {
        let defaults = try isolatedDefaults(), coordinator = CaptureCoordinator()
        let controller = RecordingController(coordinator: coordinator, defaults: defaults)
        var pending: CheckedContinuation<SCShareableContent, any Error>?
        let session = StudioSession(defaults: defaults, controller: controller, recordingState: .init(), coordinator: coordinator,
                                    operations: .init(screenCaptureAuthorized: { true }, content: { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }))
        session.setVisibility(moduleVisible: true, windowAllowsPreview: true, captureTransition: false)
        let refresh = Task { await session.refreshSources() }
        try await wait { pending != nil }
        #expect(session.isRefreshingSources)
        session.clearSource()
        #expect(!session.isRefreshingSources && session.selectedSource == nil)
        pending?.resume(throwing: RegionProviderFailure())
        await refresh.value
        #expect(!session.isRefreshingSources && session.selectedSource == nil && session.issue == nil)
        await session.releaseVisibleResources()
    }

    enum RegionCompletion: CaseIterable, Sendable {
        case cancelledTask, cancellationError, supersededSource, currentFailure
    }
    private struct RegionProviderFailure: Error {}
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
        }, isAuthorized: { false }))
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
        await rasterCompletion(document)
        try #require(document.isReady && !document.isRasterizing && document.issue == nil)
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
        let microphone = MicrophoneMonitor(operations: .init(authorize: { microphoneCalls += 1; return false }, isAuthorized: { false }))
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
        let microphone = MicrophoneMonitor(operations: .init(authorize: { microphoneCalls += 1; return false }, isAuthorized: { false }))
        let camera = CameraPreviewMonitor(operations: .init(authorize: { _ in cameraCalls += 1; return false }))
        let session = StudioSession(defaults: defaults, controller: controller, recordingState: .init(), coordinator: coordinator,
                                    microphoneMonitor: microphone, cameraMonitor: camera,
                                    operations: .init(content: { _ in throw CancellationError() }, cameraAuthorized: { false }))
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

    @Test("background settings notifications safely enter a live hidden or visible session",
          arguments: [false, true], [false, true])
    func backgroundSettingsNotification(visible: Bool, defaultsNotification: Bool) async throws {
        let defaults = try isolatedDefaults(), coordinator = CaptureCoordinator()
        let controller = RecordingController(coordinator: coordinator, defaults: defaults)
        var sourceCalls = 0, cameraCalls = 0, microphoneCalls = 0
        let camera = CameraPreviewMonitor(operations: .init(authorize: { _ in cameraCalls += 1; return false }))
        let microphone = MicrophoneMonitor(operations: .init(authorize: { microphoneCalls += 1; return false }, isAuthorized: { false }))
        let session = StudioSession(defaults: defaults, controller: controller, recordingState: .init(), coordinator: coordinator,
                                    microphoneMonitor: microphone, cameraMonitor: camera,
                                    operations: .init(screenCaptureAuthorized: { true }, content: { _ in
                                        sourceCalls += 1
                                        throw CancellationError()
                                    }))
        if visible { session.setVisibility(moduleVisible: true, windowAllowsPreview: true, captureTransition: false) }
        let initial = session.settings
        var changed = initial
        changed.microphoneDeviceID = "BackgroundInput"
        defaults.set(try JSONEncoder().encode(changed), forKey: RecordingSettings.defaultsKey)
        let name = defaultsNotification ? UserDefaults.didChangeNotification : RecordingSettings.didChangeNotification
        // Detached work deliberately exercises NotificationCenter's arbitrary posting thread.
        let postedOffMain = await Task.detached { Self.postNotification(name) }.value
        #expect(postedOffMain)
        if visible { try await wait { session.settings.microphoneDeviceID == "BackgroundInput" } }
        else {
            await Task.yield()
            #expect(session.settings == initial)
        }
        #expect(sourceCalls == 0 && cameraCalls == 0 && microphoneCalls == 0)
        #expect(session.selectedSource == nil && session.stageImage == nil)
        await session.releaseVisibleResources()
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
        await rasterCompletion(document)
        #expect(document.issue == .imageTooLarge && !document.isReady)
        document.dismissIssue()
        let failed = await controller.performPreparedStart(countdownSeconds: 0, screenFrame: .zero) { calls += 1; return true }
        #expect(!failed && calls == 0)
        document.remove(try #require(document.layers.first?.id))
        #expect(await controller.performPreparedStart(countdownSeconds: 0, screenFrame: .zero) { calls += 1; return true })
        #expect(calls == 1)
        await session.releaseVisibleResources()
    }

    @Test("region selection ignores cancelled or superseded inner provider failures but reports current errors",
          arguments: RegionCompletion.allCases)
    func regionProviderCompletion(completion: RegionCompletion) async throws {
        let defaults = try isolatedDefaults(), coordinator = CaptureCoordinator()
        let controller = RecordingController(coordinator: coordinator, defaults: defaults)
        var pending: CheckedContinuation<SCShareableContent, any Error>?
        var providerCalls = 0
        let session = StudioSession(defaults: defaults, controller: controller, recordingState: .init(), coordinator: coordinator,
                                    operations: .init(screenCaptureAuthorized: { true }, content: { refresh in
                                        #expect(refresh)
                                        providerCalls += 1
                                        return try await withCheckedThrowingContinuation { pending = $0 }
                                    }))
        let original = StudioSourceChoice(id: .window(1), title: "Original", frame: CGRect(x: 0, y: 0, width: 80, height: 48),
                                          pixelSize: CGSize(width: 80, height: 48))
        let replacement = StudioSourceChoice(id: .window(2), title: "Replacement", frame: CGRect(x: 0, y: 0, width: 96, height: 60),
                                             pixelSize: CGSize(width: 96, height: 60))
        // Source values alone do not construct SCK objects or start hidden preview capture.
        session.selectSource(original)
        let request = Task { await session.selectRegion(CGRect(x: 10, y: 10, width: 40, height: 30), displayID: 1) }
        defer {
            request.cancel()
            pending?.resume(throwing: CancellationError())
        }
        try await wait { pending != nil }
        if completion == .cancelledTask { request.cancel() }
        if completion == .supersededSource { session.selectSource(replacement) }
        let provider = try #require(pending)
        pending = nil
        if completion == .cancellationError { provider.resume(throwing: CancellationError()) }
        else { provider.resume(throwing: RegionProviderFailure()) }
        await request.value
        #expect(providerCalls == 1)
        #expect(session.selectedSource == (completion == .supersededSource ? replacement : original))
        #expect(session.issue == (completion == .currentFailure ? .sourceUnavailable : nil))
        #expect(session.stageImage == nil)
        await session.releaseVisibleResources()
    }

    @Test("negative raw region dimensions are rejected before content lookup", arguments: [true, false])
    func invalidRegionDimensions(negativeWidth: Bool) async throws {
        let defaults = try isolatedDefaults(), coordinator = CaptureCoordinator()
        let controller = RecordingController(coordinator: coordinator, defaults: defaults)
        var providerCalls = 0
        let session = StudioSession(defaults: defaults, controller: controller, recordingState: .init(), coordinator: coordinator,
                                    operations: .init(content: { _ in
                                        providerCalls += 1
                                        throw RegionProviderFailure()
                                    }))
        let rect = CGRect(x: 40, y: 40, width: negativeWidth ? -20 : 20, height: negativeWidth ? 20 : -20)
        await session.selectRegion(rect, displayID: 1)
        #expect(providerCalls == 0)
        #expect(session.issue == nil && session.selectedSource == nil)
        await session.releaseVisibleResources()
    }

    nonisolated private static func postNotification(_ name: Notification.Name) -> Bool {
        let offMain = !Thread.isMainThread
        NotificationCenter.default.post(name: name, object: nil)
        return offMain
    }

    private func rasterCompletion(_ document: StudioLayerDocument) async {
        await withCheckedContinuation { continuation in
            guard document.isRasterizing else { continuation.resume(); return }
            // Both successful and failed renders settle this actual observed property.
            withObservationTracking { _ = document.isRasterizing } onChange: {
                // Observation fires before the value changes; resume after that actor turn.
                Task { @MainActor in continuation.resume() }
            }
        }
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
