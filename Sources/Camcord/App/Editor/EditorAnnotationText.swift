import AppKit
import SwiftUI

/// This Editor-owned text view records document snapshots, not a second native
/// text-only stack. Other fields and their field editors retain AppKit behavior.
struct EditorAnnotationText: NSViewRepresentable {
    let session: EditorSession
    func makeNSView(context: Context) -> EditorAnnotationTextView {
        let view = EditorAnnotationTextView(frame: .zero)
        view.session = session; view.isRichText = false; view.allowsUndo = false
        view.string = session.selectedAnnotation?.text ?? ""
        view.font = Theme.Font.ns.body; view.textColor = Theme.Palette.ink.ns
        view.backgroundColor = Theme.Palette.field.ns
        view.setAccessibilityLabel(String(localized: "Annotation text"))
        view.delegate = view
        return view
    }
    func updateNSView(_ view: EditorAnnotationTextView, context: Context) {
        view.session = session
        let value = session.selectedAnnotation?.text ?? ""
        if view.string != value { view.string = value }
    }
}
@MainActor final class EditorAnnotationTextView: NSTextView, NSTextViewDelegate {
    weak var session: EditorSession?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, session?.showsAnnotationEditor == true {
            window.makeFirstResponder(self)
            if string == String(localized:"Text") { selectAll(nil) }
        }
    }
    override var undoManager: UndoManager? { session?.editUndoManager }
    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        // AppKit's text coalescer still attempts registration through an
        // overridden manager even when allowsUndo is false. Disable only this
        // native text registration; didChangeText then records the document edit.
        let manager = undoManager
        manager?.disableUndoRegistration()
        defer { manager?.enableUndoRegistration() }
        return super.shouldChangeText(inRanges:affectedRanges,replacementStrings:replacementStrings)
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder(); if result { session?.beginContinuousEdit() }; return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder(); if result { session?.endContinuousEdit() }; return result
    }
    func textDidChange(_ notification: Notification) {
        guard session?.selectedAnnotation?.kind == .text else { return }
        guard string.utf8.count <= 16_384 else { string = session?.selectedAnnotation?.text ?? ""; return }
        session?.updateSelected { $0.text = string }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            event.modifierFlags.contains(.shift) ? redo(nil) : undo(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { session?.showsAnnotationEditor = false; return }
        super.keyDown(with:event)
    }
    @objc func undo(_ sender: Any?) { session?.endContinuousEdit(); session?.undo(); string = session?.selectedAnnotation?.text ?? ""; session?.beginContinuousEdit() }
    @objc func redo(_ sender: Any?) { session?.endContinuousEdit(); session?.redo(); string = session?.selectedAnnotation?.text ?? ""; session?.beginContinuousEdit() }
}
