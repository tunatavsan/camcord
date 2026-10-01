import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers
import CoreText

@MainActor @Observable
final class EditorSession {
    @MainActor struct ClipboardOperations {
        var copyPNG: @MainActor (CGImage, CGSize, NSPasteboard, @escaping @MainActor () -> Bool) async -> Bool = { image, size, board, guardPublication in
            await EditorClipboardPublisher.copyPNG(image, pointSize: size, to: board, shouldPublish: guardPublication)
        }
    }
    private(set) var document: EditorDocument?
    private(set) var revision = 0
    private(set) var preview: EditorRendered?
    private(set) var previewRevision = -1
    private(set) var isRendering = false
    private(set) var isLoading = false
    private(set) var isFindingText = false
    private(set) var hasScannedSensitiveText = false
    private(set) var isExporting = false
    private(set) var suggestions: [EditorSensitiveSuggestion] = []
    var selectedSuggestions: Set<UUID> = []
    private(set) var pixelHex: String?
    private(set) var pixelLocation: CGPoint?
    var selectedID: UUID? { didSet { if selectedID != oldValue { showsAnnotationEditor = false } } }
    var showsAnnotationEditor = false
    var tool = EditorTool.select {
        didSet {
            if tool != oldValue { showsAnnotationEditor = false }
            if !hasChosenLineWidth && (tool == .arrow || tool == .rectangle) {
                style.lineWidth = tool == .arrow ? 6 : 4
            }
            if tool == .highlight && oldValue != .highlight && !hasChosenColor && style.color == .ink {
                style.color = EditorRenderer.markerColor
            }
        }
    }
    var style = EditorStyle()
    private var hasChosenColor = false
    private var hasChosenLineWidth = false
    private(set) var canvasZoom: CGFloat = 1
    var zoom: CGFloat = 1
    var fitZoom = true
    var showsBackgroundInspector = false
    var error: String?
    var pendingCapture: CapturedScreenshot?
    private(set) var pendingURL: URL?
    let editUndoManager = UndoManager()
    private var snapshotCosts: [Int] = []
    private var continuousDepth = 0
    private var continuousRecorded = false
    @ObservationIgnored private var growingTextIDs: Set<UUID> = []
    func beginContinuousEdit() { if continuousDepth == 0 { continuousRecorded = false }; continuousDepth += 1 }
    func endContinuousEdit() { continuousDepth = max(0, continuousDepth - 1) }
    private(set) var displayBase: EditorDisplayBase?
    private(set) var displayBaseEdits: EditorEdits?
    @ObservationIgnored private let pixelRenderer = EditorLiveRenderer()
    private(set) var displayBaseGeneration = 0
    private var requestedDisplayKey: EditorEdits?
    private var acceptedDisplayKey: EditorEdits?
    private(set) var displayRasterRequests = 0
    private(set) var backingScale: CGFloat = 1
    var actualPixelZoom: CGFloat { 1 / backingScale }
    var displayedZoomPercent: Int { Int((canvasZoom * backingScale * 100).rounded()) }
    func reportBackingScale(_ value: CGFloat) {
        guard value > 0, value.isFinite else { return }
        let wasActual = abs(zoom - actualPixelZoom) < 0.0001
        backingScale = value
        if !fitZoom && wasActual { zoom = actualPixelZoom }
    }
    private var cleanEdits: EditorEdits?
    private var loadGeneration = 0
    private var nextStepNumber = 1
    private var renderTask: Task<Void, Never>?
    private var ocrTask: Task<Void, Never>?
    private let worker: EditorWorker
    private let clipboard: ClipboardOperations
    private var localClipboardRequests = LatestRequestGate()
    @ObservationIgnored var claimClipboardPublication: (@MainActor () -> (@MainActor () -> Bool))?
    let temporaryExports: EditorTemporaryExports
    let pins: PinnedScreenshotController
    private let defaults: UserDefaults?
    private var rememberedBackground = EditorBackground()
    @ObservationIgnored var onDocumentAccepted: (@MainActor () -> Void)?
    var canUndo: Bool { _ = revision; return editUndoManager.canUndo }
    var canRedo: Bool { _ = revision; return editUndoManager.canRedo }
    var hasUnsavedEdits: Bool { document.map { $0.edits != cleanEdits } ?? false }
    var selectedAnnotation: EditorAnnotation? { document?.edits.annotations.first { $0.id == selectedID } }
    var nextStep: Int { nextStepNumber }
    init(defaults: UserDefaults? = nil, worker: EditorWorker = EditorWorker(), temporaryExports: EditorTemporaryExports = EditorTemporaryExports(), pins: PinnedScreenshotController = PinnedScreenshotController(), clipboard: ClipboardOperations = ClipboardOperations()) {
        editUndoManager.groupsByEvent = false; editUndoManager.levelsOfUndo = 60
        self.defaults = defaults; self.worker = worker; self.temporaryExports = temporaryExports; self.pins = pins; self.clipboard = clipboard
        pins.claimClipboardPublication = { [weak self] in self?.claimPublication() ?? { false } }
        if let data = defaults?.data(forKey: "editor.backgroundStyle"), let value = try? JSONDecoder().decode(EditorBackground.self, from: data), value.valid { rememberedBackground = value }
        if let data = defaults?.data(forKey: "editor.toolStyle"), let value = try? JSONDecoder().decode(EditorStyle.self, from: data), value.valid { style = value; hasChosenColor = true; hasChosenLineWidth = true }
    }
    @discardableResult func open(_ capture: CapturedScreenshot) -> Bool {
        loadGeneration += 1; isLoading = false
        guard capture.id != document?.id else { return true }
        if hasUnsavedEdits { pendingCapture = capture; pendingURL = nil; error = EditorError.unsaved.localizedDescription; return false }
        do { accept(try EditorDocument(id: capture.id, source: capture.image, pointSize: capture.pointSize)); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    enum OpenOutcome: Equatable { case accepted, requiresDecision, superseded, failed(String) }
    @discardableResult func open(url: URL) async -> Bool { await requestOpen(url: url) == .accepted }
    func requestOpen(url: URL, onlyIfEmpty: Bool = false) async -> OpenOutcome {
        if onlyIfEmpty && document != nil { return .superseded }
        loadGeneration += 1; let generation = loadGeneration
        if hasUnsavedEdits { isLoading = false; pendingURL = url; pendingCapture = nil; error = EditorError.unsaved.localizedDescription; return .requiresDecision }
        let startingRevision = revision; isLoading = true
        do {
            let value = try await worker.decode(url)
            guard generation == loadGeneration else { return .superseded }
            try Task.checkCancellation()
            if onlyIfEmpty && document != nil { isLoading = false; return .superseded }
            if revision != startingRevision && hasUnsavedEdits {
                pendingURL = url; self.error = EditorError.unsaved.localizedDescription; isLoading = false; return .requiresDecision
            }
            accept(value); return .accepted
        } catch {
            guard generation == loadGeneration else { return .superseded }
            isLoading = false
            if error is CancellationError || Task.isCancelled { return .superseded }
            self.error = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }
    func discardAndOpenPending() async {
        await discardAndOpen(capture: pendingCapture, url: pendingURL)
    }
    func discardAndOpen(capture: CapturedScreenshot?, url: URL?) async {
        guard capture != nil || url != nil else { return }
        let previousClean = cleanEdits, previousID = document?.id
        cleanEdits = document?.edits; pendingCapture = nil; pendingURL = nil
        let accepted: Bool
        if let capture { accepted = open(capture) }
        else if let url { accepted = await open(url: url) }
        else { return }
        if !accepted, document?.id == previousID { cleanEdits = previousClean }
    }
    func cancelPending() { pendingCapture = nil; pendingURL = nil; error = nil }
    private func accept(_ original: EditorDocument) {
        var value = original; value.edits.background = rememberedBackground
        loadGeneration += 1; isLoading = false; document = value; cleanEdits = value.edits; nextStepNumber = 1
        editUndoManager.removeAllActions(withTarget: self); snapshotCosts = []; growingTextIDs = []; selectedID = nil; pendingCapture = nil; pendingURL = nil; fitZoom = true; error = nil
        preview = nil; previewRevision = -1
        displayBase = EditorDisplayBase(image: value.source, pointSize: value.pointSize, underlay: value.source)
        displayBaseEdits = EditorEdits(crop: value.bounds)
        displayBaseGeneration += 1; requestedDisplayKey = nil; acceptedDisplayKey = nil
        changed(); onDocumentAccepted?()
    }
    func edit(_ mutation: (inout EditorEdits) -> Void) {
        guard var value = document else { return }
        let previous = value.edits; mutation(&value.edits)
        guard value.edits.valid, value.edits != previous else { return }
        recordSnapshot(previous)
        if value.edits.background != previous.background {
            rememberedBackground = value.edits.background
            if let data = try? JSONEncoder().encode(rememberedBackground) { defaults?.set(data, forKey: "editor.backgroundStyle") }
        }
        document = value; nextStepNumber = min(9999, max(nextStepNumber, (value.edits.annotations.filter { $0.kind == .step }.map(\.stepNumber).max() ?? 0) + 1)); changed()
    }
    private func recordSnapshot(_ edits: EditorEdits) {
        if continuousDepth > 0 && !editUndoManager.isUndoing && !editUndoManager.isRedoing {
            if continuousRecorded { return }; continuousRecorded = true
        }
        let cost = edits.annotations.reduce(0) { $0 + 256 + $1.text.utf8.count }
        if !editUndoManager.isUndoing && !editUndoManager.isRedoing {
            snapshotCosts.append(cost)
            if snapshotCosts.count > 60 { snapshotCosts.removeFirst() }
            let maximum = max(1, snapshotCosts.max() ?? 1)
            editUndoManager.levelsOfUndo = min(60, max(1, 16_000_000 / maximum))
            editUndoManager.beginUndoGrouping()
        }
        let growingIDs = growingTextIDs
        editUndoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restoreSnapshot(edits, growingIDs: growingIDs) }
        }
        if !editUndoManager.isUndoing && !editUndoManager.isRedoing { editUndoManager.endUndoGrouping() }
    }
    private func restoreSnapshot(_ edits: EditorEdits, growingIDs: Set<UUID>) {
        guard let current = document?.edits else { return }
        recordSnapshot(current); document?.edits = edits; growingTextIDs = growingIDs; continuousRecorded = false
        if let selectedID, !edits.annotations.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        if selectedID == nil { selectedID = edits.annotations.last?.id }
        changed()
    }
    func undo() { editUndoManager.undo() }
    func redo() { editUndoManager.redo() }
    private func displayKey(_ edits: EditorEdits) -> EditorEdits {
        var key = edits; key.annotations = edits.annotations.filter { [.redact, .blur, .pixelate].contains($0.kind) }; return key
    }
    private func changed() {
        revision += 1; pixelHex = nil; pixelLocation = nil; hasScannedSensitiveText = false; suggestions = []; selectedSuggestions = []; ocrTask?.cancel(); isFindingText = false
        schedulePreview()
    }
    private func schedulePreview() {
        guard let document else { return }
        let key = displayKey(document.edits)
        if acceptedDisplayKey == key { renderTask?.cancel(); requestedDisplayKey = key; isRendering = false; return }
        guard requestedDisplayKey != key || !isRendering else { return }
        renderTask?.cancel(); requestedDisplayKey = key; displayRasterRequests += 1
        isRendering = true
        renderTask = Task { [weak self, worker] in
            do {
                let result = try await worker.displayBase(document)
                guard let self, !Task.isCancelled, self.document?.id == document.id,
                      self.document.map({ self.displayKey($0.edits) }) == key else { return }
                self.displayBase = result; self.displayBaseEdits = key; self.displayBaseGeneration += 1; self.acceptedDisplayKey = key; self.isRendering = false
                if self.document?.edits.annotations.isEmpty == true { self.preview = EditorRendered(image: result.image, pointSize: result.pointSize); self.previewRevision = self.revision }
            } catch {
                guard let self, !Task.isCancelled, self.requestedDisplayKey == key else { return }
                self.error = error.localizedDescription; self.isRendering = false
            }
        }
    }
    func candidate(tool: EditorTool, from: CGPoint, to: CGPoint) -> EditorAnnotation? {
        guard let document, tool != .select, tool != .crop else { return nil }
        func clamped(_ point: CGPoint) -> CGPoint { CGPoint(x: min(max(point.x, 0), document.bounds.maxX), y: min(max(point.y, 0), document.bounds.maxY)) }
        let start = clamped(from), end = clamped(to)
        var rect = EditorGeometry.drag(from: start, to: end, bounds: document.bounds)
        if tool == .arrow {
            guard hypot(start.x - end.x, start.y - end.y) > 0 else { return nil }
        } else if rect.width < 1 || rect.height < 1 {
            if tool == .text || tool == .step { rect = CGRect(x: start.x, y: start.y, width: tool == .text ? 220 : 48, height: 48).intersection(document.bounds) }
            else { return nil }
        }
        return EditorAnnotation(kind: tool, rect: rect, style: style, text: tool == .text ? String(localized: "Text") : "", stepNumber: nextStep, arrowStart: tool == .arrow ? start : nil, arrowEnd: tool == .arrow ? end : nil)
    }
    func add(tool: EditorTool, from: CGPoint, to: CGPoint) {
        guard let document, tool != .select else { return }
        if tool == .crop {
            let rect = EditorGeometry.drag(from: from, to: to, bounds: document.bounds)
            if !rect.isEmpty { edit { $0.crop = rect.integral.intersection(document.bounds) } }; return
        }
        guard let annotation = candidate(tool: tool, from: from, to: to) else { return }
        let drag = EditorGeometry.drag(from: from, to: to, bounds: document.bounds)
        commitAnnotation(annotation, growsText: tool == .text && (drag.width < 1 || drag.height < 1))
    }
    func commitAnnotation(_ annotation: EditorAnnotation, growsText: Bool = false) {
        guard let document else { return }
        var value = annotation
        if growsText && value.kind == .text { value.rect = fittedTextRect(value, document: document) }
        edit { $0.annotations.append(value) }
        guard self.document?.edits.annotations.contains(where: { $0.id == value.id }) == true else { return }
        if growsText && value.kind == .text { growingTextIDs.insert(value.id) }
        selectedID = value.id
    }
    func updateSelected(_ mutation: (inout EditorAnnotation) -> Void) {
        guard let selectedID else { return }
        let previous = selectedAnnotation, document = document
        let grows = growingTextIDs.contains(selectedID)
        var manuallyResized = false
        edit { edits in
            guard let index = edits.annotations.firstIndex(where: { $0.id == selectedID }) else { return }
            mutation(&edits.annotations[index])
            manuallyResized = edits.annotations[index].rect.size != previous?.rect.size
            if grows, !manuallyResized, let document, edits.annotations[index].kind == .text,
               edits.annotations[index].style != previous?.style || edits.annotations[index].text != previous?.text {
                edits.annotations[index].rect = fittedTextRect(edits.annotations[index], document: document)
            }
        }
        if manuallyResized && selectedAnnotation?.rect.size != previous?.rect.size { growingTextIDs.remove(selectedID) }
    }
    /// Text and its automatic box growth belong to the same document undo entry.
    func updateSelectedText(_ text: String) {
        guard let selectedID, let document, selectedAnnotation?.kind == .text, text.utf8.count <= 16_384 else { return }
        let grows = growingTextIDs.contains(selectedID)
        edit { edits in
            guard let index = edits.annotations.firstIndex(where: { $0.id == selectedID }) else { return }
            edits.annotations[index].text = text
            if grows { edits.annotations[index].rect = fittedTextRect(edits.annotations[index], document: document) }
        }
    }
    /// Click-created text grows right and down until the source edge requires wrapping.
    /// Explicitly dragged or resized boxes retain the user's chosen geometry.
    private func fittedTextRect(_ annotation: EditorAnnotation, document: EditorDocument) -> CGRect {
        guard annotation.kind == .text, annotation.style.valid, annotation.text.utf8.count <= 16_384 else { return annotation.rect }
        let scale = CGSize(width: CGFloat(document.source.width) / document.pointSize.width,
                           height: CGFloat(document.source.height) / document.pointSize.height)
        let available = CGSize(width: max(0, document.bounds.maxX - annotation.rect.minX),
                               height: max(0, document.bounds.maxY - annotation.rect.minY))
        guard available.width > 0, available.height > 0 else { return annotation.rect }
        let font = NSFont.systemFont(ofSize: annotation.style.fontSize, weight: .semibold)
        let string = NSAttributedString(string: annotation.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let setter = CTFramesetterCreateWithAttributedString(string)
        let padding = annotation.style.textBackground ? CGSize(width: 16, height: 8) : .zero
        let natural = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), nil)
        // One point of rounding room prevents a fractional final glyph from wrapping.
        let width = min(available.width, max(annotation.rect.width, ceil(natural.width + padding.width + 1) * scale.width))
        let contentWidth = max(1, width / scale.width - padding.width)
        let wrapped = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
            CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude), nil)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let height = min(available.height, max(annotation.rect.height, ceil(max(lineHeight, wrapped.height) + padding.height) * scale.height))
        return CGRect(origin: annotation.rect.origin, size: CGSize(width: width, height: height))
    }
    func setSelectionRect(_ rect: CGRect) {
        guard let bounds = document?.bounds, EditorGeometry.valid(rect) else { return }
        updateSelected { $0.setRect(rect.intersection(bounds)) }
    }
    func nudge(dx: CGFloat, dy: CGFloat) {
        guard let annotation = selectedAnnotation, let bounds = document?.bounds else { return }
        var rect = annotation.rect; rect.origin.x = min(max(0, rect.minX + dx), bounds.width - rect.width); rect.origin.y = min(max(0, rect.minY + dy), bounds.height - rect.height)
        setSelectionRect(rect)
    }
    func deleteSelected() { guard let selectedID else { return }; edit { $0.annotations.removeAll { $0.id == selectedID } }; growingTextIDs.remove(selectedID); self.selectedID = nil }
    func chooseColor(_ color: EditorColor) { hasChosenColor = true; style.color = color }
    func chooseLineWidth(_ width: Double) { hasChosenLineWidth = true; style.lineWidth = width }
    func rememberStyle() { guard style.valid, let data = try? JSONEncoder().encode(style) else { return }; defaults?.set(data, forKey: "editor.toolStyle") }
    func reportCanvasZoom(_ value: CGFloat) {
        guard value.isFinite, abs(canvasZoom - value) > 0.0001 else { return }
        canvasZoom = value
    }
    func changeZoom(by factor: CGFloat) { fitZoom = false; zoom = min(16, max(0.02, canvasZoom * factor)) }
    func findSensitiveText() {
        guard let document else { return }
        ocrTask?.cancel(); hasScannedSensitiveText = false; suggestions = []; selectedSuggestions = []; isFindingText = true
        let currentRevision = revision
        ocrTask = Task { [weak self, worker] in
            do {
                let result = try await worker.recognize(document)
                guard let self, !Task.isCancelled, self.document?.id == document.id, self.revision == currentRevision else { return }
                self.hasScannedSensitiveText = true; self.suggestions = result; self.selectedSuggestions = Set(result.map(\.id)); self.isFindingText = false
            } catch {
                guard let self, !Task.isCancelled, self.revision == currentRevision else { return }
                self.error = error.localizedDescription; self.isFindingText = false
            }
        }
    }
    func waitForSensitiveText() async { await ocrTask?.value }
    func waitForRendering() async {
        await renderTask?.value
        guard let document else { return }
        let expected = revision
        if let result = try? await worker.render(document), revision == expected, self.document?.id == document.id { preview = result; previewRevision = expected }
    }
    func applySuggestions() {
        let accepted = suggestions.filter { selectedSuggestions.contains($0.id) }
        edit { edits in edits.annotations += accepted.map { EditorAnnotation(kind: .redact, rect: $0.rect, style: EditorStyle(color: .black)) } }
    }
    func dismissSuggestions() { suggestions = []; selectedSuggestions = []; hasScannedSensitiveText = false }
    func flattened() async throws -> EditorRendered {
        guard let document else { throw EditorError.invalidImage }
        let currentRevision = revision
        let result: EditorRendered
        if let preview, previewRevision == currentRevision { result = preview } else { result = try await worker.render(document) }
        guard self.document?.id == document.id, revision == currentRevision else { throw EditorError.stale }
        return result
    }
    func copy(to pasteboard: NSPasteboard = .general) async -> Bool {
        guard !isExporting else { return false }
        guard document != nil else { return false }
        let canPublish = claimPublication()
        isExporting = true; defer { isExporting = false }
        do { let result = try await flattened(); let id = document?.id, rev = revision
            let copied = await clipboard.copyPNG(result.image, result.pointSize, pasteboard, { !Task.isCancelled && canPublish() && self.document?.id == id && self.revision == rev })
            if !copied, !Task.isCancelled, canPublish(), document?.id == id, revision == rev { self.error = String(localized: "The edited image could not be copied.") }
            return copied
        } catch { self.error = error.localizedDescription; return false }
    }
    func export(to url: URL) async throws {
        guard !isExporting else { throw EditorError.busy }
        isExporting = true; defer { isExporting = false }
        let result = try await flattened(), id = document?.id, rev = revision, edits = document?.edits
        let png = try await worker.png(result)
        guard document?.id == id, revision == rev else { throw EditorError.stale }
        // Explicit destinations only; a caller must confirm replacing the source.
        guard !EditorRenderer.isSourceDestination(url, source: document?.sourceURL) else { throw EditorError.sourceOverwrite }
        try await Task.detached { try png.write(to: url, options: .atomic) }.value
        if document?.id == id, revision == rev { cleanEdits = edits }
    }
    func temporaryExport() async throws -> URL {
        guard !isExporting else { throw EditorError.busy }
        isExporting = true; defer { isExporting = false }
        let rendered = try await flattened(), id = document?.id, rev = revision
        let cache = temporaryExports
        let url = try await Task.detached { try cache.write(rendered.png) }.value
        guard document?.id == id, revision == rev else { throw EditorError.stale }
        return url
    }
    func pin() async {
        guard !isExporting else { return }
        isExporting = true; defer { isExporting = false }
        do { try pins.pin(try await flattened()) } catch { self.error = error.localizedDescription }
    }
    func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { [weak self] response in guard response == .OK, let url = panel.url else { return }; Task { @MainActor in await self?.open(url: url) } }
    }
    func chooseExport() {
        guard document != nil else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = String(localized: "Edited screenshot.png")
        panel.begin { [weak self] response in guard response == .OK, let url = panel.url else { return }; Task { @MainActor in do { try await self?.export(to: url) } catch { self?.error = error.localizedDescription } } }
    }
    func inspectPixel(at sourcePoint: CGPoint?) {
        guard let sourcePoint, let document, let base = displayBase, document.edits.crop.contains(sourcePoint) else { pixelHex = nil; pixelLocation = nil; return }
        let point = CGPoint(x: floor(sourcePoint.x), y: floor(sourcePoint.y))
        pixelRenderer.invalidate(baseGeneration: displayBaseGeneration, annotations: document.edits.annotations, baseEdits: displayBaseEdits)
        if pixelRenderer.requiresLivePrivacy(document.edits.annotations), base.privacySource != nil {
            try? pixelRenderer.preparePrivacy(region:CGRect(origin:point,size:CGSize(width:1,height:1)),scale:1,base:base,document:document,annotations:document.edits.annotations)
        }
        if let image = try? pixelRenderer.compose(rect: CGRect(origin: point, size: CGSize(width: 1, height: 1)), scale: 1, base: base, document: document, annotations: document.edits.annotations) { pixelHex = try? EditorRenderer.sample(image, at: .zero); pixelLocation = point }
        else { pixelHex = nil; pixelLocation = nil }
    }
    func claimPublication() -> @MainActor () -> Bool {
        if let claimClipboardPublication { return claimClipboardPublication() }
        let token = localClipboardRequests.begin()
        return { [weak self] in self?.localClipboardRequests.isCurrent(token) == true }
    }
    func copyHex(_ hex: String, to pasteboard: NSPasteboard = .general) {
        let canPublish = claimPublication()
        guard !Task.isCancelled, canPublish() else { return }
        pasteboard.clearContents(); if !pasteboard.setString(hex, forType: .string) { error = String(localized: "The pixel color could not be copied.") } }
    func resume() { if !isRendering { schedulePreview() } }
    func shutdown() { stop(); pins.closeAll(); temporaryExports.cleanup() }
    func stop() {
        loadGeneration += 1; renderTask?.cancel(); ocrTask?.cancel(); isLoading = false; isRendering = false; isFindingText = false
        displayBase?.privacySource = nil; acceptedDisplayKey = nil; requestedDisplayKey = nil
    }
}

extension EnvironmentValues { @Entry var screenshotEditorSession: EditorSession? }

/// All editor destinations receive the same metadata-sanitized raster encoding.
@MainActor enum EditorClipboardPublisher {
    static func copyPNG(_ image: CGImage, pointSize: CGSize, to pasteboard: NSPasteboard = .general,
                        shouldPublish: @MainActor () -> Bool = { true }) async -> Bool {
        guard let png = try? await Task.detached(priority: .userInitiated, operation: {
            try EditorRendered(image: image, pointSize: pointSize).png
        }).value, !Task.isCancelled, shouldPublish() else { return false }
        pasteboard.clearContents()
        return pasteboard.setData(png, forType: .png)
    }
}
