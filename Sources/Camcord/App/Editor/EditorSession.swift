import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers

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
    var selectedID: UUID?
    var tool = EditorTool.select {
        didSet {
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
    private var undoEntries: [EditorEdits] = []
    private var redoEntries: [EditorEdits] = []
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
    var canUndo: Bool { !undoEntries.isEmpty }
    var canRedo: Bool { !redoEntries.isEmpty }
    var hasUnsavedEdits: Bool { document.map { $0.edits != cleanEdits } ?? false }
    var selectedAnnotation: EditorAnnotation? { document?.edits.annotations.first { $0.id == selectedID } }
    var nextStep: Int { nextStepNumber }
    init(defaults: UserDefaults? = nil, worker: EditorWorker = EditorWorker(), temporaryExports: EditorTemporaryExports = EditorTemporaryExports(), pins: PinnedScreenshotController = PinnedScreenshotController(), clipboard: ClipboardOperations = ClipboardOperations()) {
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
        undoEntries = []; redoEntries = []; selectedID = nil; pendingCapture = nil; pendingURL = nil; fitZoom = true; error = nil
        changed(); onDocumentAccepted?()
    }
    func edit(_ mutation: (inout EditorEdits) -> Void) {
        guard var value = document else { return }
        let previous = value.edits; mutation(&value.edits)
        guard value.edits.valid, value.edits != previous else { return }
        undoEntries.append(previous)
        // Bound text/annotation snapshot memory as well as the number of entries.
        while undoEntries.count > 60 || undoEntries.reduce(0, { $0 + $1.annotations.reduce(0, { $0 + 256 + $1.text.utf8.count }) }) > 16_000_000 { undoEntries.removeFirst() }
        if value.edits.background != previous.background {
            rememberedBackground = value.edits.background
            if let data = try? JSONEncoder().encode(rememberedBackground) { defaults?.set(data, forKey: "editor.backgroundStyle") }
        }
        redoEntries.removeAll(); document = value; nextStepNumber = min(9999, max(nextStepNumber, (value.edits.annotations.filter { $0.kind == .step }.map(\.stepNumber).max() ?? 0) + 1)); changed()
    }
    func undo() {
        guard let edits = undoEntries.popLast(), let current = document?.edits else { return }
        redoEntries.append(current); document?.edits = edits; selectedID = nil; changed()
    }
    func redo() {
        guard let edits = redoEntries.popLast(), let current = document?.edits else { return }
        undoEntries.append(current); document?.edits = edits; selectedID = nil; changed()
    }
    private func changed() {
        revision += 1; pixelHex = nil; pixelLocation = nil; hasScannedSensitiveText = false; suggestions = []; selectedSuggestions = []; ocrTask?.cancel(); isFindingText = false
        preview = nil; previewRevision = -1; schedulePreview()
    }
    private func schedulePreview() {
        renderTask?.cancel()
        guard let document else { return }
        let currentRevision = revision; isRendering = true
        renderTask = Task { [weak self, worker] in
            do {
                let result = try await worker.render(document)
                guard let self, !Task.isCancelled, self.document?.id == document.id, self.revision == currentRevision else { return }
                self.preview = result; self.previewRevision = currentRevision; self.isRendering = false
            } catch {
                guard let self, !Task.isCancelled, self.revision == currentRevision else { return }
                self.error = error.localizedDescription; self.isRendering = false
            }
        }
    }
    func add(tool: EditorTool, from: CGPoint, to: CGPoint) {
        guard let document, tool != .select else { return }
        var rect = EditorGeometry.drag(from: from, to: to, bounds: document.bounds)
        if tool == .arrow && !rect.isNull && max(rect.width, rect.height) >= 1 {
            if rect.width < 1 { rect = CGRect(x: min(max(0, from.x - 0.5), document.bounds.width - 1), y: rect.minY, width: 1, height: rect.height) }
            if rect.height < 1 { rect = CGRect(x: rect.minX, y: min(max(0, from.y - 0.5), document.bounds.height - 1), width: rect.width, height: 1) }
        }
        if rect.isNull || rect.width < 1 || rect.height < 1 {
            if tool == .text || tool == .step { rect = CGRect(x: from.x, y: from.y, width: tool == .text ? 220 : 48, height: 48).intersection(document.bounds) }
            else { return }
        }
        if tool == .crop { edit { $0.crop = rect.integral.intersection(document.bounds) }; return }
        let annotation = EditorAnnotation(kind: tool, rect: rect, style: style, text: tool == .text ? String(localized: "Text") : "", stepNumber: nextStep, reversedX: from.x > to.x, reversedY: from.y > to.y, horizontalArrow: tool == .arrow && abs(from.y - to.y) < 1, verticalArrow: tool == .arrow && abs(from.x - to.x) < 1)
        edit { $0.annotations.append(annotation) }; selectedID = annotation.id
    }
    func updateSelected(_ mutation: (inout EditorAnnotation) -> Void) {
        guard let selectedID else { return }
        edit { if let index = $0.annotations.firstIndex(where: { $0.id == selectedID }) { mutation(&$0.annotations[index]) } }
    }
    func setSelectionRect(_ rect: CGRect) {
        guard let bounds = document?.bounds, EditorGeometry.valid(rect) else { return }
        updateSelected { $0.rect = rect.intersection(bounds) }
    }
    func nudge(dx: CGFloat, dy: CGFloat) {
        guard let annotation = selectedAnnotation, let bounds = document?.bounds else { return }
        var rect = annotation.rect; rect.origin.x = min(max(0, rect.minX + dx), bounds.width - rect.width); rect.origin.y = min(max(0, rect.minY + dy), bounds.height - rect.height)
        setSelectionRect(rect)
    }
    func deleteSelected() { guard let selectedID else { return }; edit { $0.annotations.removeAll { $0.id == selectedID } }; self.selectedID = nil }
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
    func waitForRendering() async { await renderTask?.value }
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
        guard let sourcePoint, let document, let preview, previewRevision == revision,
              document.edits.crop.contains(sourcePoint) else { pixelHex = nil; pixelLocation = nil; return }
        let crop = document.edits.crop.integral
        let background = document.edits.background
        let padding = background.preset == .none ? 0 : ceil(background.padding + background.frameWidth)
        let point = CGPoint(x: sourcePoint.x - crop.minX + padding, y: sourcePoint.y - crop.minY + padding)
        pixelHex = try? EditorRenderer.sample(preview.image, at: point)
        pixelLocation = CGPoint(x: floor(sourcePoint.x), y: floor(sourcePoint.y))
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
    func resume() { if preview == nil && !isRendering { schedulePreview() } }
    func shutdown() { stop(); pins.closeAll(); temporaryExports.cleanup() }
    func stop() { loadGeneration += 1; renderTask?.cancel(); ocrTask?.cancel(); isLoading = false; isRendering = false; isFindingText = false }
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
