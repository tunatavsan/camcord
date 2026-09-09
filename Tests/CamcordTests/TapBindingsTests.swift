import AppKit
import Foundation
import KeyboardShortcuts
import Testing

@testable import Camcord

@Suite("TapBindings")
struct TapBindingsTests {

    @Test("a lost hold release is cleared by the physical-button watchdog")
    @MainActor func watchdogReleasesLostHold() {
        let coordinator = CaptureCoordinator()
        let engine = EventTapEngine(
            coordinator: coordinator, recordingController: RecordingController(coordinator: coordinator),
            bindings: TapBindings(mouseButton3: nil, mouseButton4: nil, mouseButton5: nil, doubleTapRightCommand: nil),
            buttonIsDown: { _ in false }
        )
        engine.activeHoldButton = 4
        engine.watchdogTick()
        #expect(engine.activeHoldButton == nil)
        #expect(!engine.handle(type: .leftMouseUp, button: 0, keycode: 0,
                              isRightCommandDown: false, timestamp: 0, location: .zero))
    }

    @Test("arming the capture modifier during an existing drag passes its drag and release through")
    @MainActor func modifierPreservesExistingDragRelease() {
        let coordinator = CaptureCoordinator()
        let engine = EventTapEngine(
            coordinator: coordinator, recordingController: RecordingController(coordinator: coordinator),
            buttonIsDown: { $0 == 0 }
        )
        #expect(!engine.handle(type: .leftMouseDown, button: 0, keycode: 0,
                              isRightCommandDown: false, timestamp: 0, location: .zero))
        #expect(engine.handle(type: .otherMouseDown, button: 4, keycode: 0,
                             isRightCommandDown: false, timestamp: 1, location: .zero))
        #expect(!engine.handle(type: .leftMouseDragged, button: 0, keycode: 0,
                              isRightCommandDown: false, timestamp: 2, location: .zero))
        #expect(!engine.handle(type: .leftMouseUp, button: 0, keycode: 0,
                              isRightCommandDown: false, timestamp: 3, location: .zero))
    }

    /// A uniquely-named suite per test so tests never see each other's state or the
    /// user's real defaults.
    private func makeTestDefaults() -> UserDefaults {
        let suiteName = "dev.tavsan.camcord.tests.tapbindings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create a UserDefaults test suite")
        }
        return defaults
    }

    @Test("defaults when the key is absent: wheel = off, button 4 = paste, button 5 = capture-modifier, double-tap off")
    func defaultsWhenKeyAbsent() {
        let defaults = makeTestDefaults()
        let loaded = TapBindings.load(from: defaults)
        #expect(loaded == TapBindings(mouseButton3: nil, mouseButton4: .paste, mouseButton5: .captureModifier, doubleTapRightCommand: nil))
    }

    @Test("the capture-modifier action round-trips through JSON")
    func captureModifierRoundTrip() {
        let defaults = makeTestDefaults()
        let bindings = TapBindings(mouseButton3: nil, mouseButton4: .paste, mouseButton5: .captureModifier, doubleTapRightCommand: nil)
        bindings.save(to: defaults)
        #expect(TapBindings.load(from: defaults) == bindings)
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
        #expect(d.modeForPress(button: 4, at: 0.0) == .screenshot)
    }

    @Test("tap (no-drag release) then hold within the window is OCR text")
    func tapThenHoldIsText() {
        var d = HoldGestureDetector()
        // First press: screenshot mode, but it turns out to be a tap (no drag).
        #expect(d.modeForPress(button: 4, at: 0.0) == .screenshot)
        d.registerRelease(button: 4, dragged: false, at: 0.1)
        // Second press within the window → OCR.
        #expect(d.modeForPress(button: 4, at: 0.3) == .text)
    }

    @Test("a tap followed by a hold AFTER the window is a plain screenshot again")
    func tapThenLateHoldIsScreenshot() {
        var d = HoldGestureDetector()
        _ = d.modeForPress(button: 4, at: 0.0)
        d.registerRelease(button: 4, dragged: false, at: 0.1)
        // Past the 0.4s window from release → the tap no longer carries over.
        #expect(d.modeForPress(button: 4, at: 0.6) == .screenshot)
    }

    @Test("a completed hold (drag) does not arm the next press for OCR")
    func draggedReleaseDoesNotArm() {
        var d = HoldGestureDetector()
        _ = d.modeForPress(button: 4, at: 0.0)
        d.registerRelease(button: 4, dragged: true, at: 0.5)
        #expect(d.modeForPress(button: 4, at: 0.6) == .screenshot)
    }

    @Test("a tap on one button never arms OCR for a different button's hold")
    func tapDoesNotArmOtherButton() {
        var d = HoldGestureDetector()
        // Tap button 4...
        _ = d.modeForPress(button: 4, at: 0.0)
        d.registerRelease(button: 4, dragged: false, at: 0.1)
        // ...then hold button 5 within the window → still a screenshot, not OCR.
        #expect(d.modeForPress(button: 5, at: 0.3) == .screenshot)
    }

    @Test("a shortcut already held by another action is a conflict, and only that")
    func shortcutConflictRule() {
        let taken = KeyboardShortcuts.Shortcut(.five, modifiers: [.command, .shift])
        let free = KeyboardShortcuts.Shortcut(.six, modifiers: [.command, .shift])
        let assignments: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [
            .captureRegion: taken,
            .toggleRecording: free,
        ]

        // Another action holds it → the owner is asked before anything moves.
        #expect(ShortcutCatalogue.conflict(assigning: taken, to: .toggleCameraPreview, in: assignments) == .captureRegion)
        // Re-recording the SAME combination onto the action that already has it is not a
        // conflict with itself — that would make a shortcut impossible to re-confirm.
        #expect(ShortcutCatalogue.conflict(assigning: taken, to: .captureRegion, in: assignments) == nil)
        // An unused combination is free.
        #expect(ShortcutCatalogue.conflict(assigning: KeyboardShortcuts.Shortcut(.seven, modifiers: [.command]),
                                           to: .toggleCameraPreview, in: assignments) == nil)
    }

    @Test("every shortcut Settings offers is actually bound to a handler")
    @MainActor func everyShortcutIsBound() {
        let coordinator = CaptureCoordinator()
        let controller = RecordingController(coordinator: coordinator)
        _ = HotkeyCenter(coordinator: coordinator, recordingController: controller)
        // Settings can record a key for anything in the catalogue; anything the catalogue
        // lists but HotkeyCenter never binds is a key that does nothing when pressed.
        for entry in ShortcutCatalogue.all {
            #expect(HotkeyCenter.boundNames.contains(entry.name.rawValue),
                    "\(entry.label) is offered in Settings but nothing listens for it")
        }
    }

    @Test("every shortcut Settings offers has a label and appears exactly once")
    func shortcutCatalogueIsComplete() {
        let names = ShortcutCatalogue.all.map(\.name)
        #expect(Set(names).count == names.count)
        for entry in ShortcutCatalogue.all {
            #expect(!entry.label.isEmpty)
            #expect(ShortcutCatalogue.label(for: entry.name) == entry.label)
        }
        // The two camera shortcuts the owner asked for are in the list the recorders draw.
        #expect(names.contains(.toggleCameraPreview))
        #expect(names.contains(.toggleCameraRecording))
    }
}
