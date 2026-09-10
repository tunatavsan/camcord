import Foundation
import Testing

@testable import Camcord

/// Everything the hub decides before a pixel is drawn: where it docks, how the hover
/// expansion opens and closes, how the spring settles, where the cells land, and when the
/// recording frame is allowed to be seen. All pure — no panel, no window, no clock.
@Suite("Recording hub")
struct RecordingHubTests {
    private let area = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let hub = CGSize(width: 44, height: 44)

    // MARK: - Docks

    @Test("five docks land on their own edges, using the camera tile's margin")
    func dockGeometry() {
        let margin = CameraOptions.margin(in: area.size)
        #expect(RecordingHubDock.allCases.count == 5)

        let topLeft = RecordingHubDock.topLeft.rect(size: hub, in: area)
        #expect(topLeft.minX == area.minX + margin)
        #expect(topLeft.maxY == area.maxY - margin)

        let topCenter = RecordingHubDock.topCenter.rect(size: hub, in: area)
        #expect(topCenter.midX == area.midX)
        #expect(topCenter.maxY == area.maxY - margin)

        let topRight = RecordingHubDock.topRight.rect(size: hub, in: area)
        #expect(topRight.maxX == area.maxX - margin)
        #expect(topRight.maxY == area.maxY - margin)

        let bottomLeft = RecordingHubDock.bottomLeft.rect(size: hub, in: area)
        #expect(bottomLeft.minX == area.minX + margin)
        #expect(bottomLeft.minY == area.minY + margin)

        let bottomRight = RecordingHubDock.bottomRight.rect(size: hub, in: area)
        #expect(bottomRight.maxX == area.maxX - margin)
        #expect(bottomRight.minY == area.minY + margin)

        // Only the right-edge docks grow inward.
        #expect(RecordingHubDock.allCases.filter(\.mirrored) == [.topRight, .bottomRight])
    }

    @Test("a drop at the top middle docks top-centre, not to the right")
    func topCenterWins() {
        let dropped = CGRect(x: area.midX - 22, y: area.maxY - 60, width: 44, height: 44)
        #expect(RecordingHubDock.nearest(to: dropped, in: area) == .topCenter)
        #expect(RecordingHubDock.dock(forDrop: dropped, velocity: CGPoint(x: 8, y: -4), in: area) == .topCenter)
        // Every dock is reachable by dropping next to it.
        for dock in RecordingHubDock.allCases {
            let resting = dock.rect(size: hub, in: area).offsetBy(dx: 6, dy: -6)
            #expect(RecordingHubDock.nearest(to: resting, in: area) == dock)
        }
    }

    @Test("a throw docks where it was heading, a slow release docks where it was dropped")
    func flingAndDrop() {
        let centre = CGRect(x: area.midX - 22, y: area.midY - 22, width: 44, height: 44)
        // Faster than the tile's own fling threshold, aimed up and right.
        let thrown = CGPoint(x: 1800, y: 1400)
        #expect(hypot(thrown.x, thrown.y) >= CameraDragMotion.flingSpeed)
        #expect(RecordingHubDock.dock(forDrop: centre, velocity: thrown, in: area) == .topRight)
        #expect(RecordingHubDock.dock(forDrop: centre, velocity: CGPoint(x: -1800, y: -1400), in: area) == .bottomLeft)
        // Below the threshold the throw is ignored and the drop position decides.
        let nearBottomLeft = CGRect(x: 60, y: 60, width: 44, height: 44)
        #expect(RecordingHubDock.dock(forDrop: nearBottomLeft, velocity: CGPoint(x: 400, y: 300), in: area) == .bottomLeft)
    }

    @Test("the dock persists, defaults to top-centre and survives settings written before it existed")
    func dockPersistence() throws {
        #expect(RecordingSettings().hubDock == .topCenter)

        let legacy = try JSONDecoder().decode(RecordingSettings.self, from: Data("{\"fps\":30}".utf8))
        #expect(legacy.hubDock == .topCenter)
        let unknown = try JSONDecoder().decode(
            RecordingSettings.self, from: Data("{\"hubDock\":\"middleOfNowhere\"}".utf8)
        )
        #expect(unknown.hubDock == .topCenter)

        var moved = RecordingSettings()
        moved.hubDock = .bottomRight
        let decoded = try JSONDecoder().decode(RecordingSettings.self, from: JSONEncoder().encode(moved))
        #expect(decoded.hubDock == .bottomRight)

        // A whole-struct write from another surface must not drag the dock back.
        var otherEditor = RecordingSettings()
        otherEditor.fps = 30
        let merged = moved.merging(from: RecordingSettings(), into: otherEditor)
        #expect(merged.hubDock == .bottomRight)
        #expect(merged.fps == 30)

        let defaults = try #require(UserDefaults(suiteName: "camcord.hub.dock.test"))
        defaults.removePersistentDomain(forName: "camcord.hub.dock.test")
        #expect(RecordingSettings.load(from: defaults).hubDock == .topCenter)
        moved.save(to: defaults)
        #expect(RecordingSettings.load(from: defaults).hubDock == .bottomRight)
        defaults.removePersistentDomain(forName: "camcord.hub.dock.test")
    }

    // MARK: - Hover

    @Test("hover expands at once and collapses only after the grace period")
    func hoverStateMachine() {
        var hover = RecordingHubHover()
        #expect(!hover.expanded)
        #expect(hover.alpha == 0.55)

        hover.pointerEntered(at: 10)
        #expect(hover.expanded)
        #expect(hover.pointerInside)
        #expect(hover.alpha == 1)

        hover.pointerExited(at: 10)
        #expect(!hover.pointerInside)
        #expect(hover.collapseAt == 10 + RecordingHubHover.collapseDelay)

        // Still open while the pointer is only just off the capsule.
        hover.advance(to: 10.2)
        #expect(hover.expanded)
        hover.advance(to: 10.39)
        #expect(hover.expanded)
        hover.advance(to: 10.4)
        #expect(!hover.expanded)
        #expect(hover.alpha == 0.55)
    }

    @Test("coming back inside the grace period cancels the collapse")
    func hoverReentry() {
        var hover = RecordingHubHover()
        hover.pointerEntered(at: 0)
        hover.pointerExited(at: 0)
        hover.pointerEntered(at: 0.2)
        #expect(hover.collapseAt == nil)
        hover.advance(to: 1)
        #expect(hover.expanded)
        // A second exit with no matching enter cannot arm a second deadline.
        hover.pointerExited(at: 1)
        let armed = hover.collapseAt
        hover.pointerExited(at: 2)
        #expect(hover.collapseAt == armed)
    }

    // MARK: - Expansion spring

    @Test("the expansion spring reaches the capsule inside 260 ms with one whisper of overshoot")
    func expansionSpring() {
        var expansion = RecordingHubExpansion()
        expansion.target = 1
        var peak: CGFloat = 0
        var elapsed: TimeInterval = 0
        while elapsed < 0.26 {
            expansion.step(seconds: 1.0 / 120)
            elapsed += 1.0 / 120
            peak = max(peak, expansion.progress)
        }
        #expect(expansion.progress > 0.97)
        #expect(peak <= 1.03)
        // ζ = 0.8: underdamped, so it must actually be settled soon after, not creeping.
        while !expansion.isSettled, elapsed < 0.6 {
            expansion.step(seconds: 1.0 / 120)
            elapsed += 1.0 / 120
        }
        #expect(expansion.isSettled)
        #expect(expansion.progress == 1)

        expansion.target = 0
        elapsed = 0
        while !expansion.isSettled, elapsed < 0.6 {
            expansion.step(seconds: 1.0 / 120)
            elapsed += 1.0 / 120
        }
        #expect(expansion.progress == 0)

        var reduced = RecordingHubExpansion()
        reduced.target = 1
        reduced.finishImmediately()
        #expect(reduced.progress == 1)
        #expect(reduced.isSettled)
    }

    // MARK: - Layout

    @Test("collapsed is a 44 pt disc holding the identity cell")
    func collapsedDisc() {
        for mode in [RecordingHubMode.recording, .paused, .armed] {
            #expect(RecordingHubLayout.size(mode: mode, progress: 0) == CGSize(width: 44, height: 44))
        }
        #expect(RecordingHubLayout.identity(mode: .recording) == .elapsed)
        #expect(RecordingHubLayout.identity(mode: .paused) == .elapsed)
        #expect(RecordingHubLayout.identity(mode: .armed) == .start)
        // The capsule is wider than the disc in both modes, and grows monotonically.
        for mode in [RecordingHubMode.recording, .armed] {
            let expanded = RecordingHubLayout.expandedWidth(mode: mode)
            #expect(expanded > RecordingHubLayout.disc)
            #expect(RecordingHubLayout.width(mode: mode, progress: 1) == expanded)
            #expect(RecordingHubLayout.width(mode: mode, progress: 0.5)
                == RecordingHubLayout.disc + (expanded - RecordingHubLayout.disc) / 2)
            #expect(RecordingHubLayout.width(mode: mode, progress: 2) == expanded)
        }
    }

    @Test("every expanded cell sits inside the capsule and every control is a real target")
    func expandedCells() {
        for mode in [RecordingHubMode.recording, .armed] {
            let capsule = CGRect(x: 100, y: 40,
                                 width: RecordingHubLayout.expandedWidth(mode: mode),
                                 height: RecordingHubLayout.disc)
            for mirrored in [false, true] {
                let cells = RecordingHubLayout.cells(
                    mode: mode,
                    anchoredAt: mirrored ? capsule.maxX : capsule.minX,
                    verticalCenter: capsule.midY,
                    mirrored: mirrored
                )
                #expect(cells.count == RecordingHubLayout.items(mode: mode).count)
                for cell in cells {
                    #expect(capsule.contains(cell.rect))
                    if cell.item.isControl {
                        // A pointer target, not a hairline: comfortably past the desktop floor.
                        #expect(cell.rect.width >= 36)
                        #expect(cell.rect.height == 44)
                    }
                }
                // No two cells overlap.
                for (index, cell) in cells.enumerated() {
                    for other in cells.dropFirst(index + 1) {
                        #expect(cell.rect.intersection(other.rect).width < 0.001)
                    }
                }
                // The identity cell keeps the docked edge.
                let identity = cells.first { $0.item == RecordingHubLayout.identity(mode: mode) }?.rect
                #expect(identity != nil)
                if let identity {
                    #expect(mirrored ? identity.maxX == capsule.maxX : identity.minX == capsule.minX)
                }
            }
        }
    }

    @Test("the recording hub offers pause, stop, the camera eye and a mic level; armed offers Başlat and ×")
    func itemsPerMode() {
        #expect(RecordingHubLayout.items(mode: .recording) == [.elapsed, .divider, .pause, .stop, .preview, .micLevel])
        #expect(RecordingHubLayout.items(mode: .paused) == RecordingHubLayout.items(mode: .recording))
        #expect(RecordingHubLayout.items(mode: .armed) == [.start, .divider, .cancel])
        #expect(RecordingHubLayout.items(mode: .recording).filter(\.isControl) == [.pause, .stop, .preview])
        #expect(RecordingHubLayout.items(mode: .armed).filter(\.isControl) == [.start, .cancel])
        #expect(!RecordingHubItem.elapsed.isControl)
        #expect(!RecordingHubItem.divider.isControl)
        #expect(!RecordingHubItem.micLevel.isControl)
    }

    @Test("the mic dot reads the recorded track's dBFS")
    func micFraction() {
        #expect(RecordingHubLayout.micFraction(dbfs: nil) == 0)
        #expect(RecordingHubLayout.micFraction(dbfs: -90) == 0)
        #expect(RecordingHubLayout.micFraction(dbfs: -60) == 0)
        #expect(RecordingHubLayout.micFraction(dbfs: -30) == 0.5)
        #expect(RecordingHubLayout.micFraction(dbfs: 0) == 1)
        #expect(RecordingHubLayout.micFraction(dbfs: 12) == 1)
        #expect(RecordingHubLayout.micFraction(dbfs: .nan) == 0)
    }

    // MARK: - Recording frame visibility

    @Test("the frame is invisible while recording unless the hub is hovered or the start is fresh")
    func frameVisibilityTable() {
        var frame = RecordingFrameVisibility()
        // A border with no hub — the scrolling capture — is simply visible.
        #expect(frame.alpha == 1)

        frame.mode = .armed
        #expect(frame.alpha == 0.6)
        frame.hoveringHub = true
        #expect(frame.alpha == 1)

        frame.hoveringHub = false
        frame.mode = .recording
        frame.withinStartGrace = true
        #expect(frame.alpha == 1)
        frame.withinStartGrace = false
        #expect(frame.alpha == 0)
        frame.hoveringHub = true
        #expect(frame.alpha == 1)

        // A display recording never draws one, in any state — including in a game.
        frame.isDisplayTarget = true
        #expect(frame.alpha == 0)
        frame.hoveringHub = false
        frame.withinStartGrace = true
        #expect(frame.alpha == 0)
        frame.mode = .armed
        #expect(frame.alpha == 0)
    }
}
