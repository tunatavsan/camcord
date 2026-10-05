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

    @Test("started mid-page, it climbs to the top and captures down to exactly where the owner started")
    func capturesFromTopToTheStart() async throws {
        let page = Page(height: 1_400, startingAt: 640)
        let image = try #require(await autoCapture(page))
        #expect(page.offset == 640, "the page ends where the owner left it, not at \(page.offset)")
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

    @Test("with a scroll bar it jumps to the top in one step and still stops where the owner started")
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
