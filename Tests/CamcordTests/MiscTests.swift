import AVFoundation
import Foundation
import os
import Testing

@testable import Camcord

@Test("retry cannot begin after the single wall-clock budget is exhausted")
func retryStaysInsideOneBudget() async {
    let state = OSAllocatedUnfairLock(initialState: (now: UInt64(100), attempts: 0))
    let deadline: UInt64 = 2_000_000_100

    do {
        _ = try await ScreenshotService.withRetry(
            deadlineNanoseconds: deadline,
            nowNanoseconds: { state.withLock { $0.now } }
        ) { () async throws -> Int in
            state.withLock {
                $0.attempts += 1
                $0.now = deadline
            }
            throw CaptureError.noDisplay
        }
        Issue.record("Expected the exhausted retry budget to time out")
    } catch CaptureError.timeout {
        // Expected: the failed attempt consumed the one shared budget.
    } catch {
        Issue.record("Expected CaptureError.timeout, got \(error)")
    }

    #expect(state.withLock { $0.attempts } == 1)
    #expect(state.withLock { $0.now } == deadline)
}

@MainActor
@Test("salvaged recording is delivered once without a failure callback")
func salvageDeliversOnce() {
    let controller = RecordingController(coordinator: CaptureCoordinator())
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("salvage-test.mov")
    var delivered: [URL] = []
    var warnings: [String] = []
    var failures = 0
    controller.onRecordingFinished = { delivered.append($0) }
    controller.onToast = { warnings.append($0.text) }
    controller.onFailure = { failures += 1 }

    controller.handleUnexpectedStop(salvagedURL: url, error: RecordingError.incompleteRecording(url, nil))

    #expect(delivered == [url])
    #expect(warnings == ["Kayıt kesildi · kaydedilen kısım korundu"])
    #expect(failures == 0)
}

@Suite("FormatElapsed")
struct FormatElapsedTests {
    @MainActor
    @Test("boundary values format as M:SS with unbounded minutes")
    func boundaries() {
        #expect(RecordingController.formatElapsed(0) == "0:00")
        #expect(RecordingController.formatElapsed(0.9) == "0:00")
        #expect(RecordingController.formatElapsed(59) == "0:59")
        #expect(RecordingController.formatElapsed(60) == "1:00")
        #expect(RecordingController.formatElapsed(3599) == "59:59")
        #expect(RecordingController.formatElapsed(3600) == "60:00")
        #expect(RecordingController.formatElapsed(3661.4) == "61:01")
    }

    @MainActor
    @Test("microphone silence waits for the post-resume grace period")
    func microphoneResumeGrace() {
        var microphone = AudioSourceHealth(enabled: true)

        #expect(!RecordingController.isMicrophoneMissing(microphone, at: 101, graceUntil: 102))
        #expect(RecordingController.isMicrophoneMissing(microphone, at: 102, graceUntil: 102))

        microphone.lastSampleUptime = 101
        #expect(!RecordingController.isMicrophoneMissing(microphone, at: 102, graceUntil: 102))
    }
}

@Suite("FeedbackSound")
struct FeedbackSoundTests {
    private func makeTestDefaults() -> UserDefaults {
        UserDefaults(suiteName: "dev.tavsan.camcord.tests.feedbacksound.\(UUID().uuidString)")!
    }

    @Test("defaults to enabled when the key is absent; explicit false persists")
    func defaultOnExplicitOff() {
        let defaults = makeTestDefaults()
        #expect(FeedbackSound.isEnabled(in: defaults) == true)
        FeedbackSound.setEnabled(false, in: defaults)
        #expect(FeedbackSound.isEnabled(in: defaults) == false)
        FeedbackSound.setEnabled(true, in: defaults)
        #expect(FeedbackSound.isEnabled(in: defaults) == true)
    }

    @MainActor
    @Test("every action keeps the original macOS cue and decodes its cached AIFF")
    func legacyCueMediaContract() throws {
        let expected: [FeedbackSound: String] = [
            .regionShot: "Pop",
            .windowShot: "Bottle",
            .fullScreenShot: "Funk",
            .textOCR: "Morse",
            .recordStart: "Hero",
            .recordStop: "Glass",
            .recordPause: "Tink",
            .recordResume: "Purr",
            .paste: "Frog",
            .error: "Basso",
        ]
        var payloads = Set<Data>()

        for cue in FeedbackSound.allCases {
            let name = try #require(expected[cue])
            let payload = cue.audioData
            let player = try AVAudioPlayer(data: payload)
            payloads.insert(payload)

            #expect(cue.systemSoundName == name)
            #expect(payload.starts(with: Data("FORM".utf8)))
            let diskPayload = try Data(contentsOf: cue.systemSoundURL)
            #expect(payload == diskPayload)
            #expect(player.duration > 0.5)
            #expect(player.duration < FeedbackSound.maximumAwaitedPlaybackSeconds)
            #expect(cue.audioData == payload)
        }

        #expect(payloads.count == FeedbackSound.allCases.count)
    }
}

@Suite("TapBindingsForwardCompat")
struct TapBindingsForwardCompatTests {
    private func makeTestDefaults() -> UserDefaults {
        UserDefaults(suiteName: "dev.tavsan.camcord.tests.tapbindingscompat.\(UUID().uuidString)")!
    }

    @Test("partial JSON decodes with missing keys as nil (not as the first-run defaults)")
    func partialJSONDecodesMissingAsNil() {
        let defaults = makeTestDefaults()
        defaults.set(Data(#"{"mouseButton5":"toggleRecording"}"#.utf8), forKey: TapBindings.defaultsKey)

        let loaded = TapBindings.load(from: defaults)
        // Documented semantics: persisted-but-partial JSON means the absent fields
        // are OFF (nil) -- the .captureRegion default applies only when nothing was
        // ever persisted.
        #expect(loaded.mouseButton4 == nil)
        #expect(loaded.mouseButton5 == .toggleRecording)
        #expect(loaded.doubleTapRightCommand == nil)
    }

    @Test("an unknown enum raw value collapses to full defaults (documented limitation)")
    func unknownEnumFallsBackToDefaults() {
        let defaults = makeTestDefaults()
        defaults.set(Data(#"{"mouseButton4":"futureAction"}"#.utf8), forKey: TapBindings.defaultsKey)
        #expect(TapBindings.load(from: defaults) == TapBindings())
    }
}

@Suite("Fullscreen context")
struct FullscreenContextTests {
    private func context(front: String?, covers: Bool, layer: Int = 0, captured: Bool = false) -> FullscreenContext {
        FullscreenContext(displayID: 1, frontmostBundleID: front, coversDisplay: covers,
                          windowLayer: layer, displayCaptured: captured)
    }

    @Test("only another app covering the whole display is game-like")
    func decisionTable() {
        let game = "com.riotgames.LeagueofLegends"
        #expect(context(front: game, covers: true, layer: 0).isGameLike)
        #expect(context(front: game, covers: true, layer: 2_147_483_631, captured: true).isGameLike)
        // A window that does not cover the display leaves room for our overlays.
        #expect(!context(front: game, covers: false, layer: 0).isGameLike)
        // Our own full-screen surfaces (the selection overlay itself) are never a game.
        #expect(!context(front: Bundle.main.bundleIdentifier, covers: true).isGameLike)
        // Nothing frontmost (login window / fast user switch) is not a game context.
        #expect(!context(front: nil, covers: true).isGameLike)
    }

    @Test("the log line carries both failure classes")
    func logLineShape() {
        let line = context(front: "com.x.y", covers: true, layer: 25, captured: true).logLine
        #expect(line.contains("covers=true"))
        #expect(line.contains("layer=25"))
        #expect(line.contains("captured=true"))
        #expect(line.contains("game=true"))
    }
}
