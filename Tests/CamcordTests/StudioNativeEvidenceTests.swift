import AppKit
import AVFoundation
import CoreMedia
import Darwin
import QuartzCore
@preconcurrency import ScreenCaptureKit
import SwiftUI
import Synchronization
import Testing
@testable import Camcord

/// Opt-in production preview/recording evidence. The external driver captures only
/// the published exact owned window IDs; this fixture never captures a display.
@MainActor @Suite("Owned native Studio evidence", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["CAMCORD_STUDIO_NATIVE_EVIDENCE"] == "1"))
struct StudioNativeEvidenceTests {
    @Test("Owned window preview and ten-second recording")
    func ownedWindowPreviewAndRecording() async throws {
        let fixture = try StudioNativeEvidenceFixture()
        do {
            try await fixture.run()
            await fixture.close()
        } catch {
            fixture.reportFailure(error)
            await fixture.close()
            throw error
        }
    }
}

private enum StudioEvidenceFailure: Error {
    case unsafePath, unsafeEnvironment, invalidHandshake, sourceExcluded, sourceLost
    case forbiddenResource, deadline, recordingFailed, invalidOutput, decoderFailed
}

private struct StudioEvidenceOwnerPolicy: Sendable {
    let allowActiveOwner: Bool
    init(environment: [String: String]) {
        allowActiveOwner = environment["CAMCORD_STUDIO_ALLOW_ACTIVE_OWNER"] == "1"
    }
    func permitsIdle(_ seconds: Double) -> Bool { allowActiveOwner || seconds >= 600 }
    func permitsActivity(idleSeconds: Double, frontmostUnchanged: Bool, cursorUnchanged: Bool) -> Bool {
        permitsIdle(idleSeconds) && (allowActiveOwner || (frontmostUnchanged && cursorUnchanged))
    }
}

@Suite("Native Studio owner activity policy")
struct StudioNativeEvidenceOwnerPolicyTests {
    @Test("Active owner allowance requires the exact opt-in and preserves the strict default")
    func explicitAllowance() {
        for value in [nil, "0", "true"] as [String?] {
            let policy = StudioEvidenceOwnerPolicy(environment: value.map { ["CAMCORD_STUDIO_ALLOW_ACTIVE_OWNER": $0] } ?? [:])
            #expect(!policy.allowActiveOwner)
            #expect(!policy.permitsActivity(idleSeconds: 599, frontmostUnchanged: true, cursorUnchanged: true))
            #expect(!policy.permitsActivity(idleSeconds: 600, frontmostUnchanged: false, cursorUnchanged: true))
            #expect(!policy.permitsActivity(idleSeconds: 600, frontmostUnchanged: true, cursorUnchanged: false))
            #expect(policy.permitsActivity(idleSeconds: 600, frontmostUnchanged: true, cursorUnchanged: true))
        }
        let authorized = StudioEvidenceOwnerPolicy(environment: ["CAMCORD_STUDIO_ALLOW_ACTIVE_OWNER": "1"])
        #expect(authorized.allowActiveOwner)
        #expect(authorized.permitsActivity(idleSeconds: 0, frontmostUnchanged: false, cursorUnchanged: false))
    }
}

private final class StudioEvidenceDiagnostics: Sendable {
    private let lines = Mutex<[String]>([])
    func append(_ line: String) { lines.withLock { $0.append(line) } }
    func snapshot() -> [String] { lines.withLock { $0 } }
}

@MainActor private final class StudioNativeEvidenceFixture {
    private let output: URL
    private let commandURL: URL
    private let sentinel: URL
    private let ownerPolicy: StudioEvidenceOwnerPolicy
    private let nonce = UUID().uuidString
    private let baselineFrontmost: pid_t
    private let baselineCursor: CGPoint
    private let defaults: UserDefaults
    private let defaultsName: String
    private let diagnostics = StudioEvidenceDiagnostics()
    private let sourceWindow: NSWindow
    private let sourceWindowID: Int
    private let studioWindow: NSWindow
    private let studioWindowID: Int
    private let source: StudioEvidenceSourceView
    private let controller: RecordingController
    private let state = RecordingStateModel()
    private let session: StudioSession
    private var phase = "waiting"
    private var lastCommandID: String?
    private var closed = false
    private var chronology: [[String: Any]] = []
    private var cpuSamples: [[String: Any]] = []
    private var lastCPU: (wall: Double, cpu: Double)?
    private var acceptedSourceBundle: String?
    private var fileFacts: StudioEvidenceFileFacts?
    private var finishedURL: URL?
    private var startOperation: Task<Void, Never>?

    init() throws {
        let env = ProcessInfo.processInfo.environment
        ownerPolicy = StudioEvidenceOwnerPolicy(environment: env)
        guard let sentinelPath = env["CAMCORD_STUDIO_GUI_SENTINEL"], sentinelPath.hasPrefix("/"),
              let outputPath = env["CAMCORD_STUDIO_OUTPUT"], outputPath.hasPrefix("/"),
              let commandPath = env["CAMCORD_STUDIO_PHASE_COMMAND"], commandPath.hasPrefix("/") else {
            throw StudioEvidenceFailure.unsafePath
        }
        sentinel = URL(fileURLWithPath: sentinelPath)
        output = URL(fileURLWithPath: outputPath, isDirectory: true)
        commandURL = URL(fileURLWithPath: commandPath)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let properties = try output.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true,
              output.path == LibraryFiles.physicalPath(output), output.path != repo.path,
              !output.path.hasPrefix(repo.path + "/"), commandURL.deletingLastPathComponent().path == output.path,
              try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty else {
            throw StudioEvidenceFailure.unsafePath
        }
        try Self.preflight(sentinel: sentinel, ownerPolicy: ownerPolicy)
        baselineFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        baselineCursor = CGEvent(source: nil)?.location ?? .zero
        _ = NSApplication.shared
        guard !NSApp.isActive else { throw StudioEvidenceFailure.unsafeEnvironment }
        defaultsName = "Camcord.StudioEvidence.\(UUID().uuidString)"
        guard let isolated = UserDefaults(suiteName: defaultsName) else { throw StudioEvidenceFailure.unsafeEnvironment }
        defaults = isolated
        var settings = RecordingSettings()
        settings.systemAudio = false; settings.microphone = false; settings.camera.enabled = false
        settings.dndEnabled = false; settings.countdownEnabled = false; settings.windowGlowEnabled = false
        settings.maxDurationMinutes = 0; settings.stopWhenDiskLow = false
        settings.fps = 60; settings.canvasAspect = .matchWindow
        settings.outputDirectoryPath = output.path
        settings.save(to: isolated)
        isolated.set(false, forKey: FeedbackSound.enabledDefaultsKey)
        isolated.set(0, forKey: StudioSession.countdownKey)
        var captureOperations = CaptureCoordinator.Operations()
        captureOperations.feedback = false
        let coordinator = CaptureCoordinator(operations: captureOperations)
        let log = diagnostics
        let engine = RecordingEngine(diagnostics: { log.append($0) })
        controller = RecordingController(coordinator: coordinator, defaults: isolated, engine: engine)
        let screen = try #require(NSScreen.screens.first)
        let area = screen.visibleFrame
        sourceWindow = NSWindow(contentRect: CGRect(x: area.minX + 24, y: area.minY + 24, width: 640, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        sourceWindowID = sourceWindow.windowNumber
        sourceWindow.title = "Camcord owned animated source"
        sourceWindow.isReleasedWhenClosed = false; sourceWindow.hidesOnDeactivate = false
        source = StudioEvidenceSourceView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        sourceWindow.contentView = source
        studioWindow = NSWindow(contentRect: CGRect(x: area.midX - 480, y: area.midY - 300, width: 960, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        studioWindowID = studioWindow.windowNumber
        studioWindow.title = "Camcord owned native Studio preview"
        studioWindow.isReleasedWhenClosed = false; studioWindow.hidesOnDeactivate = false
        studioWindow.appearance = NSAppearance(named: .darkAqua)
        let exactSourceID = CGWindowID(sourceWindowID)
        let exactPID = ProcessInfo.processInfo.processIdentifier
        let guardSentinel = sentinel
        let guardOwnerPolicy = ownerPolicy
        let microphone = MicrophoneMonitor(operations: .init(authorize: { false }))
        let camera = CameraPreviewMonitor(operations: .init(authorize: { _ in false }, start: { _, _, _ in
            throw StudioEvidenceFailure.forbiddenResource
        }))
        session = StudioSession(defaults: isolated, controller: controller, recordingState: state, coordinator: coordinator,
            microphoneMonitor: microphone, cameraMonitor: camera,
            operations: .init(screenCaptureAuthorized: { CGPreflightScreenCaptureAccess() }, content: { _ in
                try Self.preflight(sentinel: guardSentinel, ownerPolicy: guardOwnerPolicy)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                try Self.preflight(sentinel: guardSentinel, ownerPolicy: guardOwnerPolicy)
                guard content.windows.contains(where: { $0.windowID == exactSourceID && $0.owningApplication?.processID == exactPID }) else {
                    throw StudioEvidenceFailure.sourceLost
                }
                return content
            }, cameraAuthorized: { false }))
        let host = NSHostingController(rootView: StudioStageView(session: session, canEdit: false)
            .padding(16).background(Theme.Palette.well.color))
        host.sizingOptions = []
        studioWindow.contentViewController = host
        studioWindow.setContentSize(CGSize(width: 960, height: 600))
        wireCallbacks()
        sourceWindow.orderBack(nil); studioWindow.orderBack(nil)
        sourceWindow.contentView?.layoutSubtreeIfNeeded(); sourceWindow.displayIfNeeded()
        studioWindow.contentView?.layoutSubtreeIfNeeded(); studioWindow.displayIfNeeded()
        source.start()
        try checkEnvironment()
        note("windows-ready; capture not started")
        try publish()
    }

    private static func preflight(sentinel: URL, ownerPolicy: StudioEvidenceOwnerPolicy) throws {
        let facts = try sentinel.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard facts.isRegularFile == true, facts.isSymbolicLink != true,
              CGPreflightScreenCaptureAccess(), ownerPolicy.permitsIdle(idleSeconds), !Task.isCancelled else {
            throw StudioEvidenceFailure.unsafeEnvironment
        }
    }

    private static var idleSeconds: Double {
        guard let anyInput = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private func checkEnvironment() throws {
        try Self.preflight(sentinel: sentinel, ownerPolicy: ownerPolicy)
        guard output.path == LibraryFiles.physicalPath(output),
              !NSApp.isActive, !sourceWindow.isKeyWindow, !studioWindow.isKeyWindow,
              ownerPolicy.permitsActivity(idleSeconds: Self.idleSeconds,
                frontmostUnchanged: (NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) == baselineFrontmost,
                cursorUnchanged: CGEvent(source: nil)?.location == baselineCursor),
              sourceWindow.isVisible, studioWindow.isVisible else { throw StudioEvidenceFailure.unsafeEnvironment }
        for window in [sourceWindow, studioWindow] {
            guard let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow, .excludeDesktopElements], CGWindowID(window.windowNumber)) as? [[String: Any]],
                  rows.contains(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber
                    && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier }) else {
                throw StudioEvidenceFailure.sourceLost
            }
        }
    }

    private func wireCallbacks() {
        controller.onUIChange = { [weak self] mode, elapsed in
            guard let self else { return }
            self.state.state = mode; self.state.elapsed = elapsed
            self.note("controller state \(mode); elapsed \(elapsed ?? "nil")")
        }
        controller.onStartingChange = { [weak self] in self?.state.isStarting = $0 }
        controller.onFinishing = { [weak self] in self?.state.isFinishing = $0; self?.note("finishing \($0)") }
        controller.onArmedChange = { [weak self] in self?.state.isArmed = $0 }
        controller.onHealthChange = { [weak self] health in
            guard let self else { return }
            self.state.health = health
            self.note("health", facts: health.map(Self.health) ?? ["available": false])
        }
        controller.onRecordingFinished = { [weak self] url in
            self?.finishedURL = url; self?.state.finishedURL = url; self?.note("finished file", facts: ["path": url.path])
        }
        controller.onFailure = { [weak self] in self?.note("controller failure") }
        controller.onToast = { [weak self] request in self?.note("toast suppressed", facts: ["text": request.text]) }
    }

    func run() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while phase != "finished", ContinuousClock.now < deadline {
            try checkEnvironment()
            sampleCPU()
            if FileManager.default.fileExists(atPath: commandURL.path) {
                let attributes = try commandURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                      (attributes.fileSize ?? 0) <= 16_384 else { throw StudioEvidenceFailure.invalidHandshake }
                let command = try JSONDecoder().decode(StudioEvidenceCommand.self, from: Data(contentsOf: commandURL))
                if command.commandID != lastCommandID {
                    guard UUID(uuidString: command.commandID) != nil, command.fixtureID == nonce, command.pid == ProcessInfo.processInfo.processIdentifier,
                          command.sourceWindowID == sourceWindowID,
                          command.studioWindowID == studioWindowID else { throw StudioEvidenceFailure.invalidHandshake }
                    lastCommandID = command.commandID
                    note("driver command \(command.phase)")
                    switch command.phase {
                    case "idle" where phase == "waiting": try await startIdle()
                    case "record10" where phase == "idle": try await recordTenSeconds()
                    case "finish" where phase == "recorded": phase = "finished"
                    default: throw StudioEvidenceFailure.invalidHandshake
                    }
                }
            }
            try publish()
            try await Task.sleep(for: .milliseconds(100))
        }
        guard phase == "finished" else { throw StudioEvidenceFailure.deadline }
        note("driver finished")
        try publish()
    }

    private func startIdle() async throws {
        try checkEnvironment()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try checkEnvironment()
        guard let window = content.windows.first(where: { $0.windowID == CGWindowID(sourceWindowID)
            && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }) else { throw StudioEvidenceFailure.sourceLost }
        acceptedSourceBundle = window.owningApplication?.bundleIdentifier
        note("original source identity", facts: ["helperBundle": Bundle.main.bundleIdentifier.map { $0 as Any } ?? NSNull(),
            "sourceBundle": acceptedSourceBundle.map { $0 as Any } ?? NSNull()])
        let target = RecordingEngine.Target.window(window)
        let choice = StudioSourceChoice(id: .window(window.windowID), title: sourceWindow.title, frame: window.frame,
            pixelSize: StudioSourceResolver.pixelSize(of: target, settings: session.settings))
        do {
            guard case .window(let resolved) = try StudioSourceResolver.resolve(choice, in: content, settings: session.settings),
                  resolved.windowID == window.windowID else { throw StudioEvidenceFailure.sourceExcluded }
        } catch {
            note("source resolver rejected original identity; no fallback")
            throw StudioEvidenceFailure.sourceExcluded
        }
        session.selectSource(choice) // Before visibility: no default-source refresh, no thumbnail capture.
        session.setVisibility(moduleVisible: true, windowAllowsPreview: true, captureTransition: false)
        try await guardedWait(seconds: 8) { self.session.previewHasFrame || self.session.issue != nil }
        guard session.previewHasFrame, session.issue == nil else { throw StudioEvidenceFailure.recordingFailed }
        phase = "idle"; note("idle first frame")
    }

    private func recordTenSeconds() async throws {
        try checkEnvironment()
        guard session.selectedSource?.id == .window(CGWindowID(sourceWindowID)) else { throw StudioEvidenceFailure.sourceLost }
        phase = "starting"; try publish()
        startOperation = Task { await session.startRecording() }
        try await guardedWait(seconds: 12) { self.state.state == .recording || self.session.issue != nil }
        await startOperation?.value; startOperation = nil
        guard state.state == .recording, session.issue == nil else { throw StudioEvidenceFailure.recordingFailed }
        phase = "recording"; note("ten-second interval begins")
        let boundary = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < boundary {
            try checkEnvironment()
            guard state.state == .recording else { throw StudioEvidenceFailure.recordingFailed }
            sampleCPU(); try publish()
            try await Task.sleep(for: .milliseconds(100))
        }
        note("Stop command boundary")
        await session.stopRecording()
        note("Stop finalized")
        let url = try #require(finishedURL)
        guard url.deletingLastPathComponent().path == output.path, url.path == LibraryFiles.physicalPath(url) else {
            throw StudioEvidenceFailure.invalidOutput
        }
        let sealed = try #require(controller.finalRecordingHealth)
        note("sealed final health", facts: Self.finalHealth(sealed))
        fileFacts = try await Self.decode(url: url)
        phase = "recorded"
        try publish()
        #expect(sealed.health.compositorPoolExhaustions == 0)
        #expect(sealed.health.video.dropped == 0)
        #expect(sealed.health.systemAudio.enabled == false && sealed.health.microphone.enabled == false)
        #expect(sealed.nominalFPS == 60)
        #expect(fileFacts?.effectiveFPS ?? 0 >= 55)
        #expect(fileFacts?.nonMonotonicPTS == 0)
        #expect(fileFacts?.timestampGaps == 0)
        #expect(fileFacts?.duration ?? 0 >= 9.5)
    }

    private func guardedWait(seconds: Double, until done: () -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !done(), ContinuousClock.now < limit {
            try checkEnvironment(); sampleCPU(); try publish()
            try await Task.sleep(for: .milliseconds(100))
        }
        try checkEnvironment()
        guard done() else { throw StudioEvidenceFailure.deadline }
    }

    private func note(_ event: String, facts: [String: Any] = [:]) {
        chronology.append(facts.merging(activityFacts) { _, current in current }.merging(["event": event, "phase": phase, "hostClockSeconds": CMClockGetTime(CMClockGetHostTimeClock()).seconds,
            "uptime": ProcessInfo.processInfo.systemUptime]) { _, new in new })
    }

    private var activityFacts: [String: Any] {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let cursor = CGEvent(source: nil)?.location
        return ["allowActiveOwner": ownerPolicy.allowActiveOwner,
            "ownerActivityMode": ownerPolicy.allowActiveOwner ? "authorized-active-owner" : "strict-idle",
            "idleSeconds": Self.idleSeconds, "frontmostPID": frontmost,
            "cursor": cursor.map { [$0.x, $0.y] as Any } ?? NSNull(),
            "frontmostUnchanged": frontmost == baselineFrontmost,
            "cursorUnchanged": cursor == baselineCursor]
    }

    private func sampleCPU() {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return }
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let wall = ProcessInfo.processInfo.systemUptime
        if let lastCPU, wall - lastCPU.wall >= 0.25 {
            cpuSamples.append(["uptime": wall, "phase": phase, "cpuPercent": 100 * (cpu - lastCPU.cpu) / (wall - lastCPU.wall),
                "scope": "whole helper including animated source, native preview and writer"])
            self.lastCPU = (wall, cpu)
        } else if lastCPU == nil { lastCPU = (wall, cpu) }
    }

    private func publish() throws {
        let native = Self.nativeHost(in: studioWindow.contentView)
        let stage = native.map { $0.convert($0.bounds, to: nil) } ?? .zero
        let data: [String: Any] = ["fixtureID": nonce, "phase": phase, "pid": ProcessInfo.processInfo.processIdentifier,
            "executablePath": Bundle.main.executableURL?.path ?? "", "bundleIdentifier": Bundle.main.bundleIdentifier.map { $0 as Any } ?? NSNull(),
            "sourceWindowID": sourceWindowID, "studioWindowID": studioWindowID,
            "sourceFrame": Self.rect(sourceWindow.frame), "studioFrame": Self.rect(studioWindow.frame),
            "sourceContentFrameInWindow": Self.rect(source.convert(source.bounds, to: nil)),
            "stageFrameInWindow": Self.rect(stage), "stageFrameCoordinates": "AppKit points, bottom-left window origin",
            "sourceMarkerRect": Self.rect(source.markerRect), "sourceMarkerCoordinates": "source content points, top-left origin",
            "sourceMarkerBits": 16, "sourceMarkerEncoding": "white=1/black=0, little-endian sequence, red/blue guard stripe",
            "sourceDisplayTicks": source.ticks, "sourcePaints": source.paints,
            "screenMaximumFramesPerSecond": studioWindow.screen?.maximumFramesPerSecond ?? 0,
            "backingScale": studioWindow.backingScaleFactor,
            "previewHasFrame": session.previewHasFrame, "previewState": String(describing: session.previewState),
            "selectedSource": String(describing: session.selectedSource?.id), "nativeHostPresent": native != nil,
            "capturePreflight": CGPreflightScreenCaptureAccess(), "appActive": NSApp.isActive,
            "sourceKey": sourceWindow.isKeyWindow, "studioKey": studioWindow.isKeyWindow,
            "recordingFile": finishedURL.map { $0.path as Any } ?? NSNull(),
            "acceptedSourceBundle": acceptedSourceBundle.map { $0 as Any } ?? NSNull(),
            "finalRecordingHealth": controller.finalRecordingHealth.map(Self.finalHealth) ?? ["available": false],
            "actualVisualFPS": "UNMEASURED: external exact-owned-window video decoder required",
            "fileFacts": try fileFacts.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()]
        try Self.writeJSON(data.merging(activityFacts) { _, current in current }, to: output.appendingPathComponent("ready.json"))
        try Self.writeJSON(chronology, to: output.appendingPathComponent("chronology.json"))
        try Self.writeJSON(cpuSamples, to: output.appendingPathComponent("cpu.json"))
        try Self.writeJSON(diagnostics.snapshot(), to: output.appendingPathComponent("diagnostics.json"))
    }

    func reportFailure(_ error: Error) {
        phase = "failed"; note("failure", facts: ["error": String(describing: error)])
        try? publish()
    }

    func close() async {
        guard !closed else { return }; closed = true
        startOperation?.cancel(); await startOperation?.value; startOperation = nil
        if controller.isBusy { await controller.stopRecording() }
        await session.releaseVisibleResources()
        source.stop()
        studioWindow.orderOut(nil); sourceWindow.orderOut(nil)
        studioWindow.close(); sourceWindow.close()
        defaults.removePersistentDomain(forName: defaultsName)
        note("owned resources closed")
        try? publish()
    }

    private static func nativeHost(in view: NSView?) -> StudioNativePreviewHost? {
        guard let view else { return nil }
        return (view as? StudioNativePreviewHost) ?? view.subviews.lazy.compactMap { nativeHost(in: $0) }.first
    }
    private static func rect(_ rect: CGRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }
    private static func health(_ health: RecordingHealth) -> [String: Any] {
        ["available": true, "videoDelivered": health.video.delivered, "videoAppended": health.video.appended,
         "videoDropped": health.video.dropped, "compositorPoolExhaustions": health.compositorPoolExhaustions,
         "systemAudioEnabled": health.systemAudio.enabled, "microphoneEnabled": health.microphone.enabled]
    }
    private static func finalHealth(_ value: RecordingFinalHealth) -> [String: Any] {
        health(value.health).merging(["epoch": value.epoch.uuidString, "nominalFPS": value.nominalFPS.map { $0 as Any } ?? NSNull(),
            "coverage": "writer sealed on serial sample queue; configured nominal FPS is not measured display FPS"]) { _, new in new }
    }
    private static func writeJSON(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    nonisolated private static func decode(url: URL) async throws -> StudioEvidenceFileFacts {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw StudioEvidenceFailure.decoderFailed }
        let duration = try await asset.load(.duration).seconds
        let natural = try await track.load(.naturalSize)
        let nominal = Double(try await track.load(.nominalFrameRate))
        let reader = try AVAssetReader(asset: asset)
        let video = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(video)
        guard reader.startReading() else { throw StudioEvidenceFailure.decoderFailed }
        var timestamps: [Double] = []
        while let sample = video.copyNextSampleBuffer() {
            guard !Task.isCancelled else { reader.cancelReading(); throw CancellationError() }
            guard CMSampleBufferGetImageBuffer(sample) != nil else { throw StudioEvidenceFailure.decoderFailed }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time.isFinite else { throw StudioEvidenceFailure.decoderFailed }
            timestamps.append(time)
        }
        guard reader.status == .completed, !timestamps.isEmpty, duration.isFinite, duration > 0 else { throw StudioEvidenceFailure.decoderFailed }
        let intervals = zip(timestamps.dropFirst(), timestamps).map { $0.0 - $0.1 }
        return StudioEvidenceFileFacts(path: url.path, duration: duration, width: Int(natural.width), height: Int(natural.height),
            frames: timestamps.count, nominalFPS: nominal, effectiveFPS: Double(timestamps.count) / duration,
            nonMonotonicPTS: intervals.filter { $0 <= 0 }.count,
            timestampGaps: intervals.filter { $0 > 1.5 / 60 }.count, maximumInterval: intervals.max() ?? 0, allPTS: timestamps)
    }
}

private struct StudioEvidenceCommand: Decodable {
    let commandID: String
    let fixtureID: String
    let pid: Int32
    let sourceWindowID: Int
    let studioWindowID: Int
    let phase: String
}

private struct StudioEvidenceFileFacts: Codable, Sendable {
    let path: String
    let duration: Double
    let width: Int
    let height: Int
    let frames: Int
    let nominalFPS: Double
    let effectiveFPS: Double
    let nonMonotonicPTS: Int
    let timestampGaps: Int
    let maximumInterval: Double
    let allPTS: [Double]
}

@MainActor private final class StudioEvidenceSourceView: NSView {
    private var link: CADisplayLink?
    private(set) var ticks = 0
    private(set) var paints = 0
    let markerRect = CGRect(x: 24, y: 24, width: 256, height: 32)
    override var isFlipped: Bool { true }
    func start() {
        let fps = Float(window?.screen?.maximumFramesPerSecond ?? 60)
        let display = displayLink(target: self, selector: #selector(tick(_:)))
        display.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        display.add(to: .main, forMode: .common); link = display
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick(_ display: CADisplayLink) { ticks += 1; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        paints += 1
        let hue = CGFloat(ticks % 240) / 240
        NSGradient(starting: NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1),
            ending: NSColor(hue: (hue + 0.4).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.7, alpha: 1))?
            .draw(in: bounds, angle: 35)
        for bit in 0..<16 {
            (ticks & (1 << bit) == 0 ? NSColor.black : NSColor.white).setFill()
            CGRect(x: markerRect.minX + CGFloat(bit) * 16, y: markerRect.minY, width: 16, height: 32).fill()
        }
        NSColor.systemRed.setFill(); CGRect(x: 24, y: 60, width: 128, height: 8).fill()
        NSColor.systemBlue.setFill(); CGRect(x: 152, y: 60, width: 128, height: 8).fill()
        let text = "\(ticks) · \(String(format: "%.6f", CMClockGetTime(CMClockGetHostTimeClock()).seconds))"
        text.draw(at: CGPoint(x: 24, y: 80), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .bold), .foregroundColor: NSColor.white])
    }
}
