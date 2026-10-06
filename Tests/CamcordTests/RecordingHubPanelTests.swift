import AppKit
import Testing

@testable import Camcord

/// The hub panel's geometry end to end: show, hover open, drag, drop, settle, close. The
/// bug was a disc that came back 72 pt left of the top-centre dock after every drop,
/// so these measure the disc against the dock's centre after each of those steps.
@MainActor
@Suite("Recording hub panel geometry", .serialized)
struct RecordingHubPanelTests {
    private static let suiteName = "camcord.hub.panel.test"
    private let area = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    private func freshDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        return defaults
    }

    /// The identity pill's centre, in screen coordinates.
    private func discCenter(_ hub: RecordingHubPanel) throws -> CGFloat {
        let view = hub.viewForTesting
        let identity = RecordingHubLayout.identity(mode: view.mode)
        let cell = try #require(view.cells.first { $0.item == identity })
        return hub.panelForTesting.frame.minX + cell.rect.midX
    }

    @Test("at top-centre the disc stays on the dock's centre, open or closed, before and after a drag and drop",
          arguments: [RecordingHubMode.recording, .armed])
    func topCenterStaysCentred(mode: RecordingHubMode) throws {
        _ = NSApplication.shared
        let hub = RecordingHubPanel(defaults: try freshDefaults(), panelPresenter: { _ in })
        hub.showForTesting(mode: mode, area: area)
        #expect(hub.dockForTesting == .topCenter)
        let dockCenter = RecordingHubDock.topCenter.rect(size: CGSize(width: 44, height: 44), in: area).midX

        // Collapsed: a 44 pt disc on the dock's centre.
        #expect(hub.capsuleForTesting.width == RecordingHubLayout.collapsedWidth(mode: hub.viewForTesting.mode))
        #expect(abs(hub.capsuleForTesting.midX - dockCenter) <= 1)
        #expect(abs(try discCenter(hub) - dockCenter) <= 1)

        // Open: the capsule grows to both sides and the disc does not move.
        hub.setHoveredForTesting(true)
        hub.settleForTesting()
        #expect(hub.capsuleForTesting.width == RecordingHubLayout.expandedWidth(mode: mode, growth: .centered))
        #expect(abs(hub.capsuleForTesting.midX - dockCenter) <= 1)
        #expect(abs(try discCenter(hub) - dockCenter) <= 1)

        // Drag the OPEN hub away, bring it back slowly, and drop it near the top middle.
        let grip = CGPoint(x: dockCenter, y: hub.capsuleForTesting.midY)
        hub.dragForTesting(.began, to: grip, at: 10)
        hub.dragForTesting(.changed, to: CGPoint(x: grip.x - 300, y: grip.y - 240), at: 10.4)
        hub.dragForTesting(.changed, to: CGPoint(x: grip.x + 30, y: grip.y - 12), at: 11.2)
        hub.dragForTesting(.changed, to: CGPoint(x: grip.x + 30, y: grip.y - 12), at: 12.0)
        hub.dragForTesting(.ended, to: CGPoint(x: grip.x + 30, y: grip.y - 12), at: 12.8)
        #expect(hub.dockForTesting == .topCenter)
        hub.settleForTesting()
        #expect(abs(hub.capsuleForTesting.midX - dockCenter) <= 1)
        #expect(abs(try discCenter(hub) - dockCenter) <= 1)

        // Close: back to the disc, still on the dock's centre.
        hub.setHoveredForTesting(false)
        hub.settleForTesting()
        #expect(hub.capsuleForTesting.width == RecordingHubLayout.collapsedWidth(mode: hub.viewForTesting.mode))
        #expect(abs(hub.capsuleForTesting.midX - dockCenter) <= 1)
        #expect(abs(try discCenter(hub) - dockCenter) <= 1)
        hub.hide()
    }

    @Test("a collapse halfway through the release settle still lands the disc on the dock's centre")
    func collapseDuringSettleLandsCentred() throws {
        _ = NSApplication.shared
        let hub = RecordingHubPanel(defaults: try freshDefaults(), panelPresenter: { _ in })
        hub.showForTesting(mode: .recording, area: area)
        let dockCenter = RecordingHubDock.topCenter.rect(size: CGSize(width: 44, height: 44), in: area).midX
        hub.setHoveredForTesting(true)
        hub.settleForTesting()

        // Drop the open hub well off-centre, so the release spring has a long way to travel.
        let grip = CGPoint(x: dockCenter, y: hub.capsuleForTesting.midY)
        hub.dragForTesting(.began, to: grip, at: 20)
        hub.dragForTesting(.changed, to: CGPoint(x: grip.x + 90, y: grip.y - 20), at: 20.3)
        hub.dragForTesting(.ended, to: CGPoint(x: grip.x + 90, y: grip.y - 20), at: 20.6)
        #expect(hub.dockForTesting == .topCenter)

        // A few ticks in, the pointer leaves and the capsule collapses while the anchor moves.
        hub.advanceMotionForTesting(seconds: 0.08)
        #expect(abs(hub.capsuleForTesting.midX - dockCenter) > 1, "the settle should still be travelling")
        hub.setHoveredForTesting(false)
        hub.expireHoverGraceForTesting()
        hub.advanceMotionForTesting(seconds: 10)

        #expect(hub.capsuleForTesting.width == RecordingHubLayout.collapsedWidth(mode: hub.viewForTesting.mode))
        #expect(abs(hub.capsuleForTesting.midX - dockCenter) <= 1)
        #expect(abs(try discCenter(hub) - dockCenter) <= 1)
        hub.hide()
    }

    @Test("a corner dock keeps its edge: the disc stays on the edge it was dropped at")
    func cornerKeepsEdge() throws {
        _ = NSApplication.shared
        let defaults = try freshDefaults()
        var settings = RecordingSettings.load(from: defaults)
        settings.hubDock = .topRight
        settings.save(to: defaults)
        let hub = RecordingHubPanel(defaults: defaults, panelPresenter: { _ in })
        hub.showForTesting(mode: .recording, area: area)
        let edge = RecordingHubDock.topRight.rect(size: CGSize(width: 44, height: 44), in: area).maxX
        #expect(hub.capsuleForTesting.maxX == edge)
        hub.setHoveredForTesting(true)
        hub.settleForTesting()
        #expect(hub.capsuleForTesting.maxX == edge)
        #expect(hub.capsuleForTesting.width == RecordingHubLayout.expandedWidth(mode: .recording))
        hub.setHoveredForTesting(false)
        hub.settleForTesting()
        #expect(hub.capsuleForTesting.maxX == edge)
        hub.hide()
    }

    @Test("opening moves no control: cells sit where they rest, and a half-uncovered control takes no click")
    func openingMovesNothing() {
        let view = RecordingHubView(frame: .zero)
        view.growth = .centered
        view.mode = .recording
        let center: CGFloat = 400
        let inset = RecordingHubLayout.shadowInset
        func place(progress: CGFloat) {
            let width = RecordingHubLayout.width(mode: .recording, progress: progress, growth: .centered)
            // The panel's frame, in a space where the disc's centre is `center`.
            view.frame = CGRect(x: 0, y: 0, width: width + inset * 2, height: RecordingHubLayout.disc + inset * 2)
            view.progress = progress
        }
        func screenCells() -> [(item: RecordingHubItem, rect: CGRect)] {
            // Shift view space so the capsule's centre sits at `center`.
            let dx = center - view.capsuleRect.midX
            return view.cells.map { ($0.item, $0.rect.offsetBy(dx: dx, dy: 0)) }
        }

        place(progress: 1)
        let rest = screenCells()
        place(progress: 0.4)
        let midway = screenCells()
        #expect(rest.map(\.item) == midway.map(\.item))
        for (a, b) in zip(rest, midway) {
            #expect(a.rect == b.rect)
        }

        // Halfway open, the outer controls are not yet uncovered and cannot be pressed.
        guard let pause = midway.first(where: { $0.item == .pause }) else {
            Issue.record("no pause cell")
            return
        }
        let dx = center - view.capsuleRect.midX
        let point = CGPoint(x: pause.rect.midX - dx, y: pause.rect.midY)
        #expect(view.control(at: point) == nil)
        place(progress: 1)
        #expect(view.control(at: CGPoint(x: pause.rect.midX - (center - view.capsuleRect.midX), y: pause.rect.midY)) == .pause)
    }

    @Test("top-centre layout: the disc in the middle, controls on both sides, every control a real target")
    func centeredLayout() {
        for mode in [RecordingHubMode.recording, .armed] {
            let center: CGFloat = 800
            let cells = RecordingHubLayout.centeredCells(mode: mode, center: center, verticalCenter: 100)
            let width = RecordingHubLayout.expandedWidth(mode: mode, growth: .centered)
            let capsule = CGRect(x: center - width / 2, y: 100 - 22, width: width, height: 44)
            let identity = cells.first { $0.item == RecordingHubLayout.identity(mode: mode) }
            #expect(identity?.rect.midX == center)
            for cell in cells {
                #expect(capsule.contains(cell.rect))
                if cell.item.isControl {
                    #expect(cell.rect.width >= 36)
                    #expect(cell.rect.height == 44)
                }
            }
            for (index, cell) in cells.enumerated() {
                for other in cells.dropFirst(index + 1) {
                    #expect(cell.rect.intersection(other.rect).width < 0.001)
                }
            }
            // Every control of the edge layout is offered here too.
            #expect(Set(cells.map(\.item).filter(\.isControl))
                == Set(RecordingHubLayout.items(mode: mode).filter(\.isControl)))
        }
        // Recording puts controls on BOTH sides of the time.
        let recording = RecordingHubLayout.centeredCells(mode: .recording, center: 800, verticalCenter: 0)
        #expect(recording.contains { $0.item.isControl && $0.rect.maxX <= 800 - 22 })
        #expect(recording.contains { $0.item.isControl && $0.rect.minX >= 800 + 22 })
        // Every dock maps to the growth that keeps its edge, and its anchor survives a resize.
        #expect(RecordingHubDock.allCases.map(\.growth) == [.leading, .centered, .trailing, .leading, .trailing])
        for dock in RecordingHubDock.allCases {
            let small = dock.rect(size: CGSize(width: 44, height: 44), in: area)
            let large = dock.rect(size: CGSize(width: 214, height: 44), in: area)
            #expect(dock.anchor(of: small) == dock.anchor(of: large))
            #expect(dock.rect(size: large.size, anchoredAt: dock.anchor(of: small)) == large)
        }
    }

    @Test("the hub is a tray capsule carrying Liquid Glass chips, and opening never resizes its window")
    func traySurface() throws {
        _ = NSApplication.shared
        let hub = RecordingHubPanel(defaults: try freshDefaults(), panelPresenter: { _ in })
        hub.showForTesting(mode: .recording, area: area)
        let view = hub.viewForTesting
        func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
            ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
        }
        #expect(view.appearance?.name == .darkAqua)
        #expect(views(TraySurface.self, in: view).count == 1)
        // The time pill (which is also Stop), pause, the camera in the file and its preview.
        #expect(views(HubChip.self, in: view).count == 4)
        #expect(hub.panelForTesting.alphaValue == 1)
        let windowSize = hub.panelForTesting.frame.size

        hub.setHoveredForTesting(true)
        hub.settleForTesting()
        #expect(hub.panelForTesting.frame.size == windowSize)
        #expect(abs(view.capsuleRect.width - RecordingHubLayout.expandedWidth(mode: .recording, growth: .centered)) < 0.5)

        hub.setHoveredForTesting(false)
        hub.settleForTesting()
        #expect(hub.panelForTesting.frame.size == windowSize)
        #expect(abs(view.capsuleRect.width - RecordingHubLayout.collapsedWidth(mode: .recording)) < 0.5)
        // Hit testing belongs to the hub view, and only inside the capsule as it is now.
        let center = CGPoint(x: view.frame.midX, y: view.frame.midY)
        #expect(view.hitTest(center) === view)
        #expect(view.hitTest(CGPoint(x: view.frame.minX + 2, y: view.frame.midY)) == nil)
        hub.hide()
    }

    // MARK: - Inside the recorded window

    private let window = CGRect(x: 300, y: 200, width: 900, height: 600)

    @Test("a window target docks inside the window, on the camera tile's margin")
    func docksInsideWindow() throws {
        _ = NSApplication.shared
        let hub = RecordingHubPanel(defaults: try freshDefaults(), panelPresenter: { _ in })
        hub.tileFrame = { nil }
        hub.showForTesting(mode: .armed, area: area, window: window)
        #expect(hub.areaForTesting == window)
        let margin = CameraOptions.margin(in: window.size)
        #expect(window.contains(hub.capsuleForTesting))
        #expect(abs(hub.capsuleForTesting.midX - window.midX) <= 1)
        #expect(abs(hub.capsuleForTesting.maxY - (window.maxY - margin)) <= 0.5)
        // The hub sits above the camera tile.
        #expect(hub.panelForTesting.level.rawValue > CameraOverlayController.baseLevel.rawValue)
        hub.hide()
    }

    @Test("the docks move with the window, and a hub being dragged keeps the pointer")
    func followsWindow() throws {
        _ = NSApplication.shared
        let hub = RecordingHubPanel(defaults: try freshDefaults(), panelPresenter: { _ in })
        hub.tileFrame = { nil }
        hub.showForTesting(mode: .recording, area: area, window: window)
        let moved = window.offsetBy(dx: 180, dy: -120)
        hub.updateWindowForTesting(moved)
        #expect(hub.areaForTesting == moved)
        #expect(abs(hub.capsuleForTesting.midX - moved.midX) <= 1)
        #expect(abs(hub.capsuleForTesting.maxY - (moved.maxY - CameraOptions.margin(in: moved.size))) <= 0.5)

        // Resized smaller: the docks are recomputed for the new size.
        let resized = CGRect(x: moved.minX, y: moved.minY, width: 520, height: 400)
        hub.updateWindowForTesting(resized)
        #expect(abs(hub.capsuleForTesting.midX - resized.midX) <= 1)
        #expect(resized.contains(hub.capsuleForTesting))

        // Mid-drag the window moving does not yank the hub from under the pointer; the drop
        // then settles on the new window's dock.
        let grip = CGPoint(x: hub.capsuleForTesting.midX, y: hub.capsuleForTesting.midY)
        hub.dragForTesting(.began, to: grip, at: 1)
        hub.dragForTesting(.changed, to: CGPoint(x: grip.x + 10, y: grip.y - 8), at: 1.5)
        let held = hub.capsuleForTesting
        let later = resized.offsetBy(dx: 40, dy: 0)
        hub.updateWindowForTesting(later)
        #expect(hub.capsuleForTesting == held)
        hub.dragForTesting(.ended, to: CGPoint(x: grip.x + 10, y: grip.y - 8), at: 2.5)
        hub.settleForTesting()
        #expect(abs(hub.capsuleForTesting.midX - later.midX) <= 1)
        hub.hide()
    }

    @Test("window and tile changes preserve drag geometry through actual expansion ticks")
    func geometryChangesDuringDrag() throws {
        _ = NSApplication.shared
        let hub = RecordingHubPanel(defaults: try freshDefaults(), panelPresenter: { _ in })
        var tile: CGRect?
        hub.tileFrame = { tile }
        hub.showForTesting(mode: .recording, area: area, window: window)
        hub.setHoveredForTesting(true)
        hub.advanceMotionForTesting(seconds: 0.04)
        let capsule = hub.capsuleForTesting
        let grip = CGPoint(x: capsule.midX, y: capsule.midY)
        hub.dragForTesting(.began, to: grip, at: 1)
        let heldArea = hub.areaForTesting
        let heldGrowth = hub.viewForTesting.growth
        let moved = window.offsetBy(dx: 160, dy: -100)
        tile = CGRect(x: moved.midX - 120, y: moved.maxY - 150, width: 240, height: 135)
        hub.updateWindowForTesting(moved)
        #expect(hub.areaForTesting == heldArea)
        #expect(hub.viewForTesting.growth == heldGrowth)
        hub.advanceMotionForTesting(seconds: 0.2)
        #expect(hub.viewForTesting.growth == heldGrowth)
        #expect(hub.areaForTesting == heldArea)
        hub.dragForTesting(.changed, to: CGPoint(x: grip.x + 20, y: grip.y - 10), at: 2)
        let pointerRect = hub.capsuleForTesting
        hub.updateWindowForTesting(moved)
        #expect(hub.capsuleForTesting == pointerRect)
        hub.dragForTesting(.ended, to: CGPoint(x: grip.x + 20, y: grip.y - 10), at: 3)
        hub.settleForTesting()
        #expect(hub.areaForTesting == moved)
        #expect(hub.dockForTesting != .topCenter)
        #expect(moved.contains(hub.capsuleForTesting))
        #expect(!hub.capsuleForTesting.intersects(try #require(tile)))
        hub.hide()
    }

    @Test("a drag snaps only inside the window")
    func dragConfinedToWindow() throws {
        _ = NSApplication.shared
        let hub = RecordingHubPanel(defaults: try freshDefaults(), panelPresenter: { _ in })
        hub.tileFrame = { nil }
        hub.showForTesting(mode: .recording, area: area, window: window)
        let grip = CGPoint(x: hub.capsuleForTesting.midX, y: hub.capsuleForTesting.midY)
        hub.dragForTesting(.began, to: grip, at: 1)
        // Far outside the window, down and to the left.
        hub.dragForTesting(.changed, to: CGPoint(x: grip.x - 1200, y: grip.y - 900), at: 2)
        #expect(window.contains(hub.capsuleForTesting))
        hub.dragForTesting(.changed, to: CGPoint(x: grip.x - 1200, y: grip.y - 900), at: 3)
        hub.dragForTesting(.ended, to: CGPoint(x: grip.x - 1200, y: grip.y - 900), at: 4)
        hub.settleForTesting()
        #expect(hub.dockForTesting == .bottomLeft)
        #expect(window.contains(hub.capsuleForTesting))
        #expect(abs(hub.capsuleForTesting.minX - (window.minX + CameraOptions.margin(in: window.size))) <= 0.5)
        hub.hide()
    }

    @Test("the camera tile's dock is taken: the hub rests on the nearest free dock, and a drop there too")
    func avoidsCameraTile() throws {
        _ = NSApplication.shared
        let hub = RecordingHubPanel(defaults: try freshDefaults(), panelPresenter: { _ in })
        // A tile sitting at the top middle of the window.
        let tile = CGRect(x: window.midX - 120, y: window.maxY - 150, width: 240, height: 135)
        hub.tileFrame = { tile }
        hub.showForTesting(mode: .recording, area: area, window: window)
        #expect(hub.dockForTesting != .topCenter)
        #expect([.topLeft, .topRight].contains(hub.dockForTesting))
        let open = RecordingHubLayout.size(mode: .recording, progress: 1, growth: hub.dockForTesting.growth)
        #expect(!hub.dockForTesting.rect(size: open, in: window).intersects(tile))

        // The pure rule: free preferred stays, held preferred moves to the NEAREST free dock
        // (in a 900×600 window, up the right edge rather than across the bottom).
        let bottomRightTile = CGRect(x: window.maxX - 260, y: window.minY + 10, width: 250, height: 140)
        #expect(RecordingHubPlacement.dock(preferred: .topCenter, in: window, mode: .recording,
                                           avoiding: bottomRightTile) == .topCenter)
        #expect(RecordingHubPlacement.dock(preferred: .bottomRight, in: window, mode: .recording,
                                           avoiding: bottomRightTile) == .topRight)
        #expect(RecordingHubPlacement.dock(preferred: .bottomRight, in: window, mode: .recording,
                                           avoiding: nil) == .bottomRight)

        // A slow drop right onto the tile's dock rests beside it instead.
        hub.tileFrame = { bottomRightTile }
        let grip = CGPoint(x: hub.capsuleForTesting.midX, y: hub.capsuleForTesting.midY)
        let aim = CGPoint(x: window.maxX - 60, y: window.minY + 40)
        hub.dragForTesting(.began, to: grip, at: 1)
        hub.dragForTesting(.changed, to: aim, at: 2)
        hub.dragForTesting(.changed, to: aim, at: 3)
        hub.dragForTesting(.ended, to: aim, at: 4)
        hub.settleForTesting()
        #expect(hub.dockForTesting != .bottomRight)
        #expect(!hub.capsuleForTesting.intersects(bottomRightTile))
        hub.hide()
    }

    @Test("a window too small for the open capsule plus its margins docks on its display instead")
    func smallWindowFallsBack() throws {
        _ = NSApplication.shared
        let small = CGRect(x: 500, y: 400, width: 200, height: 90)
        #expect(RecordingHubPlacement.area(window: small, display: area, mode: .recording) == area)
        let short = CGRect(x: 500, y: 400, width: 900, height: 46)
        #expect(RecordingHubPlacement.area(window: short, display: area, mode: .armed) == area)
        #expect(RecordingHubPlacement.area(window: window, display: area, mode: .recording) == window)
        // Clipped to the display's visible frame: no dock under the menu bar or off screen.
        let overhanging = CGRect(x: -200, y: 300, width: 1000, height: 900)
        #expect(RecordingHubPlacement.area(window: overhanging, display: area, mode: .recording)
            == CGRect(x: 0, y: 300, width: 800, height: 700))
        // No window: the display.
        #expect(RecordingHubPlacement.area(window: nil, display: area, mode: .recording) == area)

        let hub = RecordingHubPanel(defaults: try freshDefaults(), panelPresenter: { _ in })
        hub.tileFrame = { nil }
        hub.showForTesting(mode: .recording, area: area, window: small)
        #expect(hub.areaForTesting == area)
        #expect(abs(hub.capsuleForTesting.midX - area.midX) <= 1)
        hub.hide()
    }
}
