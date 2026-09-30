import AppKit
import Testing

@testable import Camcord

@MainActor
@Suite("Countdown cancellation", .serialized)
struct CountdownOverlayTests {
    @Test("cancelled before presentation never shows a panel or succeeds")
    func cancelledBeforeStart() async {
        var presentations = 0
        let task = Task { @MainActor in
            await CountdownOverlay.run(onScreenFrame: .zero, presenter: { _ in presentations += 1 })
        }
        task.cancel()
        #expect(await task.value == false)
        #expect(presentations == 0)
    }

    @Test("external cancellation during a beat returns false")
    func cancelledDuringBeat() async {
        _ = NSApplication.shared
        var started = false
        var beats = 0
        let task = Task { @MainActor in
            await CountdownOverlay.run(onScreenFrame: .zero, presenter: { _ in }, sleepBeat: {
                beats += 1
                started = true
                try await Task.sleep(for: .seconds(10))
            })
        }
        for _ in 0..<100 where !started { await Task.yield() }
        #expect(started)
        task.cancel()
        #expect(await task.value == false)
        #expect(beats == 1)
    }

    @Test("Esc, click and accessible press cancel the actual badge", arguments: [0, 1, 2])
    func badgeCancellation(method: Int) async throws {
        _ = NSApplication.shared
        var badge: NSView?
        let result = await CountdownOverlay.run(onScreenFrame: .zero, presenter: { panel in
            badge = panel.contentView
            #expect(panel.canBecomeKey)
            #expect(panel.styleMask.contains(.nonactivatingPanel))
        }, sleepBeat: {
            let view = try #require(badge)
            if method == 0 {
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                view.keyDown(with: event)
            } else if method == 1 {
                let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 0))
                view.mouseDown(with: event)
            } else { #expect(view.accessibilityPerformPress()) }
        })
        #expect(!result)
    }

    @Test("a completed countdown preserves all digits and beats")
    func completed() async {
        _ = NSApplication.shared
        var beats = 0
        #expect(await CountdownOverlay.run(onScreenFrame: .zero, seconds: 3,
            presenter: { _ in }, sleepBeat: { beats += 1 }) == true)
        #expect(beats == 30)
    }
}
