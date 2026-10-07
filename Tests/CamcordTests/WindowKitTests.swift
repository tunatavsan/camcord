import AppKit
import SwiftUI
import Testing
@testable import Camcord

@Suite("Window kit")
@MainActor
struct WindowKitTests {
    @Test("a hovered control rises and glows; its siblings step back, rows less than symbols")
    func liftFollowsThePanel() {
        let rest = KitLift.resolve(KitState(), kind: .symbol, reduceMotion: false)
        #expect(rest == KitLift(scale: 1, rise: 0, glow: 0, opacity: 1))

        let hovered = KitLift.resolve(KitState(focus: true), kind: .symbol, reduceMotion: false)
        #expect(hovered.scale == Theme.Window.Lift.symbolScale)
        #expect(hovered.rise == -Theme.Window.Lift.symbolRise)
        #expect(hovered.glow == Theme.Window.Lift.glowOpacity)

        let tool = KitLift.resolve(KitState(focus: true), kind: .tool, reduceMotion: false)
        #expect(tool.scale == Theme.Window.Lift.toolScale && tool.rise == -Theme.Window.Lift.toolRise)

        #expect(KitLift.resolve(KitState(focus: false), kind: .symbol, reduceMotion: false).opacity == Theme.Window.Lift.sibling)
        #expect(KitLift.resolve(KitState(focus: false), kind: .row, reduceMotion: false).opacity == Theme.Window.Lift.rowSibling)
        #expect(Theme.Window.Lift.rowSibling > Theme.Window.Lift.sibling)
    }

    @Test("a disabled control never rises and stays quiet even when hovered")
    func disabledStaysDown() {
        let lift = KitLift.resolve(KitState(focus: true, enabled: false), kind: .symbol, reduceMotion: false)
        #expect(lift == KitLift(scale: 1, rise: 0, glow: 0, opacity: Theme.Window.Lift.disabled))
    }

    @Test("Reduce Motion keeps the glow and the stepping back, never the movement")
    func reduceMotionDropsMovement() {
        let lift = KitLift.resolve(KitState(focus: true), kind: .tool, reduceMotion: true)
        #expect(lift.scale == 1 && lift.rise == 0)
        #expect(lift.glow == Theme.Window.Lift.glowOpacity)
        #expect(KitLift.pressScale(pressed: true, wide: false, reduceMotion: true) == 1)
    }

    @Test("a symbol gives the panel's 8 percent, a wide surface 2 percent")
    func pressScale() {
        #expect(KitLift.pressScale(pressed: false, wide: false, reduceMotion: false) == 1)
        #expect(KitLift.pressScale(pressed: true, wide: false, reduceMotion: false) == Theme.Window.Lift.press)
        #expect(KitLift.pressScale(pressed: true, wide: true, reduceMotion: false) == Theme.Window.Lift.widePress)
    }

    @Test("one focus per group: leaving a control never clears a sibling that took it")
    func hoverGroup() {
        let group = KitHoverGroup()
        #expect(group.focus(of: "a") == nil)
        group.hover("a", inside: true)
        #expect(group.focus(of: "a") == true && group.focus(of: "b") == false)
        // The pointer crosses into b before a reports that it left.
        group.hover("b", inside: true)
        group.hover("a", inside: false)
        #expect(group.focus(of: "b") == true && group.focus(of: "a") == false)
        group.hover("b", inside: false)
        #expect(group.focus(of: "b") == nil)
    }

    @Test("the window's motion is the panel's springs and Reduce Motion replaces each")
    func motionTokens() {
        #expect(Theme.Motion.resolve(Theme.Window.Motion.select, reduceMotion: true) == Theme.Motion.reduced)
        #expect(Theme.Motion.resolve(Theme.Window.Motion.lift, reduceMotion: false) == Theme.Window.Motion.lift)
    }

    @Test("every state renders, and light and dark differ", arguments: [false, true])
    func galleryRenders(dark: Bool) throws {
        let image = try Self.render(WindowKitGallery(), size: WindowKitGallery.size, dark: dark,
                                    name: "window-kit-\(dark ? "dark" : "light")")
        let other = try Self.render(WindowKitGallery(), size: WindowKitGallery.size, dark: !dark, name: nil)
        #expect(Self.distinctColours(in: image) > 40)
        #expect(Self.difference(image, other) > 0.1)
    }

    @Test("a hovered sidebar row draws differently from the same row at rest")
    func hoveredRowDiffers() throws {
        func row(_ state: KitState) -> some View {
            KitNavRow(symbol: "rectangle.stack", title: Text(verbatim: "Library"), key: "⌘1", selected: false,
                      preview: state) {}
                .frame(width: 200)
                .padding(Theme.Space.s)
        }
        let size = CGSize(width: 216, height: 48)
        let rest = try Self.render(row(KitState()), size: size, dark: true, name: nil)
        let hovered = try Self.render(row(KitState(focus: true)), size: size, dark: true, name: nil)
        let sibling = try Self.render(row(KitState(focus: false)), size: size, dark: true, name: nil)
        #expect(Self.difference(rest, hovered) > 0.005)
        #expect(Self.difference(rest, sibling) > 0.005)
    }

    // MARK: - Rendering

    /// Draws `view` offscreen at 2× with opaque materials (system glass does not draw offscreen).
    /// When CAMCORD_KIT_SHOTS names a folder, the PNG is kept there for review.
    static func render(_ view: some View, size: CGSize, dark: Bool, name: String?) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.environment(\.camcordOpaqueMaterialPreview, true))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        if let name, let folder = ProcessInfo.processInfo.environment["CAMCORD_KIT_SHOTS"] {
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    static func distinctColours(in rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        let stepX = max(1, rep.pixelsWide / 120), stepY = max(1, rep.pixelsHigh / 120)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                seen.insert(UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5 | UInt32(c.blueComponent * 31))
            }
        }
        return seen.count
    }

    /// The share of sampled pixels whose colour differs between two same-sized renders.
    static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 1 }
        var differing = 0, total = 0
        for y in stride(from: 0, to: a.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: a.pixelsWide, by: 2) {
                total += 1
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent)
                    + abs(p.blueComponent - q.blueComponent) > 0.03 { differing += 1 }
            }
        }
        return Double(differing) / Double(max(total, 1))
    }
}
