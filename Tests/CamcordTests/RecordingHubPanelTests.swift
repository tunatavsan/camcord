import AppKit
import Testing

@testable import Camcord

/// The hub panel's geometry end to end: show, hover open, drag, drop, settle, close. The
/// owner's bug was a disc that came back 72 pt left of the top-centre dock after every drop,
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

    /// The identity disc's centre, in screen coordinates.
    private func discCenter(_ hub: RecordingHubPanel) throws -> CGFloat {
        let view = hub.viewForTesting
        let identity = RecordingHubLayout.identity(mode: view.mode)
        let cell = try #require(view.cells.first { $0.item == identity })
        return hub.panelForTesting.frame.minX + cell.rect.minX + RecordingHubLayout.disc / 2
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
        #expect(hub.capsuleForTesting.width == RecordingHubLayout.disc)
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
        #expect(hub.capsuleForTesting.width == RecordingHubLayout.disc)
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
            #expect(identity?.rect.minX == center - RecordingHubLayout.disc / 2)
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

    @Test("the hub is Liquid Glass: one dark tinted glass capsule that follows the spring, never dimmed at rest")
    func glassSurface() throws {
        _ = NSApplication.shared
        let hub = RecordingHubPanel(defaults: try freshDefaults(), panelPresenter: { _ in })
        hub.showForTesting(mode: .recording, area: area)
        let view = hub.viewForTesting
        let glass = view.glass
        #expect(glass.superview === view)
        #expect(glass.style == .regular)
        #expect(glass.tintColor == RecordingHubView.glassTint)
        #expect(view.appearance?.name == .darkAqua)

        // Idle, not hovered: fully opaque.
        #expect(hub.panelForTesting.alphaValue == 1)
        #expect(glass.frame == view.capsuleRect)
        #expect(glass.cornerRadius == RecordingHubLayout.disc / 2)

        hub.setHoveredForTesting(true)
        hub.settleForTesting()
        #expect(glass.frame == view.capsuleRect)
        #expect(glass.frame.width == RecordingHubLayout.expandedWidth(mode: .recording, growth: .centered))
        #expect(hub.panelForTesting.alphaValue == 1)

        hub.setHoveredForTesting(false)
        hub.settleForTesting()
        #expect(glass.frame == view.capsuleRect)
        #expect(glass.frame.width == RecordingHubLayout.disc)
        #expect(hub.panelForTesting.alphaValue == 1)
        // Hit testing still belongs to the hub view, not the glass it hosts.
        let center = CGPoint(x: view.frame.midX, y: view.frame.midY)
        #expect(view.hitTest(center) === view)
        hub.hide()
    }
}
