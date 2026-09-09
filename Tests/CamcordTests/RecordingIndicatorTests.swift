import AppKit
import CoreGraphics
import Testing

@testable import Camcord

@MainActor
@Suite("Recording window indicator", .serialized)
struct RecordingIndicatorTests {
    @Test("missing window lookup uses the initial rect and keeps the stop pill clickable when occluded")
    func initialFallbackAndPersistentStopPill() throws {
        _ = NSApplication.shared
        let primaryHeight = try #require(NSScreen.screens.first?.frame.height)
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let initialAppKitRect = screen.visibleFrame.insetBy(dx: 80, dy: 80)
        let initialCGRect = Geometry.appKitToCG(initialAppKitRect, primaryScreenHeight: primaryHeight)
        let indicator = CaptureAreaIndicator(panelPresenter: { _ in })

        indicator.showRecordingWindow(
            CGWindowID.max,
            initialCGRect: initialCGRect,
            showsBorder: true,
            onStop: {}
        )

        let border = try #require(indicator.borderPanelForTesting)
        let stop = try #require(indicator.stopPanelForTesting)
        #expect(border.frame == initialAppKitRect.insetBy(dx: -12, dy: -12))
        #expect(screen.visibleFrame.contains(stop.frame))
        #expect(!stop.ignoresMouseEvents)

        indicator.setOccludedForTesting(true)

        #expect(border.contentView?.layer?.opacity == 0)
        #expect(stop.contentView?.layer?.opacity == 1)
        #expect(!stop.ignoresMouseEvents)
        indicator.hide()
    }

    @Test("recording stop pill exists without a border and legacy indicators retain coupled occlusion")
    func optionalBorderAndLegacyOcclusion() throws {
        _ = NSApplication.shared
        let primaryHeight = try #require(NSScreen.screens.first?.frame.height)
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let target = screen.visibleFrame.insetBy(dx: 100, dy: 100)
        let cgTarget = Geometry.appKitToCG(target, primaryScreenHeight: primaryHeight)
        let indicator = CaptureAreaIndicator(panelPresenter: { _ in })

        indicator.showRecordingWindow(
            CGWindowID.max,
            initialCGRect: cgTarget,
            showsBorder: false,
            onStop: {}
        )
        #expect(indicator.borderPanelForTesting == nil)
        #expect(indicator.stopPanelForTesting != nil)
        #expect(indicator.stopPanelForTesting?.ignoresMouseEvents == false)

        indicator.show(cgRect: cgTarget, color: .systemBlue, label: nil, onStop: {})
        indicator.setOccludedForTesting(true)
        #expect(indicator.stopPanelForTesting?.contentView?.layer?.opacity == 0)
        #expect(indicator.stopPanelForTesting?.ignoresMouseEvents == true)
        indicator.hide()
    }
}
