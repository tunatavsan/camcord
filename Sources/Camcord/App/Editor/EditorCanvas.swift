import AppKit
import SwiftUI

struct EditorCanvas: NSViewRepresentable {
    let session: EditorSession
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = EditorScrollNSView(); scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.allowsMagnification = true; scroll.minMagnification = 0.02; scroll.maxMagnification = 16
        let canvas = EditorCanvasNSView(); canvas.session = session; scroll.documentView = canvas
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? EditorCanvasNSView else { return }
        canvas.session = session
        canvas.updateSize(viewport: scroll.contentSize)
        canvas.needsDisplay = true
    }
}

@MainActor final class EditorCanvasNSView: NSView {
    weak var session: EditorSession?
    var zoom: CGFloat = 1
    var effectiveZoom: CGFloat { enclosingScrollView?.magnification ?? 1 }
    private var start: CGPoint?
    private var dragPoint: CGPoint?
    private var originalRect: CGRect?
    private var resizing = false
    private var resizeAnchor: CGPoint?
    private var hex = ""
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var imageSize: CGSize {
        if let preview = session?.preview { return CGSize(width: preview.image.width, height: preview.image.height) }
        guard let crop = session?.document?.edits.crop.integral else { return .zero }
        return CGSize(width: crop.width + padding * 2, height: crop.height + padding * 2)
    }
    private var imageOrigin: CGPoint { CGPoint(x: (bounds.width - imageSize.width * zoom) / 2, y: (bounds.height - imageSize.height * zoom) / 2) }
    private var padding: CGFloat {
        guard let bg = session?.document?.edits.background, bg.preset != .none else { return 0 }
        return ceil(bg.padding + bg.frameWidth)
    }
    func sourcePoint(_ view: CGPoint) -> CGPoint? {
        guard let local = EditorGeometry.sourcePoint(view: view, origin: imageOrigin, zoom: zoom), let crop = session?.document?.edits.crop.integral else { return nil }
        return CGPoint(x: local.x - padding + crop.minX, y: local.y - padding + crop.minY)
    }
    func viewRect(_ rect: CGRect) -> CGRect {
        guard let crop = session?.document?.edits.crop.integral else { return .zero }
        return CGRect(x: imageOrigin.x + (rect.minX - crop.minX + padding) * zoom, y: imageOrigin.y + (rect.minY - crop.minY + padding) * zoom, width: rect.width * zoom, height: rect.height * zoom)
    }
    func updateSize(viewport: CGSize) {
        guard let scroll = enclosingScrollView as? EditorScrollNSView else { return }
        scroll.synchronize(viewport: viewport)
    }
    func sizeDocument(viewport: CGSize, magnification: CGFloat) {
        zoom = 1 // NSScrollView alone owns the viewport scale.
        let margin = Theme.Editor.canvasMargin * 2 / magnification
        let size = CGSize(width: max(viewport.width / magnification, imageSize.width + margin),
                          height: max(viewport.height / magnification, imageSize.height + margin))
        if frame.size != size { setFrameSize(size) }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let session else { return }
        if let result = session.preview {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = Theme.Editor.shadowColor.ns
            shadow.shadowBlurRadius = Theme.Editor.shadowRadius / effectiveZoom
            shadow.shadowOffset = CGSize(width: 0, height: -Theme.Editor.shadowY / effectiveZoom)
            shadow.set()
            NSImage(cgImage: result.image, size: imageSize).draw(in: CGRect(origin: imageOrigin, size: CGSize(width: imageSize.width * zoom, height: imageSize.height * zoom)), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            Theme.Palette.hairline.ns.setStroke()
            let edge = NSBezierPath(rect: CGRect(origin: imageOrigin, size: imageSize))
            edge.lineWidth = 1 / ((window?.backingScaleFactor ?? 1) * effectiveZoom)
            edge.stroke()
        }
        for suggestion in session.suggestions {
            let box = NSBezierPath(rect: viewRect(suggestion.rect))
            box.lineWidth = 1 / effectiveZoom
            box.setLineDash([4 / effectiveZoom, 4 / effectiveZoom], count: 2, phase: 0)
            (session.selectedSuggestions.contains(suggestion.id) ? Theme.Palette.ink.ns : Theme.Palette.ink3.ns).setStroke()
            box.stroke()
        }
        if let selected = session.selectedAnnotation {
            let rect: CGRect
            if let originalRect, let start, let dragPoint {
                rect = resizing ? EditorGeometry.drag(from: resizeAnchor ?? originalRect.origin, to: dragPoint, bounds: session.document?.bounds ?? .zero) : originalRect.offsetBy(dx: dragPoint.x - start.x, dy: dragPoint.y - start.y)
            } else { rect = selected.rect }
            drawSelection(viewRect(rect))
        }
        if let start, let dragPoint, originalRect == nil, session.tool != .select, let document = session.document {
            drawSelection(viewRect(EditorGeometry.drag(from: start, to: dragPoint, bounds: document.bounds)))
        }
        if !hex.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [.font: Theme.Font.ns.data, .foregroundColor: Theme.Palette.ink.ns, .backgroundColor: Theme.Palette.surface.ns]
            hex.draw(at: CGPoint(x: visibleRect.minX + Theme.Space.m, y: visibleRect.maxY - 28), withAttributes: attributes)
        }
    }
    private func drawSelection(_ rect: CGRect) {
        Theme.Palette.ink.ns.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 1 / effectiveZoom; path.stroke()
        Theme.Palette.ink.ns.setFill()
        for point in [rect.origin, CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] { NSBezierPath(rect: CGRect(x: point.x - 4 / effectiveZoom, y: point.y - 4 / effectiveZoom, width: 8 / effectiveZoom, height: 8 / effectiveZoom)).fill() }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let session, let point = sourcePoint(convert(event.locationInWindow, from: nil)), let crop = session.document?.edits.crop, crop.contains(point) else { return }
        start = point; dragPoint = point
        if session.tool == .select {
            if let selected = session.selectedAnnotation {
                let rect = viewRect(selected.rect), location = convert(event.locationInWindow, from: nil)
                let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
                if let index = corners.firstIndex(where: { CGRect(x: $0.x - 8 / effectiveZoom, y: $0.y - 8 / effectiveZoom, width: 16 / effectiveZoom, height: 16 / effectiveZoom).contains(location) }) {
                    resizing = true; originalRect = selected.rect
                    let opposite = corners[3 - index]; resizeAnchor = sourcePoint(opposite); return
                }
            }
            session.selectedID = EditorGeometry.hit(point, annotations: session.document?.edits.annotations ?? [], zoom: effectiveZoom)
            originalRect = session.selectedAnnotation?.rect
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { dragPoint = sourcePoint(convert(event.locationInWindow, from: nil)); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        defer { start = nil; dragPoint = nil; originalRect = nil; resizing = false; resizeAnchor = nil; needsDisplay = true }
        guard let session, let start, let end = sourcePoint(convert(event.locationInWindow, from: nil)) else { return }
        if let originalRect {
            if resizing, let bounds = session.document?.bounds { session.setSelectionRect(EditorGeometry.drag(from: resizeAnchor ?? originalRect.origin, to: end, bounds: bounds)) }
            else { session.nudge(dx: end.x - start.x, dy: end.y - start.y) }
        } else { session.add(tool: session.tool, from: start, to: end) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self); addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        guard let session else { return }
        if let point = sourcePoint(convert(event.locationInWindow, from: nil)), session.document?.edits.crop.contains(point) == true {
            session.inspectPixel(at: point); hex = session.pixelHex ?? ""
        } else { hex = "" }
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hex = ""; needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        guard let session else { return }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? "", command = event.modifierFlags.contains(.command), shift = event.modifierFlags.contains(.shift)
        if command && key == "z" { shift ? session.redo() : session.undo(); return }
        if command && shift && key == "c", let hex = session.pixelHex { session.copyHex(hex); return }
        if command && key == "c" { Task { await session.copy() }; return }
        if command && key == "s" { session.chooseExport(); return }
        if event.keyCode == 53 { session.selectedID = nil; session.tool = .select; return }
        if event.keyCode == 51 || event.keyCode == 117 { session.deleteSelected(); return }
        let amount: CGFloat = shift ? 10 : 1
        switch event.keyCode {
        case 123: session.nudge(dx: -amount, dy: 0); return
        case 124: session.nudge(dx: amount, dy: 0); return
        case 125: session.nudge(dx: 0, dy: amount); return
        case 126: session.nudge(dx: 0, dy: -amount); return
        default: break
        }
        if command && (key == "+" || key == "=") { session.changeZoom(by: 1.25); return }
        if command && key == "-" { session.changeZoom(by: 0.8); return }
        if command && key == "0" { session.fitZoom = true; return }
        if command && key == "1" { session.fitZoom = false; session.zoom = 1; return }
        let shortcuts: [String: EditorTool] = ["v": .select, "a": .arrow, "r": .rectangle, "t": .text, "h": .highlight, "n": .step, "b": .blur, "p": .pixelate, "x": .redact, "c": .crop]
        if !command, let tool = shortcuts[key] { session.tool = tool; return }
        super.keyDown(with: event)
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { String(localized: "Screenshot editing canvas") }
    override func accessibilityValue() -> Any? {
        let count = session?.document?.edits.annotations.count ?? 0
        let selected = session?.selectedAnnotation.map { String(localized: $0.kind.title) } ?? String(localized: "None")
        return String(localized: "\(count) annotations, selected \(selected)")
    }
    override func accessibilityHelp() -> String? { String(localized: "Choose a tool, then drag on the image. Arrow keys move the selected annotation.") }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: String(localized: "Move annotation left"), handler: { [weak self] in self?.nudgeSelection(dx: -1, dy: 0) ?? false }),
         NSAccessibilityCustomAction(name: String(localized: "Move annotation right"), handler: { [weak self] in self?.nudgeSelection(dx: 1, dy: 0) ?? false }),
         NSAccessibilityCustomAction(name: String(localized: "Move annotation up"), handler: { [weak self] in self?.nudgeSelection(dx: 0, dy: -1) ?? false }),
         NSAccessibilityCustomAction(name: String(localized: "Move annotation down"), handler: { [weak self] in self?.nudgeSelection(dx: 0, dy: 1) ?? false }),
         NSAccessibilityCustomAction(name: String(localized: "Increase annotation width"), handler: { [weak self] in self?.resizeSelection(dx: 1, dy: 0) ?? false }),
         NSAccessibilityCustomAction(name: String(localized: "Decrease annotation width"), handler: { [weak self] in self?.resizeSelection(dx: -1, dy: 0) ?? false }),
         NSAccessibilityCustomAction(name: String(localized: "Increase annotation height"), handler: { [weak self] in self?.resizeSelection(dx: 0, dy: 1) ?? false }),
         NSAccessibilityCustomAction(name: String(localized: "Decrease annotation height"), handler: { [weak self] in self?.resizeSelection(dx: 0, dy: -1) ?? false }),
         NSAccessibilityCustomAction(name: String(localized: "Select next annotation"), handler: { [weak self] in
             guard let session = self?.session, let annotations = session.document?.edits.annotations, !annotations.isEmpty else { return false }
             let current = annotations.firstIndex { $0.id == session.selectedID } ?? -1
             session.selectedID = annotations[(current + 1) % annotations.count].id; self?.needsDisplay = true; return true
         })]
    }
    private func performSelectionEdit(_ action: (EditorSession) -> Void) -> Bool {
        guard let session, session.selectedAnnotation != nil else { return false }
        let before = session.revision; action(session)
        guard session.revision != before else { return false }
        needsDisplay = true; return true
    }
    private func nudgeSelection(dx: CGFloat, dy: CGFloat) -> Bool {
        performSelectionEdit { $0.nudge(dx: dx, dy: dy) }
    }
    private func resizeSelection(dx: CGFloat, dy: CGFloat) -> Bool {
        performSelectionEdit { session in
            guard let annotation = session.selectedAnnotation else { return }
            var rect = annotation.rect; rect.size.width = max(1, rect.width + dx); rect.size.height = max(1, rect.height + dy)
            session.setSelectionRect(rect)
        }
    }
    override func accessibilityPerformDelete() -> Bool { performSelectionEdit { $0.deleteSelected() } }

}

@MainActor final class EditorScrollNSView: NSScrollView {
    private var synchronizing = false
    private var reportGeneration = 0
    override func layout() {
        super.layout()
        synchronize(viewport: contentSize)
    }
    func synchronize(viewport: CGSize) {
        guard !synchronizing, let canvas = documentView as? EditorCanvasNSView,
              let session = canvas.session, canvas.imageSize.width > 0 else { return }
        synchronizing = true
        defer { synchronizing = false }
        let image = canvas.imageSize
        let fit = max(minMagnification, min(maxMagnification,
            min((viewport.width - Theme.Editor.canvasMargin * 2) / image.width,
                (viewport.height - Theme.Editor.canvasMargin * 2) / image.height)))
        let target = session.fitZoom ? fit : min(maxMagnification, max(minMagnification, session.zoom))
        canvas.sizeDocument(viewport: viewport, magnification: target)
        if abs(magnification - target) > 0.0001 {
            setMagnification(target, centeredAt: CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY))
        }
        if session.fitZoom {
            contentView.scroll(to: CGPoint(x: (canvas.bounds.width - contentView.bounds.width) / 2,
                                          y: (canvas.bounds.height - contentView.bounds.height) / 2))
            reflectScrolledClipView(contentView)
        }
        reportZoom(session)
    }
    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        guard let session = (documentView as? EditorCanvasNSView)?.session else { return }
        session.fitZoom = false
        session.zoom = magnification
        reportZoom(session)
    }
    private func reportZoom(_ session: EditorSession) {
        reportGeneration += 1
        let generation = reportGeneration, value = magnification
        Task { @MainActor [weak self, weak session] in
            await Task.yield()
            guard self?.reportGeneration == generation else { return }
            session?.reportCanvasZoom(value)
        }
    }
}
