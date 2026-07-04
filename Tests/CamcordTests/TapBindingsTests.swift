import Foundation
import Testing

@testable import Camcord

@Suite("TapBindings")
struct TapBindingsTests {

    /// A uniquely-named suite per test so tests never see each other's state or the
    /// user's real defaults.
    private func makeTestDefaults() -> UserDefaults {
        let suiteName = "dev.tavsan.camcord.tests.tapbindings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create a UserDefaults test suite")
        }
        return defaults
    }

    @Test("defaults when the key is absent: wheel = paste, button 4 = captureRegion, button 5 = hold-capture, double-tap off")
    func defaultsWhenKeyAbsent() {
        let defaults = makeTestDefaults()
        let loaded = TapBindings.load(from: defaults)
        #expect(loaded == TapBindings(mouseButton3: .paste, mouseButton4: .captureRegion, mouseButton5: .holdCaptureRegion, doubleTapRightCommand: nil))
    }

    @Test("the hold-capture action round-trips through JSON")
    func holdActionRoundTrip() {
        let defaults = makeTestDefaults()
        let bindings = TapBindings(mouseButton4: .holdCaptureRegion, mouseButton5: nil, doubleTapRightCommand: nil)
        bindings.save(to: defaults)
        #expect(TapBindings.load(from: defaults) == bindings)
    }

    @Test("round-trips through UserDefaults as JSON under the tapBindings key")
    func codableRoundTrip() {
        let defaults = makeTestDefaults()
        let bindings = TapBindings(
            mouseButton4: nil,
            mouseButton5: .toggleRecording,
            doubleTapRightCommand: .captureRegion
        )
        bindings.save(to: defaults)

        #expect(defaults.data(forKey: "tapBindings") != nil)
        #expect(TapBindings.load(from: defaults) == bindings)
    }

    @Test("anyEnabled is true iff at least one binding is non-nil")
    func anyEnabledLogic() {
        #expect(TapBindings(mouseButton3: nil, mouseButton4: nil, mouseButton5: nil, doubleTapRightCommand: nil).anyEnabled == false)
        #expect(TapBindings(mouseButton3: .paste, mouseButton4: nil, mouseButton5: nil, doubleTapRightCommand: nil).anyEnabled == true)
        #expect(TapBindings(mouseButton3: nil, mouseButton4: .captureRegion, mouseButton5: nil, doubleTapRightCommand: nil).anyEnabled == true)
        #expect(TapBindings(mouseButton3: nil, mouseButton4: nil, mouseButton5: .toggleRecording, doubleTapRightCommand: nil).anyEnabled == true)
        #expect(TapBindings(mouseButton3: nil, mouseButton4: nil, mouseButton5: nil, doubleTapRightCommand: .captureRegion).anyEnabled == true)
    }

    @Test("the paste action round-trips through JSON")
    func pasteActionRoundTrip() {
        let defaults = makeTestDefaults()
        let bindings = TapBindings(mouseButton3: .paste, mouseButton4: nil, mouseButton5: nil, doubleTapRightCommand: nil)
        bindings.save(to: defaults)
        #expect(TapBindings.load(from: defaults) == bindings)
    }
}

@Suite("HoldGestureDetector")
struct HoldGestureDetectorTests {
    @Test("a plain hold (no preceding tap) is a screenshot")
    func plainHoldIsScreenshot() {
        var d = HoldGestureDetector()
        #expect(d.modeForPress(at: 0.0) == .screenshot)
    }

    @Test("tap (no-drag release) then hold within the window is OCR text")
    func tapThenHoldIsText() {
        var d = HoldGestureDetector()
        // First press: screenshot mode, but it turns out to be a tap (no drag).
        #expect(d.modeForPress(at: 0.0) == .screenshot)
        d.registerRelease(dragged: false, at: 0.1)
        // Second press within the window → OCR.
        #expect(d.modeForPress(at: 0.3) == .text)
    }

    @Test("a tap followed by a hold AFTER the window is a plain screenshot again")
    func tapThenLateHoldIsScreenshot() {
        var d = HoldGestureDetector()
        _ = d.modeForPress(at: 0.0)
        d.registerRelease(dragged: false, at: 0.1)
        // Past the 0.4s window from release → the tap no longer carries over.
        #expect(d.modeForPress(at: 0.6) == .screenshot)
    }

    @Test("a completed hold (drag) does not arm the next press for OCR")
    func draggedReleaseDoesNotArm() {
        var d = HoldGestureDetector()
        _ = d.modeForPress(at: 0.0)
        d.registerRelease(dragged: true, at: 0.5)
        #expect(d.modeForPress(at: 0.6) == .screenshot)
    }
}
