import AppKit
import Foundation
import Testing

@testable import Camcord

@MainActor
@Suite("Engine ownership regressions")
struct EngineOwnershipTests {
    @MainActor private final class CameraCheckpoint {
        var starts = 0
        var stopContinuation: CheckedContinuation<Void, Never>?
        var pauseStop = false

        var operations: CameraPreviewMonitor.Operations {
            .init(authorize: { _ in true }, start: { [self] _, _, _ in starts += 1 },
                  waitForFirstFrame: { _ in }, stop: { [self] _ in
                      if pauseStop {
                          await withCheckedContinuation { stopContinuation = $0 }
                      }
                  })
        }

        func waitForStop() async throws {
            let deadline = ContinuousClock.now + .seconds(1)
            while stopContinuation == nil, ContinuousClock.now < deadline { await Task.yield() }
            #expect(stopContinuation != nil)
        }

        func releaseStop() {
            pauseStop = false
            stopContinuation?.resume()
            stopContinuation = nil
        }
    }

    @Test("a restart cannot reopen a camera after its final preview owner disappears", arguments: [false, true])
    func cameraRestartRetainsOnlyVisibleOwnership(secondOwner: Bool) async throws {
        let checkpoint = CameraCheckpoint()
        let monitor = CameraPreviewMonitor(operations: checkpoint.operations)
        monitor.setVisible(true, owner: "first")
        if secondOwner { monitor.setVisible(true, owner: "second") }
        await monitor.start(deviceID: "camera-A", format: .auto)
        #expect(checkpoint.starts == 1)
        checkpoint.pauseStop = true
        let restart = Task { await monitor.cameraSettingsChanged(CameraOptions(deviceID: "camera-B")) }
        try await checkpoint.waitForStop()
        monitor.setVisible(false, owner: "first")
        await monitor.stopIfUnobserved()
        checkpoint.releaseStop()
        await restart.value
        #expect(checkpoint.starts == (secondOwner ? 2 : 1))
        #expect(monitor.isRunning == secondOwner)
        monitor.setVisible(false, owner: "second")
        await monitor.stop()
    }

    @Test("recording ownership acquired during preview stop invalidates the pending restart")
    func recordingLocksPendingRestart() async throws {
        let checkpoint = CameraCheckpoint()
        let monitor = CameraPreviewMonitor(operations: checkpoint.operations)
        monitor.setVisible(true, owner: "preview")
        await monitor.start(deviceID: "camera-A", format: .auto)
        checkpoint.pauseStop = true
        let restart = Task { await monitor.cameraSettingsChanged(CameraOptions(deviceID: "camera-B")) }
        try await checkpoint.waitForStop()
        let transferred = await monitor.prepareForRecording(options: CameraOptions(enabled: true, deviceID: "camera-B"))
        #expect(transferred == nil)
        checkpoint.releaseStop()
        await restart.value
        #expect(checkpoint.starts == 1)
        #expect(monitor.recordingLocked)
        monitor.recordingEnded()
    }

    @Test("stale authorization completion cannot clear a newer preview start's ownership")
    func authorizationGenerationDoesNotClobberNewStart() async {
        var authorizations: [CheckedContinuation<Bool, Never>] = []
        var operations = CameraPreviewMonitor.Operations()
        operations.authorize = { _ in await withCheckedContinuation { authorizations.append($0) } }
        operations.start = { _, _, _ in }
        operations.waitForFirstFrame = { _ in }
        operations.stop = { _ in }
        let monitor = CameraPreviewMonitor(operations: operations)
        monitor.setVisible(true, owner: "preview")
        let old = Task { await monitor.start(deviceID: "camera-A", format: .auto) }
        while authorizations.count < 1 { await Task.yield() }
        await monitor.stop()
        let newer = Task { await monitor.start(deviceID: "camera-B", format: .auto) }
        while authorizations.count < 2 { await Task.yield() }
        authorizations[0].resume(returning: true)
        await old.value
        #expect(monitor.isStarting)
        authorizations[1].resume(returning: true)
        await newer.value
        #expect(monitor.isRunning)
        await monitor.stop()
    }

    @Test("same-camera and format handoff keeps the owned source without stopping it")
    func cameraHandoffPreserved() async {
        let checkpoint = CameraCheckpoint()
        let monitor = CameraPreviewMonitor(operations: checkpoint.operations)
        monitor.setVisible(true, owner: "preview")
        await monitor.start(deviceID: "camera-A", format: .auto)
        let capture = await monitor.prepareForRecording(options: CameraOptions(enabled: true, deviceID: "camera-A"))
        #expect(capture != nil)
        #expect(monitor.recordingLocked)
        monitor.useRecordingSource(capture)
        await monitor.stopIfUnobserved()
        #expect(monitor.isRunning)
        monitor.recordingEnded()
    }

    @MainActor private final class GestureFixture {
        var starts = 0
        var finishes = 0
        var accepted = true
        var actions: EventTapEngine.GestureActions {
            .init(begin: { [self] _, _ in starts += 1; return accepted }, update: { _ in },
                  finish: { [self] _ in finishes += 1 }, cancel: {})
        }
    }

    private func tap(_ fixture: GestureFixture, hold: Bool = false,
                     prearmed: Int64? = nil) -> EventTapEngine {
        let coordinator = CaptureCoordinator()
        return EventTapEngine(
            coordinator: coordinator, recordingController: RecordingController(coordinator: coordinator),
            bindings: TapBindings(mouseButton3: nil, mouseButton4: nil,
                                  mouseButton5: hold ? .holdCaptureRegion : .captureModifier),
            buttonIsDown: { $0 == prearmed }, gestures: fixture.actions, monitorsLifecycle: false
        )
    }

    private func send(_ engine: EventTapEngine, _ type: CGEventType, _ button: Int64 = 0) -> Bool {
        engine.handle(type: type, button: button, keycode: 0, isRightCommandDown: false,
                      timestamp: 0, location: CGPoint(x: 100, y: 100))
    }

    @Test("each swallowed chord down owns its drag and release after the capture ends",
          arguments: [false, true])
    func bothChordReleaseOrders(rightFirst: Bool) {
        let fixture = GestureFixture()
        let engine = tap(fixture)
        #expect(send(engine, .otherMouseDown, 4))
        #expect(send(engine, .leftMouseDown))
        #expect(send(engine, .rightMouseDown, 1))
        #expect(send(engine, rightFirst ? .rightMouseUp : .leftMouseUp, rightFirst ? 1 : 0))
        #expect(send(engine, .otherMouseUp, 4))
        #expect(send(engine, rightFirst ? .leftMouseDragged : .rightMouseDragged, rightFirst ? 0 : 1))
        #expect(send(engine, rightFirst ? .leftMouseUp : .rightMouseUp, rightFirst ? 0 : 1))
        #expect(fixture.starts == 1)
        #expect(fixture.finishes == 1)
        #expect(!send(engine, .leftMouseDown))
        #expect(!send(engine, .rightMouseDown, 1))
    }

    @Test("direct holds retain independent left and other-button tails after hold release")
    func directHoldTails() {
        let fixture = GestureFixture()
        let engine = tap(fixture, hold: true)
        #expect(send(engine, .otherMouseDown, 4))
        #expect(send(engine, .leftMouseDown))
        #expect(send(engine, .otherMouseDown, 6))
        #expect(send(engine, .otherMouseUp, 4))
        #expect(send(engine, .leftMouseDragged))
        #expect(send(engine, .otherMouseDragged, 6))
        #expect(send(engine, .otherMouseUp, 6))
        #expect(send(engine, .leftMouseUp))
        #expect(!send(engine, .otherMouseUp, 6))
        #expect(fixture.finishes == 1)
    }

    @Test("rejected chords still consume their owned tails; pre-arm buttons retain pass-through")
    func rejectedAndPrearmed() {
        let fixture = GestureFixture()
        fixture.accepted = false
        let engine = tap(fixture, prearmed: 0)
        #expect(send(engine, .otherMouseDown, 4))
        #expect(!send(engine, .leftMouseDragged))
        #expect(!send(engine, .leftMouseUp))
        #expect(send(engine, .rightMouseDown, 1))
        #expect(send(engine, .otherMouseUp, 4))
        #expect(send(engine, .rightMouseDragged, 1))
        #expect(send(engine, .rightMouseUp, 1))
        #expect(fixture.finishes == 0)
    }

    @Test("legacy binding replacement survives repeated loads and a fresh defaults wrapper")
    func legacyMigrationIsDurable() {
        let storage = MemoryDefaults.Storage()
        let defaults = MemoryDefaults(storage: storage)
        let legacy = TapBindings(mouseButton3: .paste, mouseButton4: .captureRegion,
                                 mouseButton5: .holdCaptureRegion, doubleTapRightCommand: nil)
        legacy.save(to: defaults)
        #expect(TapBindings.load(from: defaults) == TapBindings())
        #expect(TapBindings.load(from: defaults) == TapBindings())
        #expect(TapBindings.load(from: MemoryDefaults(storage: storage)) == TapBindings())
        let custom = TapBindings(mouseButton3: .toggleRecording, mouseButton4: nil, mouseButton5: .paste)
        custom.save(to: defaults)
        #expect(TapBindings.load(from: defaults) == custom)
    }
}

/// Test-instance-confined dictionary; overrides never read or write a preferences domain.
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    final class Storage { var values: [String: Any] = [:] }
    private let storage: Storage
    init(storage: Storage) { self.storage = storage; super.init(suiteName: nil)! }
    override func data(forKey key: String) -> Data? { storage.values[key] as? Data }
    override func bool(forKey key: String) -> Bool { storage.values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { storage.values[key] = value }
}
