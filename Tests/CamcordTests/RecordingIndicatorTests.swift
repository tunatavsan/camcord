import AppKit
import CoreGraphics
import Testing

@testable import Camcord

@MainActor
@Suite("Recording window indicator", .serialized)
struct RecordingIndicatorTests {
    /// A clean suite: the hub reads its dock from settings, and the machine running the
    /// tests must not be able to move it.
    private static let suiteName = "camcord.indicator.test"

    private func freshDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        return defaults
    }

    @Test("missing window lookup uses the initial rect and the hub docks top-centre, clickable when occluded")
    func initialFallbackAndDockedHub() throws {
        _ = NSApplication.shared
        let primaryHeight = try #require(NSScreen.screens.first?.frame.height)
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let initialAppKitRect = screen.visibleFrame.insetBy(dx: 80, dy: 80)
        let initialCGRect = Geometry.appKitToCG(initialAppKitRect, primaryScreenHeight: primaryHeight)
        let indicator = CaptureAreaIndicator(panelPresenter: { _ in }, defaults: try freshDefaults())

        indicator.showRecordingWindow(
            CGWindowID.max,
            initialCGRect: initialCGRect,
            showsBorder: true,
            onStop: {}
        )

        let border = try #require(indicator.borderPanelForTesting)
        let hub = try #require(indicator.hubPanelForTesting)
        #expect(border.frame == initialAppKitRect.insetBy(dx: -12, dy: -12))
        #expect(!hub.ignoresMouseEvents)
        // The dock is the persisted one, default top-centre — not wherever the target
        // happens to sit. The panel carries the hub's shadow margin around the capsule.
        #expect(indicator.hubForTesting?.dockForTesting == .topCenter)
        #expect(abs(hub.frame.midX - screen.visibleFrame.midX) < 0.5)
        #expect(hub.frame.maxY < screen.visibleFrame.maxY)
        #expect(hub.frame.midY > screen.visibleFrame.midY)
        #expect(hub.alphaValue == 0.55)

        // Occluding the recorded window hides the frame; the hub is docked to the display,
        // so the only way to stop the recording never goes away.
        indicator.setOccludedForTesting(true)
        #expect(indicator.frameAlphaForTesting == 0)
        #expect(!hub.ignoresMouseEvents)
        #expect(hub.alphaValue == 0.55)
        indicator.hide()
    }

    @Test("the hub survives a border-less window recording and a legacy region indicator")
    func optionalBorderAndRegionIndicator() throws {
        _ = NSApplication.shared
        let primaryHeight = try #require(NSScreen.screens.first?.frame.height)
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let target = screen.visibleFrame.insetBy(dx: 100, dy: 100)
        let cgTarget = Geometry.appKitToCG(target, primaryScreenHeight: primaryHeight)
        let indicator = CaptureAreaIndicator(panelPresenter: { _ in }, defaults: try freshDefaults())

        indicator.showRecordingWindow(
            CGWindowID.max,
            initialCGRect: cgTarget,
            showsBorder: false,
            onStop: {}
        )
        #expect(indicator.borderPanelForTesting == nil)
        #expect(indicator.hubPanelForTesting?.ignoresMouseEvents == false)

        indicator.show(cgRect: cgTarget, color: .systemRed, onStop: {})
        #expect(indicator.frameVisibilityForTesting.mode == .recording)
        indicator.setOccludedForTesting(true)
        #expect(indicator.frameAlphaForTesting == 0)
        #expect(indicator.hubPanelForTesting?.ignoresMouseEvents == false)
        indicator.hide()

        // No stop action means no hub — the scrolling-capture border, which is simply visible.
        indicator.show(cgRect: cgTarget, color: .systemBlue, onStop: nil)
        #expect(indicator.hubPanelForTesting == nil)
        #expect(indicator.frameVisibilityForTesting.mode == .plain)
        #expect(indicator.frameAlphaForTesting == 1)
        indicator.hide()
    }

    @Test("the armed hub starts and cancels, and shows its frame quietly until Başlat")
    func armedHubActions() throws {
        _ = NSApplication.shared
        let primaryHeight = try #require(NSScreen.screens.first?.frame.height)
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let target = screen.visibleFrame.insetBy(dx: 120, dy: 120)
        let cgTarget = Geometry.appKitToCG(target, primaryScreenHeight: primaryHeight)
        let indicator = CaptureAreaIndicator(panelPresenter: { _ in }, defaults: try freshDefaults())
        var starts = 0
        var cancels = 0

        indicator.showRecordingWindow(
            CGWindowID.max,
            initialCGRect: cgTarget,
            showsBorder: true,
            mode: .armed,
            color: .systemRed,
            onCancel: { cancels += 1 },
            onStop: { starts += 1 }
        )

        let hub = try #require(indicator.hubForTesting)
        #expect(hub.panelForTesting.frame.size
            == CGSize(width: 44 + 24, height: 44 + 24))
        #expect(indicator.frameVisibilityForTesting.mode == .armed)
        #expect(indicator.frameAlphaForTesting == 0.6)

        hub.viewForTesting.pressForTesting(.start)
        hub.viewForTesting.pressForTesting(.cancel)
        #expect(starts == 1)
        #expect(cancels == 1)
        // An armed hub gets no elapsed pushes, and must not be turned into a recording one.
        indicator.updateHub(elapsed: nil)
        #expect(hub.viewForTesting.mode == .armed)

        // Hovering the hub is what reveals the frame, in either mode.
        indicator.setHubHoveredForTesting(true)
        #expect(indicator.frameAlphaForTesting == 1)
        indicator.setHubHoveredForTesting(false)
        #expect(indicator.frameAlphaForTesting == 0.6)
        indicator.hide()
    }

    @Test("a recording frame shows for the first beat, then only on hover")
    func recordingFrameGrace() throws {
        _ = NSApplication.shared
        let primaryHeight = try #require(NSScreen.screens.first?.frame.height)
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let target = screen.visibleFrame.insetBy(dx: 140, dy: 140)
        let cgTarget = Geometry.appKitToCG(target, primaryScreenHeight: primaryHeight)
        let indicator = CaptureAreaIndicator(panelPresenter: { _ in }, defaults: try freshDefaults())

        indicator.showRecordingWindow(
            CGWindowID.max, initialCGRect: cgTarget, showsBorder: true, onStop: {}
        )
        #expect(indicator.frameVisibilityForTesting.withinStartGrace)
        #expect(indicator.frameAlphaForTesting == 1)

        indicator.endStartGraceForTesting()
        #expect(indicator.frameAlphaForTesting == 0)
        indicator.setHubHoveredForTesting(true)
        #expect(indicator.frameAlphaForTesting == 1)
        indicator.setHubHoveredForTesting(false)
        #expect(indicator.frameAlphaForTesting == 0)

        // Pause and resume only change the hub's glyphs, never its geometry.
        indicator.updateHub(elapsed: "1:04", paused: true)
        #expect(indicator.hubForTesting?.viewForTesting.mode == .paused)
        #expect(indicator.hubForTesting?.viewForTesting.elapsed == "1:04")
        indicator.updateHub(elapsed: "1:05", paused: false)
        #expect(indicator.hubForTesting?.viewForTesting.mode == .recording)
        indicator.hide()
        #expect(indicator.hubPanelForTesting == nil)
    }

    @Test("every hub control reaches its own action")
    func hubPressRouting() throws {
        _ = NSApplication.shared
        let primaryHeight = try #require(NSScreen.screens.first?.frame.height)
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let target = screen.visibleFrame.insetBy(dx: 130, dy: 130)
        let cgTarget = Geometry.appKitToCG(target, primaryScreenHeight: primaryHeight)
        let indicator = CaptureAreaIndicator(panelPresenter: { _ in }, defaults: try freshDefaults())
        var stops = 0
        var pauses = 0
        var previews = 0

        indicator.showRecordingWindow(
            CGWindowID.max,
            initialCGRect: cgTarget,
            showsBorder: true,
            onPauseResume: { pauses += 1 },
            onTogglePreview: { previews += 1 },
            onStop: { stops += 1 }
        )
        let view = try #require(indicator.hubForTesting?.viewForTesting)

        // Stop, pause and the camera eye each land on their OWN closure. `.start` and
        // `.stop` deliberately share one — an armed hub's Başlat IS the start action — so
        // a slip that routed anything else there would be invisible without this.
        view.pressForTesting(.stop)
        #expect((stops, pauses, previews) == (1, 0, 0))
        view.pressForTesting(.pause)
        #expect((stops, pauses, previews) == (1, 1, 0))
        view.pressForTesting(.preview)
        #expect((stops, pauses, previews) == (1, 1, 1))
        // The readouts are not controls and must fire nothing.
        view.pressForTesting(.elapsed)
        view.pressForTesting(.micLevel)
        view.pressForTesting(.divider)
        #expect((stops, pauses, previews) == (1, 1, 1))
        indicator.hide()
    }

    @Test("a display recording gets a hub and no frame at all")
    func displayTargetDrawsNoFrame() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let indicator = CaptureAreaIndicator(panelPresenter: { _ in }, defaults: try freshDefaults())

        indicator.showHubOnly(cgRect: screen.frame, color: .systemRed, onStop: {})
        #expect(indicator.borderPanelForTesting == nil)
        #expect(indicator.hubPanelForTesting != nil)
        #expect(indicator.frameVisibilityForTesting.isDisplayTarget)
        #expect(indicator.frameVisibilityForTesting.alpha == 0)
        indicator.hide()
    }
}
