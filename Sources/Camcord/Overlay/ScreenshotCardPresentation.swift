import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// The complete image fits inside the preview bounds; narrow captures retain a useful
/// control width without stretching or trimming the image itself.
struct ScreenshotCardGeometry {
    static let maximumPreview = CGSize(width: 300, height: 220)
    static let minimumWidth: CGFloat = 160
    let imageSize: CGSize
    let canvasSize: CGSize
    init(sourceSize: CGSize, maximumHeight: CGFloat = ScreenshotCardGeometry.maximumPreview.height) {
        let height = maximumHeight.isFinite ? min(Self.maximumPreview.height, max(0, maximumHeight)) : 0
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0 else {
            imageSize = .zero; canvasSize = CGSize(width: Self.minimumWidth, height: 0); return
        }
        let scale = min(Self.maximumPreview.width / sourceSize.width, height / sourceSize.height)
        imageSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        canvasSize = CGSize(width: max(Self.minimumWidth, imageSize.width), height: imageSize.height)
    }
}

/// Bounded native host shared by production panels and ordinary-window fixtures.
@MainActor final class ScreenshotCardPresentation: NSView {
    var onPause: (@MainActor (ScreenshotCardDwell.Pause, Bool) -> Void)?
    var onDismiss: (@MainActor (String) -> Void)?
    var onEdit: (@MainActor () -> Void)?
    var onSave: (@MainActor () -> Void)?
    var onPin: (@MainActor () -> Void)?
    var onQuickLook: (@MainActor (URL) -> Void)?
    var previewLimit: CGFloat = ScreenshotCardGeometry.maximumPreview.height { didSet { if previewLimit != oldValue { updateBody() } } }
    private let model: ScreenshotCardModel
    private let canEdit: Bool
    private let canPin: Bool
    private var bodyHost: NSHostingView<ScreenshotCardBody>!
    private let glass = NSGlassEffectView()
    private var alive = true
    private var reducedMotion = false
    private var tracking: NSTrackingArea?
    private(set) var animationDuration: TimeInterval = 0
    var measuredWidth: CGFloat { geometry.canvasSize.width + 24 }
    var measuredHeight: CGFloat { bodyHost.fittingSize.height }
    private var geometry: ScreenshotCardGeometry {
        ScreenshotCardGeometry(sourceSize: CGSize(width: model.capture.image.width, height: model.capture.image.height), maximumHeight: previewLimit)
    }
    var measuredChromeHeight: CGFloat {
        // Refresh the same view tree before measuring published error/busy state.
        updateBody(); bodyHost.layoutSubtreeIfNeeded()
        return max(0, measuredHeight - geometry.canvasSize.height)
    }
    init(model: ScreenshotCardModel, canEdit: Bool, canPin: Bool) {
        self.model = model; self.canEdit = canEdit; self.canPin = canPin
        super.init(frame: .zero)
        wantsLayer = true
        bodyHost = NSHostingView(rootView: body())
        bodyHost.wantsLayer = true
        glass.wantsLayer = true
        glass.style = .regular; glass.tintColor = nil; glass.cornerRadius = Theme.Radius.floating
        glass.contentView = bodyHost
        addSubview(glass)
    }
    required init?(coder: NSCoder) { nil }
    private func body() -> ScreenshotCardBody {
        ScreenshotCardBody(model: model, geometry: geometry, canEdit: canEdit, canPin: canPin,
            edit: { [weak self] in self?.onEdit?() }, save: { [weak self] in self?.onSave?() }, pin: { [weak self] in self?.onPin?() },
            quickLook: { [weak self] url in self?.onQuickLook?(url) },
            dismiss: { [weak self] in self?.onDismiss?("close") },
            pause: { [weak self] reason, active in self?.onPause?(reason, active) },
            pan: { [weak self] translation, velocity, ended, cancelled in self?.pan(translation, velocity: velocity, ended: ended, cancelled: cancelled) })
    }
    private func updateBody() { guard bodyHost != nil else { return }; bodyHost.rootView = body(); needsLayout = true }
    override func layout() {
        super.layout()
        glass.frame = bounds.insetBy(dx: 12, dy: 12)
        bodyHost.frame = glass.bounds
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds.insetBy(dx: 12, dy: 12), options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        tracking = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { if alive { onPause?(.hover, true) } }
    override func mouseExited(with event: NSEvent) { if alive { onPause?(.hover, false) } }
    func reconcileHover(at screenPoint: CGPoint) {
        guard alive, let window else { return }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        onPause?(.hover, bounds.insetBy(dx: 12, dy: 12).contains(point))
    }
    override func cancelOperation(_ sender: Any?) { if alive { onDismiss?("escape") } }
    func invalidate() { alive = false; onPause = nil; onDismiss = nil; onEdit = nil; onSave = nil; onPin = nil; onQuickLook = nil }
    func animate(entering: Bool, reduceMotion: Bool, completion: @escaping @MainActor () -> Void) {
        reducedMotion = reduceMotion
        layoutSubtreeIfNeeded()
        guard let layer = glass.layer else { completion(); return }
        let keyPath = reduceMotion ? "opacity" : "transform.translation.x"
        let travel = max(0, bounds.width)
        let end: CGFloat = entering ? (reduceMotion ? 1 : 0) : (reduceMotion ? 0 : travel)
        let start: CGFloat
        if entering { start = reduceMotion ? 0 : travel }
        else if reduceMotion { start = CGFloat(layer.presentation()?.opacity ?? layer.opacity) }
        else { start = (layer.presentation()?.value(forKeyPath: keyPath) as? CGFloat) ?? 0 }
        let animation: CABasicAnimation
        if reduceMotion {
            animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = start; animation.toValue = end
            animation.duration = Theme.Motion.Duration.reduced
        } else { animation = Theme.Motion.interactionSpring(keyPath: keyPath, from: start, to: end) }
        preferRefreshRate(for: animation)
        animationDuration = animation.duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        layer.setValue(end, forKeyPath: keyPath)
        layer.add(animation, forKey: "card-presentation")
        CATransaction.commit()
    }
    func reposition(from oldFrame: CGRect, to newFrame: CGRect, reduceMotion: Bool) {
        reducedMotion = reduceMotion
        guard !reduceMotion, oldFrame != newFrame, let layer = glass.layer else { return }
        // The window changes its logical anchor immediately; the persistent body preserves continuity.
        let previous = (layer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
        let delta = oldFrame.minY - newFrame.minY + previous
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.setValue(0, forKeyPath: "transform.translation.y")
        let animation = Theme.Motion.interactionSpring(keyPath: "transform.translation.y", from: delta, to: 0)
        preferRefreshRate(for: animation)
        layer.add(animation, forKey: "card-reflow")
        CATransaction.commit()
    }
    private func pan(_ translation: CGPoint, velocity: CGPoint, ended: Bool, cancelled: Bool) {
        guard alive, let layer = glass.layer else { return }
        onPause?(.gesture, !ended)
        if ended {
            if !cancelled, ScreenshotCardChrome.commits(translation: translation, velocity: velocity) { onDismiss?("fling"); return }
            let position = (layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? max(0, translation.x)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.setValue(0, forKeyPath: "transform.translation.x")
            if !reducedMotion {
                let animation = Theme.Motion.interactionSpring(keyPath: "transform.translation.x", from: position, to: 0)
                preferRefreshRate(for: animation)
                layer.add(animation, forKey: "card-return")
            }
            CATransaction.commit()
        } else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "card-return")
            layer.setValue(max(0, translation.x), forKeyPath: "transform.translation.x")
            CATransaction.commit()
        }
    }
    private func preferRefreshRate(for animation: CAAnimation) {
        let fps = Float(min(120, max(1, window?.screen?.maximumFramesPerSecond ?? 60)))
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, fps), maximum: fps, preferred: fps)
    }
}

private struct ScreenshotCardBody: View {
    @ObservedObject var model: ScreenshotCardModel
    let geometry: ScreenshotCardGeometry
    let canEdit: Bool, canPin: Bool
    let edit: () -> Void, save: () -> Void, pin: () -> Void, quickLook: (URL) -> Void, dismiss: () -> Void
    let pause: (ScreenshotCardDwell.Pause, Bool) -> Void
    let pan: (CGPoint, CGPoint, Bool, Bool) -> Void
    @State private var hovering = false
    var body: some View {
        VStack(spacing: 6) {
            ScreenshotCardImage(model: model, edit: canEdit ? edit : nil, pause: pause)
                .frame(width: geometry.canvasSize.width, height: geometry.canvasSize.height)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.well).fill(Theme.Palette.well.color))
                .accessibilityLabel("Screenshot preview")
                .help("Drag the screenshot to another app")
            ScreenshotCardChromeView(dimensions: "\(model.capture.image.width) × \(model.capture.image.height)", dismiss: dismiss, pan: pan)
                .frame(height: 20)
            HStack(spacing: 0) {
                action("Copy", symbol: "doc.on.doc") { Task { _ = await model.copy() } }
                action("Save…", symbol: "square.and.arrow.down", perform: save)
                action("Edit", symbol: "pencil", enabled: canEdit, perform: edit)
                action("Close", symbol: "xmark", perform: dismiss)
                action("Pin", symbol: "pin", enabled: canPin, perform: pin)
                action("Quick Look", symbol: "eye") {
                    Task {
                        do { let url = try await model.exportedFileURL(); if model.isAlive { quickLook(url) } }
                        catch { if model.isAlive, !(error is CancellationError) { model.error = error.localizedDescription } }
                    }
                }
                ScreenshotCardShareButton(model: model, pause: pause).frame(maxWidth: .infinity).frame(height: 26)
            }
            .disabled(model.isBusy)
            .opacity(hovering || model.isBusy ? 1 : 0)
            .allowsHitTesting(hovering || model.isBusy)
            if let error = model.error { Text(error).font(Theme.Font.caption).foregroundStyle(Theme.Palette.record.color).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
            if model.isBusy { ProgressView().controlSize(.mini).accessibilityLabel("Preparing screenshot") }
        }
        .frame(width: geometry.canvasSize.width)
        .padding(12)
        .foregroundStyle(Theme.Palette.ink.color)
        .tint(Theme.Palette.ink.color)
        .onHover { active in hovering = active; pause(.hover, active) }
    }
    private func action(_ title: LocalizedStringKey, symbol: String, enabled: Bool = true, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Image(systemName: symbol).frame(maxWidth: .infinity).frame(height: 26) }
            .buttonStyle(.plain).disabled(!enabled).accessibilityLabel(Text(title)).help(Text(title))
    }
}

/// Only this chrome strip owns the dismissal gesture; image file drags and action controls are excluded.
@MainActor final class ScreenshotCardChrome: NSView, NSGestureRecognizerDelegate {
    var dismiss: (() -> Void)?
    var pan: ((CGPoint, CGPoint, Bool, Bool) -> Void)?
    private let status = NSTextField(labelWithString: String(localized: "Copied"))
    private let dimensions = NSTextField(labelWithString: "")
    private let close = NSButton()
    static func commits(translation: CGPoint, velocity: CGPoint) -> Bool {
        translation.x > 0 && abs(translation.x) >= 1.5 * abs(translation.y)
            && (translation.x >= 60 || (translation.x >= 12 && velocity.x >= 600))
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        status.font = Theme.Font.ns.text(12, weight: .medium); status.textColor = Theme.Palette.ink.ns
        dimensions.font = Theme.Font.ns.mono(11); dimensions.textColor = Theme.Palette.ink2.ns
        status.isSelectable = false; dimensions.isSelectable = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Dismiss screenshot"))
        close.isBordered = false; close.target = self; close.action = #selector(closeCard)
        close.setAccessibilityLabel(String(localized: "Dismiss screenshot"))
        for view in [status, dimensions, close] { addSubview(view) }
        let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delegate = self; addGestureRecognizer(recognizer)
        toolTip = String(localized: "Swipe right to dismiss")
    }
    required init?(coder: NSCoder) { nil }
    func setDimensions(_ text: String) { dimensions.stringValue = text }
    override func layout() {
        super.layout()
        status.frame = CGRect(x: 0, y: 1, width: 58, height: 18)
        dimensions.frame = CGRect(x: 62, y: 1, width: max(0, bounds.width - 86), height: 18)
        close.frame = CGRect(x: bounds.maxX - 20, y: 0, width: 20, height: 20)
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        !close.frame.contains(convert(event.locationInWindow, from: nil))
    }
    @objc private func closeCard() { dismiss?() }
    @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        let translation = recognizer.translation(in: self), velocity = recognizer.velocity(in: self)
        let ended = recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed
        pan?(translation, velocity, ended, recognizer.state != .ended && ended)
    }
}
private struct ScreenshotCardChromeView: NSViewRepresentable {
    let dimensions: String
    let dismiss: () -> Void
    let pan: (CGPoint, CGPoint, Bool, Bool) -> Void
    func makeNSView(context: Context) -> ScreenshotCardChrome { ScreenshotCardChrome(frame: .zero) }
    func updateNSView(_ view: ScreenshotCardChrome, context: Context) { view.setDimensions(dimensions); view.dismiss = dismiss; view.pan = pan }
}

private struct ScreenshotCardImage: NSViewRepresentable {
    let model: ScreenshotCardModel
    let edit: (() -> Void)?
    let pause: (ScreenshotCardDwell.Pause, Bool) -> Void
    func makeNSView(context: Context) -> ScreenshotCardImageView { ScreenshotCardImageView(frame: .zero) }
    func updateNSView(_ view: ScreenshotCardImageView, context: Context) {
        view.image = NSImage(cgImage: model.capture.image, size: model.capture.pointSize)
        view.export = model.export; view.preparedURL = model.preparedExportURL
        view.preparedPNG = model.preparedExportPNG
        view.edit = edit; view.pause = { pause(.dragging, $0) }
        view.canInteract = { [weak model] in model?.isAlive == true }
    }
}

@MainActor final class ScreenshotCardImageView: NSImageView, NSDraggingSource {
    var export: ScreenshotCardExport?
    var preparedURL: URL?
    var preparedPNG: Data?
    var edit: (() -> Void)?
    var pause: ((Bool) -> Void)?
    var canInteract: @MainActor () -> Bool = { true }
    private var downPoint: CGPoint?
    private var moved = false
    private var dragging = false
    private var promiseDelegate: ScreenshotCardPromiseDelegate?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); imageScaling = .scaleProportionallyUpOrDown; setAccessibilityLabel(String(localized: "Screenshot preview")) }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        guard canInteract(), let edit else { return false }
        edit(); return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { _ = accessibilityPerformPress() }
        else { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        guard canInteract() else { downPoint = nil; return }
        downPoint = convert(event.locationInWindow, from: nil); moved = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard canInteract(), let origin = downPoint, !dragging else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard hypot(location.x - origin.x, location.y - origin.y) >= 4 else { return }
        moved = true
        guard let export else { return }
        let delegate = ScreenshotCardPromiseDelegate(export: export)
        let writer = ScreenshotCardPromiseWriter(fileType: UTType.png.identifier, delegate: delegate,
            preparedURL: preparedURL, preparedPNG: preparedPNG)
        writer.userInfo = delegate
        promiseDelegate = delegate
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(bounds, contents: image)
        dragging = true
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil }
        guard canInteract(), downPoint != nil, !moved, !dragging, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        edit?()
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { pause?(true) }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false; downPoint = nil; promiseDelegate = nil
        (window?.contentView as? ScreenshotCardPresentation)?.reconcileHover(at: screenPoint)
        pause?(false)
    }
}

/// The drag manager retains this writer and its delegate even when its source card is evicted.
@MainActor final class ScreenshotCardPromiseWriter: NSFilePromiseProvider {
    nonisolated let preparedURL: URL?
    nonisolated let preparedPNG: Data?
    init(fileType: String, delegate: any NSFilePromiseProviderDelegate, preparedURL: URL? = nil, preparedPNG: Data? = nil) {
        self.preparedURL = preparedURL; self.preparedPNG = preparedPNG
        // The Objective-C convenience initializer dispatches through self.init().
        // Initialize the base directly so the frozen subclass payload is never lost.
        super.init()
        self.fileType = fileType; self.delegate = delegate
    }
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if preparedURL != nil { types.append(.fileURL) }
        if preparedPNG != nil { types.append(.png) }
        return types
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL { return preparedURL?.absoluteString }
        if type == .png { return preparedPNG }
        return super.pasteboardPropertyList(forType: type)
    }
}
final class ScreenshotCardPromiseDelegate: NSObject, NSFilePromiseProviderDelegate, Sendable {
    private let export: ScreenshotCardExport
    init(export: ScreenshotCardExport) { self.export = export }
    @MainActor func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { String(localized: "Screenshot.png") }
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let export = export
        let completion = ScreenshotCardPromiseCompletion(completionHandler)
        Task {
            do {
                let source = try await export.fileURL()
                try await Task.detached { try FileManager.default.copyItem(at: source, to: url) }.value
                completion.call(nil)
            } catch { completion.call(error) }
        }
    }
}

/// AppKit explicitly permits this callback on the promise operation queue. The one-shot
/// box transfers only that callback; its mutable ownership is protected by the lock.
private final class ScreenshotCardPromiseCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Error?) -> Void)?
    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
    func call(_ error: Error?) {
        lock.lock(); let callback = handler; handler = nil; lock.unlock()
        callback?(error)
    }
}

struct ScreenshotCardShareButton: NSViewRepresentable {
    let model: ScreenshotCardModel
    let pause: (ScreenshotCardDwell.Pause, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(model: model, pause: pause) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: String(localized: "Share"))!, target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.isBordered = false; button.contentTintColor = Theme.Palette.ink.ns
        button.setAccessibilityLabel(String(localized: "Share")); button.toolTip = String(localized: "Share")
        button.sendAction(on: [.leftMouseDown])
        return button
    }
    func updateNSView(_ view: NSButton, context: Context) { context.coordinator.model = model; context.coordinator.pause = pause; view.isEnabled = !model.isBusy }
    static func dismantleNSView(_ nsView: NSButton, coordinator: Coordinator) { coordinator.close() }
    @MainActor final class Coordinator: NSObject, @preconcurrency NSSharingServicePickerDelegate, @preconcurrency NSCloudSharingServiceDelegate {
        var model: ScreenshotCardModel
        var pause: (ScreenshotCardDwell.Pause, Bool) -> Void
        private(set) var picker: NSSharingServicePicker?
        private let present: @MainActor (NSSharingServicePicker, NSButton) -> Void
        private var service: NSSharingService?
        private var finish: (() -> Void)?
        private var snapshot: ScreenshotCardModel?
        init(model: ScreenshotCardModel, pause: @escaping (ScreenshotCardDwell.Pause, Bool) -> Void,
             present: @escaping @MainActor (NSSharingServicePicker, NSButton) -> Void = { picker, button in
                 picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
             }) { self.model = model; self.pause = pause; self.present = present }
        @objc func share(_ button: NSButton) {
            guard picker == nil, model.isAlive else { return }
            let pause = pause
            pause(.sharing, true); finish = { pause(.sharing, false) }; snapshot = model
            let picker = NSSharingServicePicker(items: [model.dragProvider()])
            self.picker = picker; picker.delegate = self
            present(picker, button)
        }
        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? { self }
        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            guard picker === sharingServicePicker else { return }
            if let service { self.service = service } else { release() }
        }
        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { if service === sharingService { release() } }
        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
            guard service === sharingService else { return }
            if snapshot?.isAlive == true { snapshot?.error = error.localizedDescription }
            release()
        }
        func sharingService(_ sharingService: NSSharingService, didCompleteForItems items: [Any], error: Error?) {
            guard service === sharingService else { return }
            if let error, snapshot?.isAlive == true { snapshot?.error = error.localizedDescription }
            release()
        }
        func close() { picker?.close(); release() }
        private func release() { let callback = finish; finish = nil; picker = nil; service = nil; snapshot = nil; callback?() }
    }
}
