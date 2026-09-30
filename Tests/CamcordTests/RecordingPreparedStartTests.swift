import Foundation
import CoreGraphics
import Testing
@testable import Camcord

@MainActor @Suite("Prepared Studio recording start guards")
struct RecordingPreparedStartTests {
    @Test("cancelling a body keeps the starting lock until noncooperative handoff cleanup drains")
    func cancelledBodyDrain() async throws {
        let controller = RecordingController(coordinator: CaptureCoordinator(), defaults: try isolatedDefaults(),
                                             preparedStartOperations: .init(screenCaptureAuthorized: { true }))
        var pending: CheckedContinuation<Bool, Never>?
        var calls = 0
        let first = Task { await controller.performPreparedStart(countdownSeconds: 0, screenFrame: .zero) {
            await withCheckedContinuation { pending = $0 }
        } }
        try await wait { pending != nil }
        first.cancel()
        await Task.yield()
        let replacement = await controller.performPreparedStart(countdownSeconds: 0, screenFrame: .zero) { calls += 1; return true }
        #expect(!replacement && controller.isBusy && calls == 0)
        pending?.resume(returning: true)
        let accepted = await first.value
        #expect(!accepted && !controller.isBusy)
        #expect(await controller.performPreparedStart(countdownSeconds: 0, screenFrame: .zero) { calls += 1; return true })
        #expect(calls == 1)
    }
    @Test("an authoritative capture accepted during countdown blocks the prepared operation until it drains")
    func captureDuringCountdown() async throws {
        var countdown: CheckedContinuation<Bool, Never>?
        var capture: CheckedContinuation<(image: CGImage, pointSize: CGSize), Error>?
        var operations = CaptureCoordinator.Operations()
        operations.feedback = false
        operations.screenshotSettings = { ScreenshotSettings() }
        operations.screenCaptureAuthorized = { true }
        operations.fullScreen = { try await withCheckedThrowingContinuation { capture = $0 } }
        let coordinator = CaptureCoordinator(operations: operations)
        let controller = RecordingController(coordinator: coordinator, defaults: try isolatedDefaults(),
            preparedStartOperations: .init(screenCaptureAuthorized: { true }, countdown: { _, _ in
                await withCheckedContinuation { countdown = $0 }
            }))
        var calls = 0
        let start = Task { await controller.performPreparedStart(countdownSeconds: 3, screenFrame: .zero) { calls += 1; return true } }
        try await wait { countdown != nil }
        let shot = Task { await coordinator.captureFullScreen() }
        try await wait { capture != nil }
        #expect(coordinator.captureTransition.isActive)
        countdown?.resume(returning: true)
        let accepted = await start.value
        #expect(!accepted && calls == 0)
        capture?.resume(throwing: CancellationError())
        await shot.value
        #expect(!coordinator.captureTransition.isActive)
        #expect(await controller.performPreparedStart(countdownSeconds: 0, screenFrame: .zero) { calls += 1; return true })
        #expect(calls == 1)
    }
    @Test("the actual transaction runs exactly once for every supported countdown", arguments: [0, 3, 5, 10])
    func acceptedTransaction(seconds: Int) async throws {
        let defaults = try isolatedDefaults()
        var countdowns: [Int] = [], calls = 0
        let controller = RecordingController(coordinator: CaptureCoordinator(), defaults: defaults,
            preparedStartOperations: .init(screenCaptureAuthorized: { true }, countdown: { _, value in
                countdowns.append(value)
                return true
            }))
        let accepted = await controller.performPreparedStart(countdownSeconds: seconds, screenFrame: .zero) {
            #expect(controller.isBusy)
            calls += 1
            return true
        }
        #expect(accepted)
        #expect(calls == 1 && countdowns == (seconds == 0 ? [] : [seconds]))
        #expect(!controller.isBusy)
    }

    @Test("a second start cannot enter while the real starting lock is held")
    func concurrentTransaction() async throws {
        var pending: CheckedContinuation<Bool, Never>?
        let controller = RecordingController(coordinator: CaptureCoordinator(), defaults: try isolatedDefaults(),
            preparedStartOperations: .init(screenCaptureAuthorized: { true }, countdown: { _, _ in
                await withCheckedContinuation { pending = $0 }
            }))
        var calls = 0
        let first = Task { await controller.performPreparedStart(countdownSeconds: 3, screenFrame: .zero) { calls += 1; return true } }
        try await wait { pending != nil }
        let accepted = await controller.performPreparedStart(countdownSeconds: 0, screenFrame: .zero) { calls += 1; return true }
        #expect(!accepted)
        pending?.resume(returning: true)
        #expect(await first.value && calls == 1 && !controller.isBusy)
    }

    @Test("cancelled late countdown cannot clear a replacement start")
    func cancelledCountdownGeneration() async throws {
        var pending: [CheckedContinuation<Bool, Never>] = []
        let controller = RecordingController(coordinator: CaptureCoordinator(), defaults: try isolatedDefaults(),
            preparedStartOperations: .init(screenCaptureAuthorized: { true }, countdown: { _, _ in
                await withCheckedContinuation { pending.append($0) }
            }))
        var calls = 0
        let first = Task { await controller.performPreparedStart(countdownSeconds: 3, screenFrame: .zero) { calls += 1; return true } }
        try await wait { pending.count == 1 }
        first.cancel()
        try await wait { !controller.isBusy }
        let second = Task { await controller.performPreparedStart(countdownSeconds: 5, screenFrame: .zero) { calls += 1; return true } }
        try await wait { pending.count == 2 }
        pending[0].resume(returning: true)
        let firstAccepted = await first.value
        #expect(!firstAccepted && controller.isBusy && calls == 0)
        pending[1].resume(returning: true)
        #expect(await second.value && calls == 1 && !controller.isBusy)
    }

    @Test("new invalid layer revision blocks a suspended start and every legacy entry")
    func authoritativeLayerGate() async throws {
        var pending: CheckedContinuation<Bool, Never>?
        let controller = RecordingController(coordinator: CaptureCoordinator(), defaults: try isolatedDefaults(),
            preparedStartOperations: .init(screenCaptureAuthorized: { true }, countdown: { _, _ in
                await withCheckedContinuation { pending = $0 }
            }))
        var calls = 0, issues = 0
        controller.onToast = { _ in issues += 1 }
        let first = Task { await controller.performPreparedStart(countdownSeconds: 3, screenFrame: .zero) { calls += 1; return true } }
        try await wait { pending != nil }
        controller.updateStudioLayerReadiness(false)
        pending?.resume(returning: true)
        let accepted = await first.value
        #expect(!accepted && calls == 0 && issues == 1)
        await controller.toggleRecording()
        await controller.recordWindow()
        await controller.recordFullScreen()
        #expect(!controller.isBusy && calls == 0 && issues == 4)
        controller.updateStudioLayerReadiness(true)
        #expect(await controller.performPreparedStart(countdownSeconds: 0, screenFrame: .zero) { calls += 1; return true })
        #expect(calls == 1)
    }

    @Test("termination after countdown acceptance rejects the final operation")
    func terminationDuringCountdown() async throws {
        var pending: CheckedContinuation<Bool, Never>?
        let controller = RecordingController(coordinator: CaptureCoordinator(), defaults: try isolatedDefaults(),
            preparedStartOperations: .init(screenCaptureAuthorized: { true }, countdown: { _, _ in
                await withCheckedContinuation { pending = $0 }
            }))
        var calls = 0
        let task = Task { await controller.performPreparedStart(countdownSeconds: 3, screenFrame: .zero) { calls += 1; return true } }
        try await wait { pending != nil }
        await controller.stopForTermination()
        pending?.resume(returning: true)
        let accepted = await task.value
        #expect(!accepted && calls == 0 && !controller.isBusy)
    }

    @Test("only supported Studio countdown choices accept an idle start", arguments: [-1, 0, 1, 3, 5, 10, 11])
    func countdownChoices(seconds: Int) {
        #expect(RecordingController.acceptsPreparedStart(state: .idle, armed: false, starting: false,
                                                          finalizing: false, terminating: false,
                                                          captureTransition: false, countdownSeconds: seconds)
                == [0, 3, 5, 10].contains(seconds))
    }

    @Test("every authoritative busy boundary rejects another start", arguments: 0..<7)
    func busyBoundaries(index: Int) {
        let state: RecordingController.UIState = index == 0 ? .recording : index == 1 ? .paused : .idle
        #expect(!RecordingController.acceptsPreparedStart(state: state, armed: index == 2, starting: index == 3,
                                                           finalizing: index == 4, terminating: index == 5,
                                                           captureTransition: index == 6, countdownSeconds: 3))
    }

    private func isolatedDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "Camcord.PreparedStudio.\(UUID())"))
    }
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
}
