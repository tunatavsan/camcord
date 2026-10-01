import AppKit
import SwiftUI

struct EditorCanvas: NSViewRepresentable {
    let session: EditorSession
    var fitTopClearance: CGFloat = 0
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
        (scroll as? EditorScrollNSView)?.fitTopClearance = fitTopClearance
        canvas.updateSize(viewport: scroll.contentSize)
        canvas.refreshLayers()
        canvas.needsDisplay = true
    }
}

@MainActor final class EditorCanvasNSView: NSView {
    weak var session: EditorSession?
    var zoom: CGFloat = 1
    private(set) var fitTopInset: CGFloat = 0
    var effectiveZoom: CGFloat { enclosingScrollView?.magnification ?? 1 }
    let baseLayer = CALayer()
    let canvasShadowLayer = CALayer()
    private let patchesLayer = CALayer()
    private let privacyLayer = CALayer()
    private var privacyRegion: CGRect?
    private var privacyDisplayLink: CADisplayLink?
    private lazy var privacyDisplayProxy = EditorPrivacyDisplayProxy(view:self)
    private var privacyNeedsRefresh = false
    private var lastPrivacyAnnotations: [EditorAnnotation] = []
    private var lastPrivacyGeneration = -1
    private var lastPrivacyScale: CGFloat = 0
    private(set) var privacyDisplayFrames = 0
    var privacyPatchComputations: Int { liveRenderer.privacyPatchComputations }
    private let redactionsLayer = CAShapeLayer()
    private let baseMask = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()
    private let liveRenderer = EditorLiveRenderer()
    private var patches: [String: (rect: CGRect, layer: CALayer)] = [:]
    private var previousAnnotations: [EditorAnnotation] = []
    private var canvasDocumentID: UUID?
    private var baseGeneration = -1
    private var patchScale: CGFloat = 0
    private var start: CGPoint?
    private var original: EditorAnnotation?
    private var handleIndex: Int?
    private(set) var candidateAnnotation: EditorAnnotation?
    private var creatingID = UUID()
    private var cropCandidate: CGRect?
    private var hex = ""
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { session?.editUndoManager }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); wantsLayer = true
        layer?.addSublayer(canvasShadowLayer); layer?.addSublayer(baseLayer); layer?.addSublayer(patchesLayer)
        layer?.addSublayer(privacyLayer); layer?.addSublayer(redactionsLayer); layer?.addSublayer(selectionLayer); layer?.addSublayer(handlesLayer)
        baseLayer.minificationFilter = .trilinear
        baseLayer.magnificationFilter = .nearest
        baseMask.fillRule = .evenOdd; baseMask.fillColor = CGColor(gray: 1, alpha: 1)
        baseLayer.shadowPath = CGPath(rect: CGRect(origin: .zero, size: imageSize), transform: nil)
        selectionLayer.fillColor = nil; handlesLayer.fillColor = CGColor(gray: 1, alpha: 1)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { privacyDisplayLink?.invalidate() }
    var imageSize: CGSize {
        if let base = session?.displayBase { return CGSize(width: base.image.width, height: base.image.height) }
        return session?.document?.edits.crop.size ?? .zero
    }
    var imageOrigin: CGPoint {
        let point = CGPoint(x: (bounds.width - imageSize.width) / 2, y: (bounds.height - imageSize.height + fitTopInset) / 2)
        let backing = convertToBacking(point)
        return convertFromBacking(CGPoint(x: backing.x.rounded(), y: fitTopInset > 0 ? backing.y.rounded(.up) : backing.y.rounded()))
    }
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
        return CGRect(x: imageOrigin.x + (rect.minX - crop.minX + padding), y: imageOrigin.y + (rect.minY - crop.minY + padding), width: rect.width, height: rect.height)
    }
    func updateSize(viewport: CGSize) {
        session?.reportBackingScale(window?.backingScaleFactor ?? 1)
        (enclosingScrollView as? EditorScrollNSView)?.synchronize(viewport: viewport)
    }
    func sizeDocument(viewport: CGSize, magnification: CGFloat, fitTopInset: CGFloat = 0) {
        zoom = 1
        self.fitTopInset = fitTopInset / magnification
        let margin = Theme.Editor.canvasMargin * 2 / magnification
        let size = CGSize(width: max(viewport.width / magnification, imageSize.width + margin), height: max(viewport.height / magnification, imageSize.height + margin + self.fitTopInset))
        if frame.size != size { setFrameSize(size) }; refreshLayers()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateSize(viewport: enclosingScrollView?.contentSize ?? bounds.size); refreshLayers() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateSize(viewport: enclosingScrollView?.contentSize ?? bounds.size); refreshLayers() }
    override func draw(_ dirtyRect: NSRect) {
        refreshLayers()
        if !hex.isEmpty { hex.draw(at: CGPoint(x: visibleRect.minX + Theme.Space.m, y: visibleRect.maxY - 28), withAttributes: [.font: Theme.Font.ns.data, .foregroundColor: Theme.Palette.ink.ns, .backgroundColor: Theme.Palette.surface.ns]) }
    }
    var liveAnnotations: [EditorAnnotation] {
        var values = session?.document?.edits.annotations ?? []
        if let candidateAnnotation {
            if let index = values.firstIndex(where: { $0.id == candidateAnnotation.id }) { values[index] = candidateAnnotation }
            else { values.append(candidateAnnotation) }
        }
        return values
    }
    func refreshLayers(renderPrivacy: Bool = false) {
        guard let session, let document = session.document, let base = session.displayBase else { return }
        if canvasDocumentID != document.id {
            canvasDocumentID = document.id; start = nil; original = nil; handleIndex = nil; candidateAnnotation = nil; cropCandidate = nil
        }
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        baseLayer.frame = CGRect(origin: imageOrigin, size: imageSize)
        baseLayer.contentsScale = window?.backingScaleFactor ?? 1
        baseLayer.minificationFilter = .trilinear
        baseLayer.magnificationFilter = abs(effectiveZoom * baseLayer.contentsScale - 1) < 0.0001 ? .nearest : .linear
        let changedBase = baseGeneration != session.displayBaseGeneration
        if changedBase { baseLayer.contents = base.image; baseGeneration = session.displayBaseGeneration }
        let annotations = liveAnnotations
        let redactions = CGMutablePath()
        let acceptedRedactions = session.displayBaseEdits?.annotations.filter { $0.kind == .redact } ?? []
        if annotations.filter({ $0.kind == .redact }) != acceptedRedactions {
            for item in annotations where item.kind == .redact { redactions.addRect(viewRect(EditorGeometry.pixelRect(item.rect, bounds: document.bounds).intersection(document.edits.crop.integral))) }
        }
        redactionsLayer.path = redactions; redactionsLayer.fillColor = CGColor(gray: 0, alpha: 1)
        liveRenderer.invalidate(baseGeneration: baseGeneration, annotations: annotations, baseEdits: session.displayBaseEdits)
        let scale = min(4, max(0.02, (window?.backingScaleFactor ?? 1) * effectiveZoom))
        let common = zip(previousAnnotations, annotations).prefix { $0 == $1 }.count
        let changed = Array(previousAnnotations.dropFirst(common)) + Array(annotations.dropFirst(common))
        let privacyChanged = previousAnnotations.filter { $0.kind == .redact } != annotations.filter { $0.kind == .redact }
        var dirty = CGRect.null
        for annotation in changed { dirty = dirty.union(EditorLiveRenderer.drawingBounds(annotation, document: document)) }
        let allDirty = changedBase || abs(scale - patchScale) > 0.0001 || privacyChanged || renderPrivacy
        patchScale = scale
        guard let top = sourcePoint(visibleRect.origin), let bottom = sourcePoint(CGPoint(x: visibleRect.maxX, y: visibleRect.maxY)) else { return }
        let viewport = CGRect(x: top.x, y: top.y, width: bottom.x - top.x, height: bottom.y - top.y).intersection(document.edits.crop.integral)
        let tileSize = max(1, floor(256 / scale)), crop = document.edits.crop.integral
        let livePrivacy = liveRenderer.requiresLivePrivacy(annotations) && base.privacySource != nil
        if livePrivacy {
            let privacy = annotations.filter { [.blur,.pixelate,.redact].contains($0.kind) }
            let prior = session.displayBaseEdits?.annotations.filter { [.blur,.pixelate,.redact].contains($0.kind) } ?? []
            let effectBounds = (privacy + prior).reduce(CGRect.null) { $0.union($1.rect) }.intersection(viewport)
            if !effectBounds.isNull, !effectBounds.isEmpty {
                let x = floor((effectBounds.minX-crop.minX)/tileSize)*tileSize+crop.minX
                let y = floor((effectBounds.minY-crop.minY)/tileSize)*tileSize+crop.minY
                let right = ceil((effectBounds.maxX-crop.minX)/tileSize)*tileSize+crop.minX
                let bottom = ceil((effectBounds.maxY-crop.minY)/tileSize)*tileSize+crop.minY
                let region = CGRect(x:x,y:y,width:right-x,height:bottom-y).intersection(crop)
                privacyNeedsRefresh = privacyNeedsRefresh || privacy != lastPrivacyAnnotations || baseGeneration != lastPrivacyGeneration || abs(scale-lastPrivacyScale) > 0.0001 || region != privacyRegion
                if renderPrivacy, privacyNeedsRefresh {
                    do {
                        try liveRenderer.preparePrivacy(region:region,scale:scale,base:base,document:document,annotations:annotations)
                        let image = try liveRenderer.compose(rect:region,scale:scale,base:base,document:document,annotations:annotations)
                        privacyLayer.frame = viewRect(region); privacyLayer.contentsScale = scale
                        privacyLayer.minificationFilter = .trilinear; privacyLayer.magnificationFilter = .nearest
                        privacyLayer.contents = image; privacyRegion = region
                        lastPrivacyAnnotations = privacy; lastPrivacyGeneration = baseGeneration; lastPrivacyScale = scale; privacyNeedsRefresh = false
                    } catch { session.error = error.localizedDescription }
                }
            }
            startPrivacyDisplayLink()
        } else {
            privacyRegion = nil; privacyLayer.contents = nil; privacyNeedsRefresh = false
            privacyDisplayLink?.invalidate(); privacyDisplayLink = nil
        }
        var wanted: Set<String> = []
        if !viewport.isNull && !viewport.isEmpty {
            for y in stride(from: floor((viewport.minY - crop.minY) / tileSize) * tileSize + crop.minY, to: viewport.maxY, by: tileSize) {
                for x in stride(from: floor((viewport.minX - crop.minX) / tileSize) * tileSize + crop.minX, to: viewport.maxX, by: tileSize) {
                    let region = CGRect(x: x, y: y, width: tileSize, height: tileSize).intersection(crop)
                    if privacyRegion?.contains(region) == true { continue }
                    guard annotations.contains(where: { EditorLiveRenderer.drawingBounds($0, document: document).intersects(region) }) else { continue }
                    let key = "\(x),\(y),\(tileSize),\(crop)"; wanted.insert(key)
                    let item = patches[key] ?? (region, CALayer())
                    if patches[key] == nil { patchesLayer.addSublayer(item.layer) }
                    item.layer.frame = viewRect(region); item.layer.contentsScale = scale
                    item.layer.minificationFilter = .trilinear; item.layer.magnificationFilter = .nearest
                    if (patches[key] == nil || allDirty || dirty.intersects(region)) && (!livePrivacy || renderPrivacy) {
                        do { item.layer.contents = try liveRenderer.compose(rect: region, scale: scale, base: base, document: document, annotations: annotations) }
                        catch { session.error = error.localizedDescription; item.layer.contents = nil }
                    }
                    guard item.layer.contents != nil else {
                        item.layer.removeFromSuperlayer(); patches.removeValue(forKey: key); continue
                    }
                    patches[key] = item
                }
            }
        }
        for key in Array(patches.keys) where !wanted.contains(key) { patches.removeValue(forKey: key)?.layer.removeFromSuperlayer() }
        // Replace, rather than source-over, destination-bearing tiles. This also
        // preserves source alpha instead of compositing the same underlay twice.
        let maskPath = CGMutablePath(); maskPath.addRect(CGRect(origin: .zero, size: imageSize))
        for item in patches.values { maskPath.addRect(viewRect(item.rect).offsetBy(dx: -imageOrigin.x, dy: -imageOrigin.y)) }
        if let privacyRegion { maskPath.addRect(viewRect(privacyRegion).offsetBy(dx:-imageOrigin.x,dy:-imageOrigin.y)) }
        baseMask.frame = CGRect(origin: .zero, size: imageSize); baseMask.path = maskPath
        baseLayer.mask = patches.isEmpty && privacyRegion == nil ? nil : baseMask
        // UI shadow is common destination underlay for both retained source and
        // replacement tiles; masking the source must not punch a shadow hole.
        baseLayer.shadowOpacity = 0
        canvasShadowLayer.frame = baseLayer.frame
        canvasShadowLayer.shadowColor = Theme.Editor.shadowColor.ns.cgColor; canvasShadowLayer.shadowOpacity = 1
        canvasShadowLayer.shadowRadius = Theme.Editor.shadowRadius / effectiveZoom
        canvasShadowLayer.shadowOffset = CGSize(width: 0, height: Theme.Editor.shadowY / effectiveZoom)
        canvasShadowLayer.shadowPath = CGPath(rect: CGRect(origin: .zero, size: imageSize), transform: nil)
        previousAnnotations = annotations
        refreshSelection()
    }
    private func startPrivacyDisplayLink() {
        guard privacyDisplayLink == nil, window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { return }
        let link = displayLink(target:privacyDisplayProxy,selector:#selector(EditorPrivacyDisplayProxy.tick(_:)))
        let fps = Float(window?.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum:fps,maximum:fps,preferred:fps)
        link.add(to:.main,forMode:.common); privacyDisplayLink = link
    }
    func renderPrivacyDisplayFrame() {
        guard privacyNeedsRefresh else { return }
        privacyDisplayFrames += 1; refreshLayers(renderPrivacy:true)
    }
    func handlePoints(for annotation: EditorAnnotation) -> [CGPoint] {
        let offset = 6 / effectiveZoom
        if annotation.kind == .arrow {
            let pair = annotation.resolvedArrowEndpoints
            let dx = pair.end.x - pair.start.x, dy = pair.end.y - pair.start.y, length = max(1, hypot(dx, dy))
            return [CGPoint(x: viewRect(CGRect(origin: pair.start, size: .zero)).minX - dx / length * offset, y: viewRect(CGRect(origin: pair.start, size: .zero)).minY - dy / length * offset),
                    CGPoint(x: viewRect(CGRect(origin: pair.end, size: .zero)).minX + dx / length * offset, y: viewRect(CGRect(origin: pair.end, size: .zero)).minY + dy / length * offset)]
        }
        let rect = viewRect(annotation.rect).insetBy(dx: -offset, dy: -offset)
        return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }
    private func refreshSelection() {
        let annotation = candidateAnnotation ?? session?.selectedAnnotation
        let outline = CGMutablePath(), handles = CGMutablePath()
        if let annotation {
            if annotation.kind != .arrow { outline.addRect(viewRect(annotation.rect).insetBy(dx: -6 / effectiveZoom, dy: -6 / effectiveZoom)) }
            for point in handlePoints(for: annotation) { handles.addRect(CGRect(x: point.x - 4 / effectiveZoom, y: point.y - 4 / effectiveZoom, width: 8 / effectiveZoom, height: 8 / effectiveZoom)) }
        }
        if let cropCandidate { outline.addRect(viewRect(cropCandidate)) }
        for suggestion in session?.suggestions ?? [] { outline.addRect(viewRect(suggestion.rect)) }
        selectionLayer.path = outline; selectionLayer.strokeColor = Theme.Palette.ink2.ns.cgColor
        selectionLayer.lineWidth = 1 / effectiveZoom; selectionLayer.lineDashPattern = [4 / effectiveZoom, 4 / effectiveZoom].map { NSNumber(value: Double($0)) }
        handlesLayer.path = handles; handlesLayer.strokeColor = Theme.Palette.ink2.ns.cgColor; handlesLayer.lineWidth = 1 / effectiveZoom
    }
    private func hitHandle(_ location: CGPoint) -> Int? {
        guard let selected = session?.selectedAnnotation else { return nil }
        return handlePoints(for: selected).firstIndex { CGRect(x: $0.x - 8 / effectiveZoom, y: $0.y - 8 / effectiveZoom, width: 16 / effectiveZoom, height: 16 / effectiveZoom).contains(location) }
    }
    private func hitAnnotation(_ point: CGPoint) -> EditorAnnotation? {
        liveAnnotations.reversed().first { annotation in
            if annotation.kind == .arrow {
                let pair = annotation.resolvedArrowEndpoints, dx = pair.end.x - pair.start.x, dy = pair.end.y - pair.start.y
                let t = min(1, max(0, ((point.x - pair.start.x) * dx + (point.y - pair.start.y) * dy) / max(0.0001, dx * dx + dy * dy)))
                let tolerance = max(CGFloat(annotation.style.lineWidth) * 2, 6 / effectiveZoom)
                return hypot(point.x - pair.start.x - t * dx, point.y - pair.start.y - t * dy) <= tolerance
            }
            return annotation.rect.insetBy(dx: -6 / effectiveZoom, dy: -6 / effectiveZoom).contains(point)
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let session, let document = session.document, let point = sourcePoint(convert(event.locationInWindow, from: nil)) else { return }
        let location = convert(event.locationInWindow, from: nil)
        handleIndex = hitHandle(location)
        if handleIndex != nil { original = session.selectedAnnotation; start = point; candidateAnnotation = original; return }
        guard document.edits.crop.contains(point) else { return }
        start = point; creatingID = UUID()
        if let hit = hitAnnotation(point) {
            session.selectedID = hit.id
            if event.clickCount >= 2, hit.kind == .text {
                start = nil; original = nil; candidateAnnotation = nil
                session.showsAnnotationEditor = true; refreshLayers(); return
            }
            original = hit; candidateAnnotation = hit
        }
        else { session.selectedID = nil; original = nil; candidateAnnotation = session.candidate(tool: session.tool, from: point, to: point) }
        refreshLayers()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let session, let document = session.document, let start, let point = sourcePoint(convert(event.locationInWindow, from: nil)) else { return }
        if var original {
            if let handleIndex {
                if original.kind == .arrow {
                    var pair = original.resolvedArrowEndpoints
                    let dx = point.x - start.x, dy = point.y - start.y
                    if handleIndex == 0 { pair.start.x += dx; pair.start.y += dy } else { pair.end.x += dx; pair.end.y += dy }
                    func clamp(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(0, p.x), document.bounds.maxX), y: min(max(0, p.y), document.bounds.maxY)) }
                    original.setArrowEndpoints(start: clamp(pair.start), end: clamp(pair.end))
                } else {
                    var rect = original.rect
                    let dx = point.x - start.x, dy = point.y - start.y
                    let minX = [0, 6, 7].contains(handleIndex) ? rect.minX + dx : rect.minX
                    let maxX = [2, 3, 4].contains(handleIndex) ? rect.maxX + dx : rect.maxX
                    let minY = [0, 1, 2].contains(handleIndex) ? rect.minY + dy : rect.minY
                    let maxY = [4, 5, 6].contains(handleIndex) ? rect.maxY + dy : rect.maxY
                    rect = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: max(1, abs(maxX - minX)), height: max(1, abs(maxY - minY)))
                    original.setRect(rect.intersection(document.bounds))
                }
            } else {
                let rect = original.rect
                let moved = rect.offsetBy(dx: min(max(point.x - start.x, -rect.minX), document.bounds.maxX - rect.maxX), dy: min(max(point.y - start.y, -rect.minY), document.bounds.maxY - rect.maxY))
                original.setRect(moved)
            }
            candidateAnnotation = original
        } else if session.tool == .crop { cropCandidate = EditorGeometry.drag(from: start, to: point, bounds: document.bounds) }
        else { candidateAnnotation = session.candidate(tool: session.tool, from: start, to: point); candidateAnnotation?.id = creatingID }
        refreshLayers(); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let session, let start else { return }
        mouseDragged(with: event)
        if let original, let candidateAnnotation, candidateAnnotation.valid, original != candidateAnnotation {
            session.updateSelected { $0 = candidateAnnotation }
        } else if original == nil, let candidateAnnotation, candidateAnnotation.valid {
            session.edit { $0.annotations.append(candidateAnnotation) }; session.selectedID = candidateAnnotation.id
            if candidateAnnotation.kind == .text { session.showsAnnotationEditor = true }
        } else if let cropCandidate, !cropCandidate.isEmpty { session.edit { $0.crop = cropCandidate.integral } }
        else if original == nil, let point = sourcePoint(convert(event.locationInWindow, from: nil)) { session.add(tool: session.tool, from: start, to: point) }
        cancelGesture()
    }
    func cancelGesture() { start = nil; original = nil; handleIndex = nil; candidateAnnotation = nil; cropCandidate = nil; refreshLayers(); needsDisplay = true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self); addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let index = hitHandle(location), let selected = session?.selectedAnnotation {
            if selected.kind == .arrow { NSCursor.crosshair.set() }
            else {
                let positions: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
                NSCursor.frameResize(position: positions[index], directions: .all).set()
            }
        } else if let point = sourcePoint(location), hitAnnotation(point) != nil { NSCursor.openHand.set() }
        else { NSCursor.arrow.set() }
        if let point = sourcePoint(location) { session?.inspectPixel(at: point); hex = session?.pixelHex ?? "" } else { hex = "" }
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hex = ""; NSCursor.arrow.set(); needsDisplay = true }
    @objc func undo(_ sender: Any?) { cancelGesture(); session?.undo(); refreshLayers() }
    @objc func redo(_ sender: Any?) { cancelGesture(); session?.redo(); refreshLayers() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            event.modifierFlags.contains(.shift) ? redo(nil) : undo(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard let session else { return }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? "", command = event.modifierFlags.contains(.command), shift = event.modifierFlags.contains(.shift)
        if command && key == "z" { shift ? redo(nil) : undo(nil); return }
        if command && shift && key == "c", let hex = session.pixelHex { session.copyHex(hex); return }
        if command && key == "c" { Task { await session.copy() }; return }
        if command && key == "s" { session.chooseExport(); return }
        if event.keyCode == 53 { cancelGesture(); session.selectedID = nil; session.tool = .select; return }
        if event.keyCode == 51 || event.keyCode == 117 { session.deleteSelected(); refreshLayers(); return }
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
        if command && key == "1" { session.fitZoom = false; session.zoom = session.actualPixelZoom; return }
        let shortcuts: [String: EditorTool] = ["v": .select, "a": .arrow, "r": .rectangle, "t": .text, "h": .highlight, "n": .step, "b": .blur, "p": .pixelate, "x": .redact, "c": .crop]
        if !command, let tool = shortcuts[key] { session.tool = tool; return }; super.keyDown(with: event)
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
        [NSAccessibilityCustomAction(name: String(localized: "Move annotation left"), handler: { [weak self] in self?.selectionEdit { $0.nudge(dx: -1, dy: 0) } ?? false }),
         NSAccessibilityCustomAction(name: String(localized: "Move annotation right"), handler: { [weak self] in self?.selectionEdit { $0.nudge(dx: 1, dy: 0) } ?? false }),
         NSAccessibilityCustomAction(name: String(localized: "Move annotation up"), handler: { [weak self] in self?.selectionEdit { $0.nudge(dx: 0, dy: -1) } ?? false }),
         NSAccessibilityCustomAction(name: String(localized: "Move annotation down"), handler: { [weak self] in self?.selectionEdit { $0.nudge(dx: 0, dy: 1) } ?? false }),
         NSAccessibilityCustomAction(name: String(localized: "Increase annotation width"), handler: { [weak self] in self?.resizeSelection(dx: 1, dy: 0) ?? false }),
         NSAccessibilityCustomAction(name: String(localized: "Decrease annotation width"), handler: { [weak self] in self?.resizeSelection(dx: -1, dy: 0) ?? false }),
         NSAccessibilityCustomAction(name: String(localized: "Increase annotation height"), handler: { [weak self] in self?.resizeSelection(dx: 0, dy: 1) ?? false }),
         NSAccessibilityCustomAction(name: String(localized: "Decrease annotation height"), handler: { [weak self] in self?.resizeSelection(dx: 0, dy: -1) ?? false }),
         NSAccessibilityCustomAction(name: String(localized: "Select next annotation"), handler: { [weak self] in
             guard let session = self?.session, let values = session.document?.edits.annotations, !values.isEmpty else { return false }
             let current = values.firstIndex { $0.id == session.selectedID } ?? -1; session.selectedID = values[(current + 1) % values.count].id; self?.refreshLayers(); return true
         })]
    }
    private func selectionEdit(_ action: (EditorSession) -> Void) -> Bool {
        guard let session, session.selectedAnnotation != nil else { return false }; let before = session.revision; action(session); refreshLayers(); return session.revision != before
    }
    private func resizeSelection(dx: CGFloat, dy: CGFloat) -> Bool {
        selectionEdit { session in guard let item = session.selectedAnnotation else { return }; var rect = item.rect; rect.size.width = max(1, rect.width + dx); rect.size.height = max(1, rect.height + dy); session.setSelectionRect(rect) }
    }
    override func accessibilityPerformDelete() -> Bool { selectionEdit { $0.deleteSelected() } }
}

@MainActor private final class EditorPrivacyDisplayProxy: NSObject {
    weak var view: EditorCanvasNSView?
    init(view:EditorCanvasNSView) { self.view = view }
    @objc func tick(_ link:CADisplayLink) { view?.renderPrivacyDisplayFrame() }
}

@MainActor final class EditorScrollNSView: NSScrollView {
    var fitTopClearance: CGFloat = 0
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
        let topInset = session.fitZoom ? max(0, fitTopClearance - Theme.Editor.canvasMargin) : 0
        let fit = max(minMagnification, min(maxMagnification,
            min((viewport.width - Theme.Editor.canvasMargin * 2) / image.width,
                (viewport.height - Theme.Editor.canvasMargin * 2 - topInset) / image.height)))
        let target = session.fitZoom ? fit : min(maxMagnification, max(minMagnification, session.zoom))
        canvas.sizeDocument(viewport: viewport, magnification: target, fitTopInset: topInset)
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
