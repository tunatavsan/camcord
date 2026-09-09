import CoreGraphics
import Testing

@testable import Camcord

@Suite("TextLayout")
struct TextLayoutTests {

    /// A line whose box width defaults to 10pt per character (so the median glyph width is a
    /// tidy 10 and indentation/gap math is easy to reason about).
    private func line(_ text: String, x: CGFloat = 0, y: CGFloat, w: CGFloat? = nil, h: CGFloat = 20) -> TextLine {
        TextLine(text: text, rect: CGRect(x: x, y: y, width: w ?? CGFloat(text.count) * 10, height: h))
    }

    @Test("assembles top-to-bottom regardless of the input order")
    func readingOrder() {
        let lines = [line("second", y: 30), line("first", y: 0), line("third", y: 60)]
        #expect(TextLayout.assemble(lines) == "first\nsecond\nthird")
    }

    @Test("a large vertical gap becomes a blank line (paragraph break)")
    func paragraphBreak() {
        let lines = [line("para1", y: 0), line("para2", y: 60)]
        #expect(TextLayout.assemble(lines) == "para1\n\npara2")
    }

    @Test("indentation is preserved from the horizontal offset (code keeps its shape)")
    func indentation() {
        let lines = [line("def foo():", x: 0, y: 0), line("return 1", x: 40, y: 25)]
        #expect(TextLayout.assemble(lines) == "def foo():\n    return 1")
    }

    @Test("minor left-edge jitter does NOT add phantom indentation")
    func noPhantomIndent() {
        // Second line is only ~1 glyph off — below the 2-char indent threshold.
        let lines = [line("first line", x: 0, y: 0), line("second line", x: 8, y: 25)]
        #expect(TextLayout.assemble(lines) == "first line\nsecond line")
    }

    @Test("a sidebar does not indent the next block and emitted indentation is capped")
    func sidebarIndentationUsesContiguousBlock() {
        let lines = [line("Sidebar", y: 0), line("func capture() {", x: 300, y: 25),
                     line("return image", x: 340, y: 50), line("next()", x: 700, y: 110),
                     line("tail", x: 800, y: 135)]
        #expect(TextLayout.assemble(lines) == "Sidebar\nfunc capture() {\n    return image\n\nnext()\n        tail")
    }

    @Test("side-by-side observations on one row are spaced by their gap (columns/tables)")
    func columnsSpacing() {
        let lines = [line("Name", x: 0, y: 0, w: 40), line("Value", x: 100, y: 0, w: 40)]
        #expect(TextLayout.assemble(lines) == "Name      Value")   // 60pt gap ÷ 10 = 6 spaces
    }

    @Test("strips: one for a normal image, several covering a tall one")
    func stripsTiling() {
        #expect(TextLayout.strips(imageWidth: 1200, imageHeight: 800).count == 1)
        let tall = TextLayout.strips(imageWidth: 800, imageHeight: 5000)
        #expect(tall.count > 1)
        #expect(tall.first?.minY == 0)
        #expect(tall.last.map { $0.maxY } == 5000)
        // Consecutive strips overlap so nothing at a boundary is lost.
        #expect(tall[1].minY < tall[0].maxY)
    }

    @Test("dedupOverlaps drops a line repeated at a near-identical position")
    func dedup() {
        let a = TextLine(text: "hello", rect: CGRect(x: 0, y: 100, width: 50, height: 20))
        let b = TextLine(text: "hello", rect: CGRect(x: 0, y: 105, width: 50, height: 20))
        let c = TextLine(text: "world", rect: CGRect(x: 0, y: 200, width: 50, height: 20))
        let out = TextLayout.dedupOverlaps([a, b, c])
        #expect(out.map(\.text) == ["hello", "world"])
    }
}
