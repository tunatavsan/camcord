import AVFoundation
import AppKit
import Combine
import Observation
@preconcurrency import ScreenCaptureKit
import SwiftUI

@MainActor @Observable
final class StudioSession {
    @MainActor struct Operations {
        var screenCaptureAuthorized: () -> Bool = { CGPreflightScreenCaptureAccess() }
        var content: (Bool) async throws -> SCShareableContent
        var makePreview: () -> any StudioPreviewCapture = { StudioScreenPreview() }
        var mainDisplayID: () -> UInt32 = { CGMainDisplayID() }
        var cameraAuthorized: () -> Bool = { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
        var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    }

    let recordingState: RecordingStateModel
    let layers: StudioLayerDocument
    let microphoneMonitor: MicrophoneMonitor
    let cameraMonitor: CameraPreviewMonitor
    let sourceThumbnails: StudioSourceThumbnails
    private(set) var settings: RecordingSettings
    private(set) var sources: [StudioSourceChoice] = []
    private(set) var selectedSource: StudioSourceChoice?
    private(set) var stageImage: NSImage?
    private(set) var previewState: StudioPreviewState = .inactive
    private(set) var isRefreshingSources = false
    private(set) var issue: StudioIssue?
    private(set) var cameraPreviewRequested = false
    private(set) var microphoneTestRequested = false
    private(set) var systemAudioTestRequested = false
    private(set) var systemAudioLevels: AudioLevels?
    private var frameCameraContentRect: CGRect?
    var countdownSeconds: Int {
        didSet {
            if !Self.countdownChoices.contains(countdownSeconds) { countdownSeconds = 3 }
            defaults.set(countdownSeconds, forKey: Self.countdownKey)
        }
    }

    static let countdownChoices = [0, 3, 5, 10]
    static let countdownKey = "studio.countdownSeconds"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let controller: RecordingController
    @ObservationIgnored private let operations: Operations
    @ObservationIgnored private let idleRenderer = StudioIdlePreviewRenderer()
    @ObservationIgnored private var layerSnapshot = StudioLayerSnapshot.empty
    @ObservationIgnored private var visibility = StudioVisibility()
    @ObservationIgnored private let previewOwner = StudioPreviewOwner()
    private var previewCapture: (any StudioPreviewCapture)? { previewOwner.capture as? any StudioPreviewCapture }
    private var previewGeneration: UUID { previewOwner.generation }
    @ObservationIgnored private var sourceGeneration = UUID()
    @ObservationIgnored private var defaultSourcePolicy = StudioDefaultSourcePolicy()
    @ObservationIgnored private var stageOwner: UUID?
    @ObservationIgnored private var microphoneOwner = UUID()
    @ObservationIgnored private var cameraOwner = CameraPreviewMonitor.makeOwnerID("studio")
    @ObservationIgnored private var cameraIntentGeneration = UUID()
    @ObservationIgnored private var microphoneIntentGeneration = UUID()
    @ObservationIgnored private var deviceSettingsGeneration = UUID()
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var stateObservation: AnyCancellable?
    @ObservationIgnored private var microphoneObservation: AnyCancellable?
    @ObservationIgnored private var settingsObservation: AnyCancellable?
    @ObservationIgnored private var lastSourceRefresh = -Double.infinity
    @ObservationIgnored private var stageRendering = false

    init(defaults: UserDefaults, controller: RecordingController, recordingState: RecordingStateModel,
         coordinator: CaptureCoordinator, layers: StudioLayerDocument = .init(),
         microphoneMonitor: MicrophoneMonitor = .shared, cameraMonitor: CameraPreviewMonitor = .shared,
         operations: Operations? = nil) {
        self.defaults = defaults
        self.controller = controller
        self.recordingState = recordingState
        self.layers = layers
        self.microphoneMonitor = microphoneMonitor
        self.cameraMonitor = cameraMonitor
        let configured = operations ?? Operations(content: { try await coordinator.contentCache.content(forceRefresh: $0) })
        self.operations = configured
        sourceThumbnails = StudioSourceThumbnails(operations: .init(batch: { choices, maximum in
            guard configured.screenCaptureAuthorized(), !Task.isCancelled,
                  let content = try? await configured.content(false), !Task.isCancelled else { return [:] }
            return await StudioSourceThumbnails.capture(choices, content: content, maximum: maximum)
        }))
        settings = RecordingSettings.load(from: defaults)
        let saved = defaults.object(forKey: Self.countdownKey) as? Int
        countdownSeconds = saved.flatMap { Self.countdownChoices.contains($0) ? $0 : nil } ?? 3
        layerSnapshot = layers.snapshot
        controller.updateStudioLayers(layers.snapshot)
        controller.updateStudioLayerReadiness(layers.isReady)
        layers.onReadinessChange = { [weak self] ready in self?.controller.updateStudioLayerReadiness(ready) }
        layers.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.layerSnapshot = snapshot
            self.controller.updateStudioLayers(snapshot)
        }
        // Combine can invoke a sink on its publisher's thread. These Sendable callbacks
        // stay nonisolated; only the explicit MainActor tasks read or change session state.
        stateObservation = recordingState.$state.combineLatest(recordingState.$isStarting, recordingState.$isFinishing)
            .sink { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in await self?.recordingStateChanged() }
            }
        microphoneObservation = microphoneMonitor.$activeOwner.combineLatest(microphoneMonitor.$recordingLocked)
            .sink { @Sendable [weak self] _, locked in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if locked || !self.microphoneMonitor.owns(self.microphoneOwner) {
                        self.microphoneTestRequested = false
                        // A superseded Studio lease must not restart when a foreign lease ends.
                        await self.microphoneMonitor.release(owner: self.microphoneOwner)
                    }
                }
            }
        settingsObservation = NotificationCenter.default.publisher(for: RecordingSettings.didChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification))
            .sink { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.visibility.allowsPreview else { return }
                    self.acceptSettings(RecordingSettings.load(from: self.defaults))
                }
            }
    }

    var canStart: Bool {
        selectedSource != nil && issue != .sourceUnavailable && issue != .screenPermissionRequired && !controller.isBusy && visibility.allowsPreview
            && layers.isReady && !layers.isRasterizing && layers.issue == nil
    }
    var isBusy: Bool { controller.isBusy }
    var canvasSize: CGSize {
        if let size = stageImage?.size, Self.validCanvasSize(size) { return size }
        return Self.plannedCanvasSize(source: selectedSource, settings: settings)
    }
    /// Destination units and top-left origin; the camera's placement math uses the
    /// fitted live window content, while layer bounds use the entire canvas.
    var cameraContentRect: CGRect {
        frameCameraContentRect ?? CGRect(origin: .zero, size: canvasSize)
    }
    static func mappedCameraContentRect(_ rect: CGRect?, bufferSize: CGSize, canvasSize: CGSize) -> CGRect {
        let fullCanvas = CGRect(origin: .zero, size: canvasSize)
        guard validCanvasSize(bufferSize), validCanvasSize(canvasSize) else { return fullCanvas }
        let fullBuffer = CGRect(origin: .zero, size: bufferSize)
        let source: CGRect
        if let rect, rect.origin.x.isFinite, rect.origin.y.isFinite,
           rect.size.width.isFinite, rect.size.height.isFinite, rect.size.width > 0, rect.size.height > 0,
           !rect.intersection(fullBuffer).isEmpty { source = rect.intersection(fullBuffer) }
        else { source = fullBuffer }
        let sx = canvasSize.width / bufferSize.width, sy = canvasSize.height / bufferSize.height
        return CGRect(x: source.minX * sx, y: source.minY * sy, width: source.width * sx, height: source.height * sy)
    }
    static func plannedCanvasSize(source: StudioSourceChoice?, settings: RecordingSettings) -> CGSize {
        guard let source, validCanvasSize(source.pixelSize) else { return CGSize(width: 16, height: 9) }
        guard case .window = source.id else { return source.pixelSize }
        let planned = settings.canvasAspect.canvasSize(window: source.pixelSize, display: .zero)
        let size = CGSize(width: planned.width, height: planned.height)
        return validCanvasSize(size) ? size : CGSize(width: 16, height: 9)
    }
    private static func validCanvasSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width >= 2 && size.height >= 2
    }
    var microphoneLevels: AudioLevels? {
        recordingState.state != .idle ? recordingState.health?.microphone.levels
            : microphoneMonitor.owns(microphoneOwner) ? microphoneMonitor.levels : nil
    }
    var ownsMicrophoneTest: Bool { microphoneMonitor.owns(microphoneOwner) }
    func dismissIssue() { issue = nil }

    func setVisibility(moduleVisible: Bool, windowAllowsPreview: Bool, captureTransition: Bool) {
        let new = StudioVisibility(moduleVisible: moduleVisible, windowAllowsPreview: windowAllowsPreview,
                                   captureTransition: captureTransition)
        guard new != visibility else { return }
        visibility = new
        deviceSettingsGeneration = UUID()
        if !new.allowsPreview {
            retireVisibleResources()
        } else {
            settings = RecordingSettings.load(from: defaults)
            sourceThumbnails.update(choices: thumbnailChoices, visible: true)
            Task { [weak self] in
                await self?.reconcileDevices()
                await self?.reconcilePreview()
            }
        }
    }

    var thumbnailChoices: [StudioSourceChoice] {
        if let selectedSource, case .region = selectedSource.id { return sources + [selectedSource] }
        return sources
    }

    func refreshSources() async {
        guard visibility.allowsPreview, !isRefreshingSources else { return }
        let now = operations.uptime()
        guard now - lastSourceRefresh >= 1 else { return }
        guard operations.screenCaptureAuthorized() else {
            resetPreview()
            systemAudioLevels = nil
            issue = .screenPermissionRequired
            previewState = .permissionRequired
            return
        }
        lastSourceRefresh = now
        sourceGeneration = UUID()
        let token = sourceGeneration
        isRefreshingSources = true
        defer { if sourceGeneration == token { isRefreshingSources = false } }
        do {
            let content = try await operations.content(true)
            guard !Task.isCancelled, sourceGeneration == token, visibility.allowsPreview else { return }
            sources = StudioSourceResolver.choices(in: content, settings: settings)
            issue = nil
            if let selectedSource, case .region = selectedSource.id {} else if let selectedSource, !controller.isBusy {
                if let updated = sources.first(where: { $0.id == selectedSource.id }) {
                    self.selectedSource = updated
                    if updated != selectedSource { resetPreview() }
                } else {
                    resetPreview()
                    issue = .sourceUnavailable
                    previewState = .unavailable
                    if defaultSourcePolicy.sourceDisappeared(selectedSource.id, idle: true) { self.selectedSource = nil }
                }
            }
            if selectedSource == nil, !controller.isBusy,
               let choice = defaultSourcePolicy.choose(from: sources, mainDisplayID: operations.mainDisplayID()) {
                selectedSource = choice
                issue = nil
                resetPreview()
            }
            sourceThumbnails.update(choices: thumbnailChoices, visible: true)
            await reconcilePreview()
        } catch {
            guard sourceGeneration == token, visibility.allowsPreview else { return }
            issue = .sourceListUnavailable
        }
    }

    func selectSource(_ source: StudioSourceChoice) {
        guard !controller.isBusy, source.frame.origin.x.isFinite, source.frame.origin.y.isFinite,
              source.frame.width.isFinite, source.frame.height.isFinite,
              source.frame.width > 1, source.frame.height > 1,
              source.pixelSize.width.isFinite, source.pixelSize.height.isFinite,
              source.pixelSize.width >= 2, source.pixelSize.height >= 2 else { return }
        sourceGeneration = UUID()
        isRefreshingSources = false
        defaultSourcePolicy.manualIntent()
        selectedSource = source
        issue = nil
        sourceThumbnails.update(choices: thumbnailChoices, visible: visibility.allowsPreview)
        resetPreview()
        Task { [weak self] in await self?.reconcilePreview() }
    }

    func selectRegion(_ cgRect: CGRect, displayID: CGDirectDisplayID) async {
        guard !controller.isBusy, cgRect.origin.x.isFinite, cgRect.origin.y.isFinite,
              cgRect.size.width.isFinite, cgRect.size.height.isFinite,
              cgRect.size.width > 1, cgRect.size.height > 1 else { return }
        sourceGeneration = UUID()
        isRefreshingSources = false
        defaultSourcePolicy.manualIntent()
        let token = sourceGeneration
        do {
            let content = try await operations.content(true)
            guard !Task.isCancelled, sourceGeneration == token, !controller.isBusy else { return }
            guard let display = content.displays.first(where: { $0.displayID == displayID }),
                  let clamp = RegionClamp.clamp(region: cgRect, displays: [.init(frame: display.frame,
                                                                               scale: StudioSourceResolver.scale(display))]),
                  clamp.pixelWidth >= 2, clamp.pixelHeight >= 2 else { issue = .sourceUnavailable; return }
            let target = RecordingEngine.Target.region(clamp, display, excluding: nil)
            selectSource(StudioSourceChoice(id: .region(displayID), title: String(localized: "Region", comment: "Studio selected source"),
                                           frame: clamp.clampedRegion,
                                           pixelSize: StudioSourceResolver.pixelSize(of: target, settings: settings)))
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), sourceGeneration == token,
                  !controller.isBusy else { return }
            issue = .sourceUnavailable
        }
    }

    func clearSource() {
        guard !controller.isBusy else { return }
        sourceGeneration = UUID()
        isRefreshingSources = false
        defaultSourcePolicy.manualIntent()
        selectedSource = nil
        sourceThumbnails.update(choices: thumbnailChoices, visible: visibility.allowsPreview)
        resetPreview()
        previewState = visibility.allowsPreview ? .noSource : .inactive
    }

    func updateSettings(_ change: (inout RecordingSettings) -> Void) {
        var current = RecordingSettings.load(from: defaults)
        change(&current)
        current.camera = current.camera.resolved()
        current.save(to: defaults)
        acceptSettings(current, requestPermission: true)
    }

    private func acceptSettings(_ current: RecordingSettings, requestPermission: Bool = false) {
        let before = settings
        guard current != before else { return }
        settings = current
        if microphoneMonitor.owns(microphoneOwner) {
            microphoneMonitor.updateGain(current.microphoneGainDB, owner: microphoneOwner)
        }
        let micChanged = before.microphone != current.microphone || before.microphoneDeviceID != current.microphoneDeviceID
        let cameraChanged = before.camera.enabled != current.camera.enabled
            || before.camera.deviceID != current.camera.deviceID || before.camera.format != current.camera.format
        if micChanged || cameraChanged {
            deviceSettingsGeneration = UUID()
            let deviceToken = deviceSettingsGeneration
            let requestedMicrophone = current.microphone, requestedDevice = current.microphoneDeviceID
            let requestedCamera = current.camera
            Task { [weak self] in
                guard let self, self.visibility.allowsPreview, self.deviceSettingsGeneration == deviceToken,
                      self.settings.microphone == requestedMicrophone, self.settings.microphoneDeviceID == requestedDevice,
                      self.settings.camera == requestedCamera else { return }
                if micChanged { await self.setMicrophoneTestRequested(false) }
                guard self.deviceSettingsGeneration == deviceToken, self.visibility.allowsPreview else { return }
                if cameraChanged, self.cameraPreviewRequested {
                    if self.cameraMonitor.canObserve(options: current.camera, owner: self.cameraOwner) {
                        await self.cameraMonitor.cameraSettingsChanged(current.camera)
                    } else { await self.setCameraPreviewRequested(false) }
                }
                guard self.deviceSettingsGeneration == deviceToken, self.visibility.allowsPreview else { return }
                await self.reconcileDevices(requestMicrophonePermission: requestPermission && !before.microphone && current.microphone,
                                            requestCameraPermission: requestPermission && !before.camera.enabled && current.camera.enabled)
            }
        }
        if before.canvasAspect != current.canvasAspect || before.resolutionScale != current.resolutionScale
            || before.systemAudio != current.systemAudio {
            systemAudioLevels = nil
            resetPreview()
            Task { [weak self] in await self?.reconcilePreview() }
        }
        previewCapture?.updateGain(current.resolvedSystemAudioGainDB)
    }

    func setCameraPreviewRequested(_ requested: Bool, requestPermission: Bool = true) async {
        cameraIntentGeneration = UUID()
        let token = cameraIntentGeneration
        guard requested, visibility.allowsPreview, !controller.isBusy else {
            cameraPreviewRequested = false
            cameraMonitor.setVisible(false, owner: cameraOwner)
            await cameraMonitor.stopIfUnobserved()
            return
        }
        guard cameraMonitor.canObserve(options: settings.camera, owner: cameraOwner) else {
            cameraPreviewRequested = false
            cameraMonitor.setVisible(false, owner: cameraOwner)
            return
        }
        cameraPreviewRequested = true
        cameraMonitor.setVisible(true, owner: cameraOwner)
        await cameraMonitor.start(deviceID: settings.camera.deviceID, format: settings.camera.format, requestPermission: requestPermission)
        guard cameraIntentGeneration == token, cameraPreviewRequested, visibility.allowsPreview else { return }
        if !cameraMonitor.isRunning { cameraPreviewRequested = false; cameraMonitor.setVisible(false, owner: cameraOwner) }
    }

    func setMicrophoneTestRequested(_ requested: Bool, requestPermission: Bool = true) async {
        microphoneIntentGeneration = UUID()
        let token = microphoneIntentGeneration
        let owner = microphoneOwner
        guard requested, visibility.allowsPreview, !controller.isBusy else {
            microphoneTestRequested = false
            await microphoneMonitor.release(owner: owner)
            return
        }
        guard requestPermission || microphoneMonitor.canStartPassively(owner: owner) else { return }
        microphoneTestRequested = true
        await microphoneMonitor.start(owner: owner, deviceID: settings.microphoneDeviceID, gainDB: settings.microphoneGainDB, requestPermission: requestPermission)
        guard microphoneIntentGeneration == token, microphoneOwner == owner, visibility.allowsPreview else { return }
        microphoneTestRequested = microphoneMonitor.owns(owner) && (microphoneMonitor.isRunning || microphoneMonitor.isStarting)
    }

    private func reconcileDevices(requestMicrophonePermission: Bool = false, requestCameraPermission: Bool = false) async {
        guard visibility.allowsPreview, !controller.isBusy, recordingState.state == .idle,
              !recordingState.isStarting, !recordingState.isFinishing else {
            await setMicrophoneTestRequested(false)
            await setCameraPreviewRequested(false)
            return
        }
        let token = deviceSettingsGeneration
        if settings.microphone {
            if !microphoneMonitor.owns(microphoneOwner), microphoneMonitor.canStartPassively(owner: microphoneOwner) {
                await setMicrophoneTestRequested(true, requestPermission: requestMicrophonePermission)
            }
        } else if microphoneTestRequested { await setMicrophoneTestRequested(false) }
        guard deviceSettingsGeneration == token, visibility.allowsPreview, !controller.isBusy,
              recordingState.state == .idle, !recordingState.isStarting, !recordingState.isFinishing else { return }
        if settings.camera.enabled, requestCameraPermission || operations.cameraAuthorized() {
            if !cameraPreviewRequested {
                await setCameraPreviewRequested(true, requestPermission: requestCameraPermission)
            }
        } else if cameraPreviewRequested { await setCameraPreviewRequested(false) }
    }

    func setSystemAudioTestRequested(_ requested: Bool) async {
        systemAudioTestRequested = requested && visibility.allowsPreview && !controller.isBusy && selectedSource != nil
        resetPreview()
        await reconcilePreview()
    }

    func startRecording() async {
        guard canStart, let choice = selectedSource else { return }
        let token = sourceGeneration
        do {
            guard operations.screenCaptureAuthorized() else { issue = .screenPermissionRequired; return }
            let content = try await operations.content(true)
            guard !Task.isCancelled, sourceGeneration == token, selectedSource?.id == choice.id, canStart else { return }
            let target = try StudioSourceResolver.resolve(choice, in: content, settings: settings)
            let old = detachPreview()
            if let old { await old.stop() }
            guard !Task.isCancelled, sourceGeneration == token, selectedSource?.id == choice.id, canStart else { return }
            systemAudioTestRequested = false
            _ = await controller.startPreparedTarget(target: target, countdownSeconds: countdownSeconds)
            await reconcilePreview()
        } catch { if sourceGeneration == token { issue = .sourceUnavailable } }
    }

    func stopRecording() async { await controller.stopRecording() }
    func pauseResume() { controller.pauseResume() }
    func retryPreview() async { issue = nil; resetPreview(); await reconcilePreview() }
    func releaseVisibleResources() async {
        visibility.moduleVisible = false
        retireVisibleResources()
    }

    private func retireVisibleResources() {
        deviceSettingsGeneration = UUID()
        sourceGeneration = UUID()
        isRefreshingSources = false
        sourceThumbnails.update(choices: thumbnailChoices, visible: false)
        cameraIntentGeneration = UUID()
        microphoneIntentGeneration = UUID()
        cameraPreviewRequested = false
        microphoneTestRequested = false
        systemAudioTestRequested = false
        systemAudioLevels = nil
        let oldMicrophoneOwner = microphoneOwner
        microphoneOwner = UUID()
        cameraMonitor.setVisible(false, owner: cameraOwner)
        cameraOwner = CameraPreviewMonitor.makeOwnerID("studio")
        if let stageOwner { controller.unsubscribeStage(owner: stageOwner) }
        stageOwner = nil
        let old = detachPreview()
        stageImage = nil
        frameCameraContentRect = nil
        previewState = .inactive
        Task { [microphoneMonitor, cameraMonitor] in
            await microphoneMonitor.release(owner: oldMicrophoneOwner)
            await cameraMonitor.stopIfUnobserved()
            if let old { await old.stop() }
        }
    }

    private func resetPreview() {
        let old = detachPreview()
        stageImage = nil
        frameCameraContentRect = nil
        if let old { Task { await old.stop() } }
    }

    private func detachPreview() -> (any StudioPreviewResource)? {
        poll?.cancel()
        poll = nil
        return previewOwner.detach()
    }

    private func recordingStateChanged() async {
        await reconcileDevices()
        if recordingState.isStarting || recordingState.isFinishing {
            resetPreview()
            return
        }
        await reconcilePreview()
    }

    private func reconcilePreview() async {
        guard visibility.allowsPreview else { return }
        if recordingState.state != .idle {
            let old = detachPreview()
            if let old { await old.stop() }
            guard visibility.allowsPreview, recordingState.state != .idle else { return }
            previewState = recordingState.state == .paused ? .paused : .recording
            if stageOwner == nil {
                let owner = UUID()
                stageOwner = owner
                controller.subscribeStage(owner: owner) { [weak self] frame in
                    Task { @MainActor [weak self] in await self?.receiveStage(frame, owner: owner) }
                }
            }
            return
        }
        if let stageOwner { controller.unsubscribeStage(owner: stageOwner); self.stageOwner = nil }
        guard !recordingState.isStarting, !recordingState.isFinishing, previewCapture == nil else { return }
        guard let choice = selectedSource else { previewState = .noSource; return }
        guard operations.screenCaptureAuthorized() else { previewState = .permissionRequired; issue = .screenPermissionRequired; return }
        previewOwner.invalidatePending()
        let token = previewGeneration
        previewState = .starting
        do {
            let content = try await operations.content(false)
            guard !Task.isCancelled, token == previewGeneration, visibility.allowsPreview,
                  selectedSource?.id == choice.id, recordingState.state == .idle, !recordingState.isStarting else { return }
            let target = try StudioSourceResolver.resolve(choice, in: content, settings: settings)
            let size = StudioSourceResolver.pixelSize(of: target, settings: settings)
            selectedSource = StudioSourceChoice(id: choice.id, title: choice.title, frame: choice.frame, pixelSize: size)
            let capture = operations.makePreview()
            capture.updateGain(settings.resolvedSystemAudioGainDB)
            let capturesAudio = settings.systemAudio || systemAudioTestRequested
            let installed = try await previewOwner.install(capture, generation: token) {
                try await capture.start(target: target, canvasSize: size, capturesAudio: capturesAudio)
            }
            guard installed else { return }
            guard !Task.isCancelled, token == previewGeneration, visibility.allowsPreview,
                  previewCapture === capture, recordingState.state == .idle, !recordingState.isStarting else {
                await capture.stop()
                return
            }
            previewState = .live
            issue = nil
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.previewGeneration == token, self.visibility.allowsPreview,
                          self.previewCapture === capture, self.recordingState.state == .idle else { return }
                    let captureStatus = capture.audioSnapshot()
                    if captureStatus.failed {
                        self.resetPreview()
                        self.systemAudioLevels = nil
                        self.issue = .previewFailed
                        self.previewState = .unavailable
                        return
                    }
                    if let frame = capture.latestFrame() {
                        let camera = self.cameraPreviewRequested ? self.cameraMonitor.currentPreviewFrame() : nil
                        let image = await self.idleRenderer.render(frame, camera: camera, options: self.settings.camera,
                                                                  layers: self.layerSnapshot, fitsWindow: target.isWindow)
                        guard !Task.isCancelled, self.previewGeneration == token, self.visibility.allowsPreview else { return }
                        if let image, let buffer = CMSampleBufferGetImageBuffer(frame.sample) {
                            self.stageImage = NSImage(cgImage: image, size: size)
                            let bufferSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
                            let content = target.isWindow ? StreamWriter.canvasFit(of: frame.sample)?.fitted : nil
                            self.frameCameraContentRect = Self.mappedCameraContentRect(content, bufferSize: bufferSize, canvasSize: size)
                        }
                    }
                    if self.settings.systemAudio || self.systemAudioTestRequested {
                        self.systemAudioLevels = captureStatus.levels
                    }
                    do { try await Task.sleep(for: .milliseconds(84)) } catch { return }
                }
            }
        } catch {
            guard token == previewGeneration, visibility.allowsPreview else { return }
            resetPreview()
            issue = (error as? StudioIssue) ?? .previewFailed
            previewState = .unavailable
        }
    }

    private func receiveStage(_ frame: PixelBufferBox, owner: UUID) async {
        guard stageOwner == owner, visibility.allowsPreview, !stageRendering else { return }
        stageRendering = true
        defer { stageRendering = false }
        let rendered = await cameraMonitor.renderer.render(frame.value, maximumWidth: 960)
        guard stageOwner == owner, visibility.allowsPreview, let rendered else { return }
        // StreamWriter already composed fit/camera/layers; this path only downscales.
        stageImage = NSImage(cgImage: rendered.image, size: rendered.size)
        frameCameraContentRect = Self.mappedCameraContentRect(frame.cameraContentRect, bufferSize: frame.pixelSize,
                                                            canvasSize: rendered.size)
    }
}

extension EnvironmentValues {
    @Entry var studioSession: StudioSession?
}
