import Foundation
import Testing

@testable import Camcord

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
