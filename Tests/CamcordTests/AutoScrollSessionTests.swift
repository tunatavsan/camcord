import CoreGraphics
import Foundation
import Testing

@testable import Camcord

/// Auto-scroll end to end on a scripted page: the real session, stitcher and settle loop, with
/// a page that moves only when the actuator moves it.
@MainActor
@Suite("Auto-scroll", .serialized)
struct AutoScrollSessionTests {
    /// A tall page seen through a viewport; every row is distinct, so the stitcher can align it.
    @MainActor final class Page: ScrollActuator {
        let route = "scripted"
        let viewport = 120
        let height: Int
        let full: CGImage
        private(set) var offset: Int
        private var sign: CGFloat
        let jumps: Bool
        /// Rows of a toolbar over the page that never scroll.
        let header: Int
        private let pageBytes: [UInt8]
        private let toolbar: [UInt8]
        private(set) var steps = 0

        init(height: Int, startingAt offset: Int, reversed: Bool = false, jumps: Bool = false, header: Int = 0) {
            self.height = height
            self.offset = offset
            sign = reversed ? -1 : 1
            self.jumps = jumps
            self.header = header
            pageBytes = Self.noise(rows: height, seed: 0)
            toolbar = Self.noise(rows: header, seed: 7_777)
            full = Self.image(pageBytes, rows: height)
        }

        static func noise(rows: Int, seed: Int) -> [UInt8] {
            (0..<(40 * rows)).map { index -> UInt8 in
                var z = UInt64((index / 40 + seed) * 40_503 + (index % 40) * 92_821) &+ 0x9E3779B97F4A7C15
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                return UInt8(truncatingIfNeeded: z ^ (z >> 31)) % 220
            }
        }
        static func image(_ bytes: [UInt8], rows: Int) -> CGImage {
            CGImage(width: 40, height: rows, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 40,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                    provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent)!
        }

        var maxOffset: Int { height - (viewport - header) }
        func frame() -> CGImage {
            let content = viewport - header
            let rows = pageBytes[(offset * 40)..<((offset + content) * 40)]
            return Self.image(toolbar + rows, rows: viewport)
        }

        func scroll(by points: CGFloat) async -> Bool {
            steps += 1
            offset = min(max(offset + Int((points * sign).rounded()), 0), maxOffset)
            return true
        }
        func jumpToTop() async -> Bool {
            guard jumps else { return false }
            offset = 0
            return true
        }
        func reverse() { sign = -sign }
        /// A scroll-bar page reports where it is; a wheel page does not.
        func position() -> CGFloat? { jumps ? CGFloat(offset) : nil }
    }

    private func session(on page: Page) -> (ScrollingCaptureSession, () -> Int) {
        var updates = 0
        let hooks = ScrollingCaptureSession.Hooks(
            prepare: {}, capture: { _ in page.frame() }, update: { _, _ in updates += 1 }, actuator: page)
        return (ScrollingCaptureSession(region: CGRect(x: 0, y: 0, width: 40, height: 120), hooks: hooks), { updates })
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    /// Runs auto from `page`'s current place to the end and returns the finished capture.
    private func autoCapture(_ page: Page) async -> CGImage? {
        let (session, updates) = session(on: page)
        let run = Task { await session.run() }
        await waitUntil { updates() >= 1 && session.readyForCaptureForTesting }
        session.toggleAutoForTesting()
        #expect(session.autoScrollingForTesting)
        guard case .completed(let image, _) = await run.value else { Issue.record("auto must finish the capture"); return nil }
        return image
    }

    @Test("started mid-page, it climbs to the top and captures down to exactly where the user started")
    func capturesFromTopToTheStart() async throws {
        let page = Page(height: 1_400, startingAt: 640)
        let image = try #require(await autoCapture(page))
        #expect(page.offset == 640, "the page ends where the user left it, not at \(page.offset)")
        #expect(abs(image.height - (640 + page.viewport)) <= 2, "captured \(image.height) rows")
    }

    @Test("auto asked for before the first frame (a double press) starts as soon as that frame is in")
    func requestedBeforeTheFirstFrame() async throws {
        let page = Page(height: 900, startingAt: 0)
        let (session, _) = session(on: page)
        session.requestAuto()
        #expect(!session.autoScrollingForTesting)
        guard case .completed(let image, _) = await session.run() else {
            Issue.record("the requested auto must run and finish the capture"); return
        }
        #expect(page.offset == page.maxOffset)
        #expect(abs(image.height - page.height) <= 2, "captured \(image.height) of \(page.height) rows")
    }

    @Test("auto waits for the shortcut's modifier keys to come up before its first step")
    func waitsForModifierRelease() async throws {
        let page = Page(height: 900, startingAt: 0)
        var held = true
        var updates = 0
        let hooks = ScrollingCaptureSession.Hooks(
            prepare: {}, capture: { _ in page.frame() }, update: { _, _ in updates += 1 }, actuator: page,
            modifiersHeld: { held })
        let session = ScrollingCaptureSession(region: CGRect(x: 0, y: 0, width: 40, height: 120), hooks: hooks)
        let run = Task { await session.run() }
        await waitUntil { updates >= 1 && session.readyForCaptureForTesting }
        session.toggleAutoForTesting()
        try await Task.sleep(for: .milliseconds(200))
        #expect(page.steps == 0, "no step while ⌘⇧ are still down")
        held = false
        guard case .completed(let image, _) = await run.value else {
            Issue.record("auto must run once the keys are up"); return
        }
        #expect(page.offset == page.maxOffset)
        #expect(abs(image.height - page.height) <= 2)
    }

    /// A page with a sidebar fixed beside it, like a web app's navigation.
    @MainActor final class SidebarPage: ScrollActuator {
        let route = "scripted"
        static let width = 160, sidebar = 40, viewport = 120
        let height = 900
        private(set) var offset = 0
        /// The page and the sidebar, both `width` wide; the sidebar shows its first columns.
        private let pageBytes: [UInt8]
        private let sidebarBytes: [UInt8]
        init() {
            pageBytes = (0..<(Self.width * height / 40)).flatMap { Page.noise(rows: 1, seed: $0 &* 7) }
            sidebarBytes = (0..<(Self.width * Self.viewport / 40)).flatMap { Page.noise(rows: 1, seed: 90_000 &+ $0) }
        }
        func pixel(_ x: Int, _ y: Int) -> UInt8 { pageBytes[y * Self.width + x] }
        func frame() -> CGImage {
            var bytes = [UInt8](repeating: 0, count: Self.width * Self.viewport)
            for y in 0..<Self.viewport {
                for x in 0..<Self.width {
                    // The sidebar shows the same rows whatever the page does.
                    bytes[y * Self.width + x] = x < Self.sidebar ? sidebarBytes[y * Self.width + x] : pixel(x, offset + y)
                }
            }
            return CGImage(width: Self.width, height: Self.viewport, bitsPerComponent: 8, bitsPerPixel: 8,
                           bytesPerRow: Self.width, space: CGColorSpaceCreateDeviceGray(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent)!
        }
        func scroll(by points: CGFloat) async -> Bool {
            offset = min(max(offset + Int(points.rounded()), 0), height - Self.viewport)
            return true
        }
        func jumpToTop() async -> Bool { false }
        func reverse() {}
        func position() -> CGFloat? { nil }
    }

    @Test("a sidebar fixed beside the page is cut away instead of repeating in every strip")
    func fixedSidebarIsCutAway() async throws {
        let page = SidebarPage()
        var updates = 0
        let hooks = ScrollingCaptureSession.Hooks(
            prepare: {}, capture: { _ in page.frame() }, update: { _, _ in updates += 1 }, actuator: page)
        let session = ScrollingCaptureSession(
            region: CGRect(x: 0, y: 0, width: SidebarPage.width, height: SidebarPage.viewport), hooks: hooks)
        let run = Task { await session.run() }
        await waitUntil { updates >= 1 && session.readyForCaptureForTesting }
        session.toggleAutoForTesting()
        guard case .completed(let image, _) = await run.value else { Issue.record("auto must finish"); return }
        #expect(image.width == SidebarPage.width - SidebarPage.sidebar, "kept \(image.width) columns")
        #expect(abs(image.height - page.height) <= 2, "captured \(image.height) of \(page.height) rows")
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: image.width * image.height)
        let wrong = (0..<min(image.height, page.height)).filter { y in
            (0..<image.width).contains { x in
                abs(Int(pixels[y * image.width + x]) - Int(page.pixel(x + SidebarPage.sidebar, y))) > 3
            }
        }.count
        #expect(wrong == 0, "\(wrong) rows differ from the page")
    }

    @Test("a window's rounded bottom corners stay out of every seam and close the capture once")
    func roundedCornersCloseTheCapture() async throws {
        let page = Page(height: 900, startingAt: 0)
        let corner = 10
        // The window's bottom corners show what is behind it: a value the page never has.
        let cornered: () -> CGImage = {
            let frame = page.frame()
            var bytes = [UInt8](repeating: 0, count: 40 * page.viewport)
            let context = CGContext(data: &bytes, width: 40, height: page.viewport, bitsPerComponent: 8, bytesPerRow: 40,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.draw(frame, in: CGRect(x: 0, y: 0, width: 40, height: page.viewport))
            for y in (page.viewport - corner)..<page.viewport {
                for x in [0, 1, 2, 37, 38, 39] { bytes[y * 40 + x] = 255 }
            }
            return Page.image(bytes, rows: page.viewport)
        }
        var updates = 0
        let hooks = ScrollingCaptureSession.Hooks(
            prepare: {}, capture: { _ in cornered() }, update: { _, _ in updates += 1 }, actuator: page)
        let session = ScrollingCaptureSession(region: CGRect(x: 0, y: 0, width: 40, height: 120), hooks: hooks,
                                              cornerRows: CGFloat(corner))
        let run = Task { await session.run() }
        await waitUntil { updates >= 1 && session.readyForCaptureForTesting }
        session.toggleAutoForTesting()
        guard case .completed(let image, _) = await run.value else { Issue.record("auto must finish"); return }
        #expect(page.offset == page.maxOffset)
        #expect(abs(image.height - page.height) <= 2, "captured \(image.height) of \(page.height) rows")
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &rgba, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let seams = (0..<(image.height - corner)).filter { y in
            (0..<image.width).contains { x in rgba[(y * image.width + x) * 4] > 240 }
        }.count
        #expect(seams == 0, "\(seams) rows above the bottom edge carry a corner")
        let last = image.height - 1
        #expect(rgba[(last * image.width) * 4 + 3] == 0, "the bottom-left corner is clear, like the window's")
        #expect(rgba[(last * image.width + 39) * 4 + 3] == 0, "the bottom-right corner is clear, like the window's")
        #expect(rgba[(last * image.width + 20) * 4 + 3] == 255, "the bottom edge between the corners is the page")
    }

    @Test("with a scroll bar it jumps to the top in one step and still stops where the user started")
    func jumpsToTheTop() async throws {
        let page = Page(height: 1_400, startingAt: 500, jumps: true)
        let image = try #require(await autoCapture(page))
        #expect(page.offset == 500)
        #expect(abs(image.height - (500 + page.viewport)) <= 2)
    }

    @Test("started at the top, it captures to the end of the page and finishes by itself")
    func capturesToThePageEnd() async throws {
        let page = Page(height: 900, startingAt: 0)
        let image = try #require(await autoCapture(page))
        #expect(page.offset == page.maxOffset)
        #expect(abs(image.height - page.height) <= 2, "captured \(image.height) of \(page.height) rows")
    }

    @Test("a wheel that runs the other way is caught on the first step and reversed")
    func reversedWheel() async throws {
        let page = Page(height: 1_400, startingAt: 640, reversed: true)
        let image = try #require(await autoCapture(page))
        #expect(page.offset == 640)
        #expect(abs(image.height - (640 + page.viewport)) <= 2)
    }

    @Test("a toolbar that never scrolls does not keep the stitch from starting, and appears once")
    func stickyToolbar() async throws {
        let page = Page(height: 1_400, startingAt: 640, header: 30)
        let image = try #require(await autoCapture(page))
        #expect(page.offset == 640)
        // The toolbar once, then the page from its top down to the bottom of where it started.
        #expect(abs(image.height - (30 + 640 + 90)) <= 3, "captured \(image.height) rows")
    }

    @Test("stopping it leaves the page where it is and the capture open")
    func stopHolds() async throws {
        let page = Page(height: 4_000, startingAt: 0)
        let (session, updates) = session(on: page)
        let run = Task { await session.run() }
        await waitUntil { updates() >= 1 && session.readyForCaptureForTesting }
        session.toggleAutoForTesting()
        await waitUntil { page.steps >= 4 }
        session.toggleAutoForTesting()
        #expect(!session.autoScrollingForTesting)
        let steps = page.steps
        try? await Task.sleep(for: .milliseconds(400))
        #expect(page.steps == steps, "no step after stopping")
        session.cancelForTesting()
        _ = await run.value
    }
}
