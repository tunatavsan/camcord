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

    @Test("defaults when the key is absent: button 4 = captureRegion, button 5 = hold-capture, double-tap off")
    func defaultsWhenKeyAbsent() {
        let defaults = makeTestDefaults()
        let loaded = TapBindings.load(from: defaults)
        #expect(loaded == TapBindings(mouseButton4: .captureRegion, mouseButton5: .holdCaptureRegion, doubleTapRightCommand: nil))
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
        #expect(TapBindings(mouseButton4: nil, mouseButton5: nil, doubleTapRightCommand: nil).anyEnabled == false)
        #expect(TapBindings(mouseButton4: .captureRegion, mouseButton5: nil, doubleTapRightCommand: nil).anyEnabled == true)
        #expect(TapBindings(mouseButton4: nil, mouseButton5: .toggleRecording, doubleTapRightCommand: nil).anyEnabled == true)
        #expect(TapBindings(mouseButton4: nil, mouseButton5: nil, doubleTapRightCommand: .captureRegion).anyEnabled == true)
    }
}
