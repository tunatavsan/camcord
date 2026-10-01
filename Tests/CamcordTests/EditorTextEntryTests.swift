import AppKit
import CoreText
import Testing
@testable import Camcord

@Suite("Text entry sizing") @MainActor
struct EditorTextEntryTests {
    private func session(fontSize: Double = 93) throws -> EditorSession {
        let context = try EditorRenderer.context(width: 960, height: 600)
        let image = try #require(context.makeImage())
        let session = EditorSession()
        session.style.fontSize = fontSize
        session.open(CapturedScreenshot(id: UUID(), image: image, pointSize: CGSize(width: 480, height: 300), kind: .screenshot, saveToDiskRequested: false))
        return session
    }

    /// Ask CoreText which characters the actual renderer's text frame can paint.
    private func visibleCharacters(_ annotation: EditorAnnotation) -> Int {
        let font = NSFont.systemFont(ofSize: annotation.style.fontSize, weight: .semibold)
        let string = NSAttributedString(string: annotation.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let setter = CTFramesetterCreateWithAttributedString(string)
        let padding = annotation.style.textBackground ? CGSize(width: 16, height: 8) : .zero
        let size = CGSize(width: annotation.rect.width / 2 - padding.width, height: annotation.rect.height / 2 - padding.height)
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), nil)
        return CTFrameGetVisibleStringRange(frame).length
    }

    @Test("Click-created Review fits the chosen font at double density", arguments: [28.0, 93.0])
    func reviewFits(fontSize: Double) throws {
        let session = try session(fontSize: fontSize)
        defer { session.stop() }
        let origin = CGPoint(x: 100, y: 100)
        session.add(tool: .text, from: origin, to: origin)
        let original = try #require(session.selectedAnnotation)
        session.updateSelectedText("Review")
        let edited = try #require(session.selectedAnnotation)
        #expect(edited.rect.origin == origin)
        #expect(edited.style.fontSize == fontSize)
        #expect(session.style.fontSize == fontSize)
        #expect(edited.rect.width >= original.rect.width)
        #expect(edited.rect.height >= original.rect.height)
        #expect(visibleCharacters(edited) == edited.text.utf16.count)
        if fontSize == 93 { #expect(edited.rect.width > 220) }
    }

    @Test("Growth wraps at the source edge, preserves its origin and caps its height")
    func sourceBounds() throws {
        let session = try session(fontSize: 28)
        defer { session.stop() }
        let origin = CGPoint(x: 700, y: 100)
        session.add(tool: .text, from: origin, to: origin)
        session.updateSelectedText("Review this carefully")
        let wrapped = try #require(session.selectedAnnotation)
        #expect(wrapped.rect.origin == origin)
        #expect(wrapped.rect.maxX == 960)
        #expect(wrapped.rect.height > 80)
        #expect(visibleCharacters(wrapped) == wrapped.text.utf16.count)
        session.updateSelectedText(String(repeating: "Review this carefully\n", count: 30))
        let limited = try #require(session.selectedAnnotation)
        #expect(limited.rect.origin == origin)
        #expect(limited.rect.maxX == 960)
        #expect(limited.rect.maxY == 600)
    }

    @Test("Existing and drag-created boxes keep their deliberate wrapping geometry")
    func fixedBoxes() throws {
        let session = try session()
        defer { session.stop() }
        let existing = EditorAnnotation(kind: .text, rect: CGRect(x: 80, y: 80, width: 140, height: 300), text: "Old")
        session.commitAnnotation(existing)
        session.updateSelectedText("Review")
        #expect(session.selectedAnnotation?.rect == existing.rect)
        session.add(tool: .text, from: CGPoint(x: 350, y: 100), to: CGPoint(x: 500, y: 400))
        let dragged = try #require(session.selectedAnnotation)
        session.updateSelectedText("Review")
        #expect(session.selectedAnnotation?.rect == dragged.rect)
    }

    @Test("Moving keeps automatic sizing while a deliberate resize switches to fixed wrapping")
    func moveAndResize() throws {
        let session = try session(fontSize: 28)
        defer { session.stop() }
        session.add(tool: .text, from: CGPoint(x: 80, y: 80), to: CGPoint(x: 80, y: 80))
        session.nudge(dx: 10, dy: 15)
        session.updateSelectedText("Review this carefully")
        let moved = try #require(session.selectedAnnotation)
        #expect(moved.rect.origin == CGPoint(x: 90, y: 95))
        #expect(moved.rect.width > 220)
        let manual = CGRect(x: 90, y: 95, width: 150, height: 300)
        session.setSelectionRect(manual)
        session.updateSelectedText("Review this carefully again")
        #expect(session.selectedAnnotation?.rect == manual)
        session.undo()
        session.undo()
        #expect(session.selectedAnnotation == moved)
        session.updateSelectedText("Review this carefully with extra words")
        #expect(session.selectedAnnotation!.rect.width > moved.rect.width)
    }

    @Test("One continuous input undo restores text and geometry exactly; redo restores the full final entry")
    func continuousUndoRedo() throws {
        let session = try session()
        defer { session.stop() }
        session.add(tool: .text, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100))
        let original = try #require(session.selectedAnnotation)
        let input = EditorAnnotationTextView(frame: .zero)
        input.session = session
        session.beginContinuousEdit()
        for text in ["R", "Re", "Rev", "Revi", "Revie", "Review"] {
            input.string = text
            input.textDidChange(Notification(name: NSText.didChangeNotification, object: input))
        }
        session.endContinuousEdit()
        let final = try #require(session.selectedAnnotation)
        #expect(visibleCharacters(final) == 6)
        input.undo(nil)
        #expect(session.selectedAnnotation == original)
        #expect(input.string == original.text)
        input.redo(nil)
        #expect(session.selectedAnnotation == final)
        #expect(input.string == final.text)
        session.endContinuousEdit()
        session.undo()
        session.undo()
        #expect(session.document?.edits.annotations.isEmpty == true)
        session.redo()
        #expect(session.selectedAnnotation == original)
        session.updateSelectedText("Review again")
        #expect(session.selectedAnnotation!.rect.width > original.rect.width)
    }

    @Test("Changing a click-created entry's font grows its box in the same undo action")
    func styleGrowth() throws {
        let session = try session(fontSize: 28)
        defer { session.stop() }
        session.add(tool: .text, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100))
        session.updateSelectedText("Review")
        let original = try #require(session.selectedAnnotation)
        session.updateSelected { $0.style.fontSize = 93; $0.style.textBackground = true }
        let large = try #require(session.selectedAnnotation)
        #expect(large.rect.origin == original.rect.origin)
        #expect(large.rect.width > original.rect.width)
        #expect(large.rect.height > original.rect.height)
        #expect(visibleCharacters(large) == 6)
        session.undo()
        #expect(session.selectedAnnotation == original)
        session.redo()
        #expect(session.selectedAnnotation == large)
        let manual = CGRect(x: 100, y: 100, width: 140, height: 300)
        session.setSelectionRect(manual)
        session.updateSelected { $0.style.fontSize = 110 }
        #expect(session.selectedAnnotation?.rect == manual)
    }
}
