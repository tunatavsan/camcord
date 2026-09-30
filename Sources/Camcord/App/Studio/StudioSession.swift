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
        var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    }

    let recordingState: RecordingStateModel
    let layers: StudioLayerDocument
    let microphoneMonitor: MicrophoneMonitor
    let cameraMonitor: CameraPreviewMonitor
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
    @ObservationIgnored private var stageOwner: UUID?
    @ObservationIgnored private var microphoneOwner = UUID()
    @ObservationIgnored private var cameraOwner = CameraPreviewMonitor.makeOwnerID("studio")
    @ObservationIgnored private var cameraIntentGeneration = UUID()
    @ObservationIgnored private var microphoneIntentGeneration = UUID()
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
        self.operations = operations ?? Operations(content: { try await coordinator.contentCache.content(forceRefresh: $0) })
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
        stateObservation = recordingState.$state.combineLatest(recordingState.$isStarting, recordingState.$isFinishing)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.recordingStateChanged() }
            }
        microphoneObservation = microphoneMonitor.$activeOwner.combineLatest(microphoneMonitor.$recordingLocked)
            .sink { [weak self] _, locked in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if locked || !self.microphoneMonitor.owns(self.microphoneOwner) { self.microphoneTestRequested = false }
                }
            }
        settingsObservation = NotificationCenter.default.publisher(for: RecordingSettings.didChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.visibility.allowsPreview else { return }
                    self.acceptSettings(RecordingSettings.load(from: self.defaults))
                }
            }
    }

    var canStart: Bool {
        selectedSource != nil && !controller.isBusy && visibility.allowsPreview
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
        if !new.allowsPreview {
            retireVisibleResources()
        } else {
            settings = RecordingSettings.load(from: defaults)
            Task { [weak self] in await self?.reconcilePreview() }
        }
    }

    func refreshSources() async {
        guard visibility.allowsPreview, !isRefreshingSources else { return }
        let now = operations.uptime()
        guard now - lastSourceRefresh >= 1 else { return }
        guard operations.screenCaptureAuthorized() else {
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
            if let selectedSource, case .region = selectedSource.id {} else if let selectedSource {
                self.selectedSource = sources.first { $0.id == selectedSource.id }
                if self.selectedSource == nil { resetPreview(); issue = .sourceUnavailable; previewState = .unavailable }
                else if self.selectedSource != selectedSource, !controller.isBusy {
                    resetPreview()
                    Task { [weak self] in await self?.reconcilePreview() }
                }
            }
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
        selectedSource = source
        issue = nil
        resetPreview()
        Task { [weak self] in await self?.reconcilePreview() }
    }

    func selectRegion(_ cgRect: CGRect, displayID: CGDirectDisplayID) async {
        guard !controller.isBusy, cgRect.origin.x.isFinite, cgRect.origin.y.isFinite,
              cgRect.width.isFinite, cgRect.height.isFinite, cgRect.width > 1, cgRect.height > 1 else { return }
        let token = sourceGeneration
        do {
            let content = try await operations.content(true)
            guard !Task.isCancelled, sourceGeneration == token, !controller.isBusy,
                  let display = content.displays.first(where: { $0.displayID == displayID }),
                  let clamp = RegionClamp.clamp(region: cgRect, displays: [.init(frame: display.frame,
                                                                               scale: StudioSourceResolver.scale(display))]),
                  clamp.pixelWidth >= 2, clamp.pixelHeight >= 2 else { issue = .sourceUnavailable; return }
            let target = RecordingEngine.Target.region(clamp, display, excluding: nil)
            selectSource(StudioSourceChoice(id: .region(displayID), title: String(localized: "Region", comment: "Studio selected source"),
                                           frame: clamp.clampedRegion,
                                           pixelSize: StudioSourceResolver.pixelSize(of: target, settings: settings)))
        } catch { if sourceGeneration == token { issue = .sourceUnavailable } }
    }

    func clearSource() {
        guard !controller.isBusy else { return }
        sourceGeneration = UUID()
        selectedSource = nil
        resetPreview()
        previewState = visibility.allowsPreview ? .noSource : .inactive
    }

    func updateSettings(_ change: (inout RecordingSettings) -> Void) {
        var current = RecordingSettings.load(from: defaults)
        change(&current)
        current.camera = current.camera.resolved()
        current.save(to: defaults)
        acceptSettings(current)
    }

    private func acceptSettings(_ current: RecordingSettings) {
        let before = settings
        guard current != before else { return }
        settings = current
        if microphoneMonitor.owns(microphoneOwner) {
            microphoneMonitor.updateGain(current.microphoneGainDB, owner: microphoneOwner)
        }
        if before.microphoneDeviceID != current.microphoneDeviceID, microphoneTestRequested {
            let owner = microphoneOwner, token = microphoneIntentGeneration
            Task { [weak self] in
                guard let self, self.microphoneOwner == owner, self.microphoneIntentGeneration == token,
                      self.microphoneMonitor.owns(owner), self.microphoneTestRequested,
                      self.visibility.allowsPreview else { return }
                await self.setMicrophoneTestRequested(true)
            }
        }
        if cameraPreviewRequested, before.camera != current.camera {
            let token = cameraIntentGeneration
            Task { [weak self] in
                guard let self, self.cameraIntentGeneration == token, self.cameraPreviewRequested,
                      self.visibility.allowsPreview, self.settings.camera == current.camera else { return }
                await self.cameraMonitor.cameraSettingsChanged(current.camera)
            }
        }
        if before.canvasAspect != current.canvasAspect || before.resolutionScale != current.resolutionScale {
            resetPreview()
            Task { [weak self] in await self?.reconcilePreview() }
        }
        previewCapture?.updateGain(current.resolvedSystemAudioGainDB)
    }

    func setCameraPreviewRequested(_ requested: Bool) async {
        cameraIntentGeneration = UUID()
        let token = cameraIntentGeneration
        guard requested, visibility.allowsPreview, !controller.isBusy else {
            cameraPreviewRequested = false
            cameraMonitor.setVisible(false, owner: cameraOwner)
            await cameraMonitor.stopIfUnobserved()
            return
        }
        cameraPreviewRequested = true
        cameraMonitor.setVisible(true, owner: cameraOwner)
        await cameraMonitor.start(deviceID: settings.camera.deviceID, format: settings.camera.format, requestPermission: true)
        guard cameraIntentGeneration == token, cameraPreviewRequested, visibility.allowsPreview else { return }
        if !cameraMonitor.isRunning { cameraPreviewRequested = false; cameraMonitor.setVisible(false, owner: cameraOwner) }
    }

    func setMicrophoneTestRequested(_ requested: Bool) async {
        microphoneIntentGeneration = UUID()
        let token = microphoneIntentGeneration
        let owner = microphoneOwner
        guard requested, visibility.allowsPreview, !controller.isBusy else {
            microphoneTestRequested = false
            await microphoneMonitor.release(owner: owner)
            return
        }
        microphoneTestRequested = true
        await microphoneMonitor.start(owner: owner, deviceID: settings.microphoneDeviceID, gainDB: settings.microphoneGainDB)
        guard microphoneIntentGeneration == token, microphoneOwner == owner, visibility.allowsPreview else { return }
        microphoneTestRequested = microphoneMonitor.owns(owner) && (microphoneMonitor.isRunning || microphoneMonitor.isStarting)
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
        sourceGeneration = UUID()
        isRefreshingSources = false
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
            let capturesAudio = systemAudioTestRequested
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
                    if self.systemAudioTestRequested {
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
