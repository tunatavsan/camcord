import AppKit
import Combine
import QuartzCore
import UniformTypeIdentifiers

/// The card keeps one size for every capture; the whole capture fits inside its preview well.
struct ScreenshotCardGeometry {
    static let card = CGSize(width: 320, height: 232)
    /// The glass ring around the well; the well's radius stays concentric with the card's.
    static let ring: CGFloat = 8
    static let footer: CGFloat = 20
    static let footerGap: CGFloat = 6
    /// The hover band over the well's lower edge.
    static let band: CGFloat = 72
    static let well = CGSize(width: card.width - 2 * ring, height: card.height - 2 * ring - footer - footerGap)
    /// Room around the card for the glass's own shadow.
    static let shadowInset: CGFloat = 12
    static let window = CGSize(width: card.width + 2 * shadowInset, height: card.height + 2 * shadowInset)
    /// The capture's frame inside the well: aspect-fit, centred, never magnified past its own size.
    let imageRect: CGRect
    init(sourceSize: CGSize) {
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0 else { imageRect = .zero; return }
        let well = Self.well
        let scale = min(1, well.width / sourceSize.width, well.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        imageRect = CGRect(x: (well.width - size.width) / 2, y: (well.height - size.height) / 2,
                           width: size.width, height: size.height)
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
    private let model: ScreenshotCardModel
    private let canEdit: Bool
    private let canPin: Bool
    /// Frost and glass move as one surface: entrance, reflow and the dismissal swipe.
    private let surface = NSView()
    private let glass = NSGlassEffectView()
    let well: ScreenshotCardWell
    private let chrome = ScreenshotCardChrome(frame: .zero)
    private let share: ScreenshotCardShare
    private var observers: Set<AnyCancellable> = []
    private var alive = true
    private var hovering = false
    private var reducedMotion = false
    private var tracking: NSTrackingArea?
    private(set) var animationDuration: TimeInterval = 0
    var measuredHeight: CGFloat { ScreenshotCardGeometry.card.height }
    private var cardRect: CGRect { bounds.insetBy(dx: ScreenshotCardGeometry.shadowInset, dy: ScreenshotCardGeometry.shadowInset) }
    init(model: ScreenshotCardModel, canEdit: Bool, canPin: Bool) {
        self.model = model; self.canEdit = canEdit; self.canPin = canPin
        well = ScreenshotCardWell(capture: model.capture)
        share = ScreenshotCardShare(model: model, pause: { _, _ in })
        super.init(frame: CGRect(origin: .zero, size: ScreenshotCardGeometry.window))
        wantsLayer = true
        surface.wantsLayer = true
        // The window tray's light frost sets the card apart from whatever it floats over.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            surface.addSubview(TrayBlurView(cornerRadius: Theme.Radius.floating))
        }
        glass.style = .regular; glass.tintColor = nil; glass.cornerRadius = Theme.Radius.floating
        glass.adoptSidebarGlass()
        glass.contentView = ScreenshotCardContent(well: well, chrome: chrome)
        surface.addSubview(glass)
        addSubview(surface)
        wire()
    }
    required init?(coder: NSCoder) { nil }
    private func wire() {
        share.pause = { [weak self] reason, active in self?.onPause?(reason, active) }
        let image = well.imageView
        image.export = model.export
        image.edit = canEdit ? { [weak self] in self?.onEdit?() } : nil
        image.pause = { [weak self] in self?.onPause?(.dragging, $0) }
        image.canInteract = { [weak model] in model?.isAlive == true }
        well.band.actions = [
            .init(title: String(localized: "Copy"), symbol: "doc.on.doc") { [weak model] _ in Task { _ = await model?.copy() } },
            .init(title: String(localized: "Save…"), symbol: "square.and.arrow.down") { [weak self] _ in self?.onSave?() },
            .init(title: String(localized: "Edit"), symbol: "pencil", enabled: canEdit) { [weak self] _ in self?.onEdit?() },
            .init(title: String(localized: "Pin"), symbol: "pin", enabled: canPin) { [weak self] _ in self?.onPin?() },
            .init(title: String(localized: "Quick Look"), symbol: "eye") { [weak self] _ in self?.quickLook() },
            .init(title: String(localized: "Share"), symbol: "square.and.arrow.up") { [weak self] anchor in self?.share.share(anchor) },
        ]
        chrome.dismiss = { [weak self] in self?.onDismiss?("close") }
        chrome.pan = { [weak self] translation, velocity, ended, cancelled in
            self?.pan(translation, velocity: velocity, ended: ended, cancelled: cancelled)
        }
        chrome.setDimensions("\(model.capture.image.width) × \(model.capture.image.height)")
        model.$isBusy.sink { [weak self] busy in self?.update(busy: busy, error: self?.model.error) }.store(in: &observers)
        model.$error.sink { [weak self] error in self?.update(busy: self?.model.isBusy ?? false, error: error) }.store(in: &observers)
        model.$preparedExportURL.sink { image.preparedURL = $0 }.store(in: &observers)
        model.$preparedExportPNG.sink { image.preparedPNG = $0 }.store(in: &observers)
    }
    private func update(busy: Bool, error: String?) {
        guard alive else { return }
        chrome.setState(busy: busy, error: error)
        well.band.isEnabled = !busy
        well.band.setRevealed(hovering || busy, reduceMotion: reducedMotion)
    }
    private func quickLook() {
        Task { [weak self, model] in
            do {
                let url = try await model.exportedFileURL()
                if model.isAlive { self?.onQuickLook?(url) }
            } catch {
                if model.isAlive, !(error is CancellationError) { model.error = error.localizedDescription }
            }
        }
    }
    override func layout() {
        super.layout()
        if surface.frame != cardRect { surface.frame = cardRect }
        for view in surface.subviews where view.frame != surface.bounds { view.frame = surface.bounds }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: cardRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        tracking = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }
    func reconcileHover(at screenPoint: CGPoint) {
        guard alive, let window else { return }
        setHovering(cardRect.contains(convert(window.convertPoint(fromScreen: screenPoint), from: nil)))
    }
    private func setHovering(_ active: Bool) {
        guard alive else { return }
        hovering = active
        onPause?(.hover, active)
        well.band.setRevealed(active || model.isBusy, reduceMotion: reducedMotion)
    }
    override func cancelOperation(_ sender: Any?) { if alive { onDismiss?("escape") } }
    func invalidate() {
        alive = false; observers.removeAll(); share.close()
        onPause = nil; onDismiss = nil; onEdit = nil; onSave = nil; onPin = nil; onQuickLook = nil
    }
    func animate(entering: Bool, reduceMotion: Bool, completion: @escaping @MainActor () -> Void) {
        reducedMotion = reduceMotion
        layoutSubtreeIfNeeded()
        guard let layer = surface.layer else { completion(); return }
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
        animation.preferFullRefreshRate(on: window?.screen)
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
        guard !reduceMotion, oldFrame != newFrame, let layer = surface.layer else { return }
        // The window changes its logical anchor immediately; the persistent body preserves continuity.
        let previous = (layer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
        let delta = oldFrame.minY - newFrame.minY + previous
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.setValue(0, forKeyPath: "transform.translation.y")
        let animation = Theme.Motion.interactionSpring(keyPath: "transform.translation.y", from: delta, to: 0)
        animation.preferFullRefreshRate(on: window?.screen)
        layer.add(animation, forKey: "card-reflow")
        CATransaction.commit()
    }
    private func pan(_ translation: CGPoint, velocity: CGPoint, ended: Bool, cancelled: Bool) {
        guard alive, let layer = surface.layer else { return }
        onPause?(.gesture, !ended)
        if ended {
            if !cancelled, ScreenshotCardChrome.commits(translation: translation, velocity: velocity) { onDismiss?("fling"); return }
            let position = (layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? max(0, translation.x)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.setValue(0, forKeyPath: "transform.translation.x")
            if !reducedMotion {
                let animation = Theme.Motion.interactionSpring(keyPath: "transform.translation.x", from: position, to: 0)
                animation.preferFullRefreshRate(on: window?.screen)
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
}

extension CAAnimation {
    /// Card motion asks for the display's full rate (120 Hz on ProMotion).
    func preferFullRefreshRate(on screen: NSScreen?) {
        let fps = Float(min(120, max(1, screen?.maximumFramesPerSecond ?? 60)))
        preferredFrameRateRange = CAFrameRateRange(minimum: min(80, fps), maximum: fps, preferred: fps)
    }
}

/// The glass's content: the preview well above a one-line footer.
private final class ScreenshotCardContent: NSView {
    private let well: NSView
    private let chrome: NSView
    init(well: NSView, chrome: NSView) {
        self.well = well; self.chrome = chrome
        super.init(frame: .zero)
        addSubview(well); addSubview(chrome)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        typealias G = ScreenshotCardGeometry
        chrome.frame = CGRect(x: G.ring + 4, y: G.ring, width: max(0, bounds.width - 2 * G.ring - 6), height: G.footer)
        well.frame = CGRect(x: G.ring, y: G.ring + G.footer + G.footerGap, width: G.well.width, height: G.well.height)
    }
}

/// The whole capture over a dimmed blur of itself; the action band rises over its lower edge.
@MainActor final class ScreenshotCardWell: NSView {
    let imageView = ScreenshotCardImageView(frame: .zero)
    let band = ScreenshotCardActionBand(frame: .zero)
    private let backdrop = NSView()
    private let fill = CALayer()
    private let dim = CALayer()
    init(capture: CapturedScreenshot) {
        super.init(frame: CGRect(origin: .zero, size: ScreenshotCardGeometry.well))
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.well
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = Theme.Palette.well.ns.cgColor
        backdrop.wantsLayer = true
        fill.contentsGravity = .resizeAspectFill
        fill.opacity = 0
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        backdrop.layer?.addSublayer(fill)
        backdrop.layer?.addSublayer(dim)
        imageView.image = NSImage(cgImage: capture.image, size: capture.pointSize)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.setAccessibilityHelp(String(localized: "Drag the screenshot to another app"))
        imageView.toolTip = String(localized: "Drag the screenshot to another app")
        let lift = NSShadow()
        lift.shadowColor = NSColor.black.withAlphaComponent(0.35); lift.shadowBlurRadius = 6; lift.shadowOffset = CGSize(width: 0, height: -1)
        imageView.shadow = lift
        for view in [backdrop, imageView, band] { addSubview(view) }
        let geometry = ScreenshotCardGeometry(sourceSize: capture.pointSize)
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        Task { [weak self] in
            let rendered = await ScreenshotCardBlur.render(capture.image, imageRect: geometry.imageRect, scale: scale)
            self?.apply(rendered)
        }
    }
    required init?(coder: NSCoder) { nil }
    private func apply(_ rendered: ScreenshotCardBlur.Rendered) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        fill.contents = rendered.fill
        fill.opacity = rendered.fill == nil ? 0 : 1
        CATransaction.commit()
        band.setBlurLevels(rendered.levels)
    }
    override func layout() {
        super.layout()
        backdrop.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds; dim.frame = bounds
        CATransaction.commit()
        imageView.frame = bounds
        band.frame = CGRect(x: 0, y: 0, width: bounds.width, height: ScreenshotCardGeometry.band)
    }
}

/// Only this footer owns the dismissal gesture; image file drags and action controls are excluded.
@MainActor final class ScreenshotCardChrome: NSView, NSGestureRecognizerDelegate {
    var dismiss: (() -> Void)?
    var pan: ((CGPoint, CGPoint, Bool, Bool) -> Void)?
    private let status = NSTextField(labelWithString: String(localized: "Copied"))
    private let dimensions = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let close = NSButton()
    private var busy = false
    private var error: String?
    static func commits(translation: CGPoint, velocity: CGPoint) -> Bool {
        translation.x > 0 && abs(translation.x) >= 1.5 * abs(translation.y)
            && (translation.x >= 60 || (translation.x >= 12 && velocity.x >= 600))
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        status.font = Theme.Font.ns.text(12, weight: .medium); status.textColor = Theme.Palette.ink.ns
        status.lineBreakMode = .byTruncatingTail
        dimensions.font = Theme.Font.ns.mono(11); dimensions.textColor = Theme.Palette.ink2.ns
        status.isSelectable = false; dimensions.isSelectable = false
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel(String(localized: "Preparing screenshot"))
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Dismiss screenshot"))?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        close.contentTintColor = Theme.Palette.ink2.ns
        close.isBordered = false; close.target = self; close.action = #selector(closeCard)
        close.setAccessibilityLabel(String(localized: "Dismiss screenshot"))
        for view in [spinner, status, dimensions, close] { addSubview(view) }
        let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delegate = self; addGestureRecognizer(recognizer)
        toolTip = String(localized: "Swipe right to dismiss")
    }
    required init?(coder: NSCoder) { nil }
    func setDimensions(_ text: String) { dimensions.stringValue = text; needsLayout = true }
    func setState(busy: Bool, error: String?) {
        self.busy = busy; self.error = error
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        status.stringValue = error ?? String(localized: "Copied")
        status.textColor = error == nil ? Theme.Palette.ink.ns : Theme.Palette.record.ns
        status.toolTip = error
        dimensions.isHidden = error != nil
        needsLayout = true
    }
    override func layout() {
        super.layout()
        var x: CGFloat = 0
        if busy { spinner.frame = CGRect(x: 0, y: 2, width: 16, height: 16); x = 22 }
        let closeX = bounds.maxX - 20
        let statusWidth = min(ceil(status.attributedStringValue.size().width) + 4, max(0, closeX - 8 - x))
        status.frame = CGRect(x: x, y: 1, width: statusWidth, height: 18)
        x += statusWidth + 8
        dimensions.frame = CGRect(x: x, y: 1, width: max(0, closeX - 8 - x), height: 18)
        close.frame = CGRect(x: closeX, y: 0, width: 20, height: 20)
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


/// Owns one sharing picker at a time and its sharing pause.
@MainActor final class ScreenshotCardShare: NSObject, @preconcurrency NSSharingServicePickerDelegate, @preconcurrency NSCloudSharingServiceDelegate {
    var model: ScreenshotCardModel
    var pause: (ScreenshotCardDwell.Pause, Bool) -> Void
    private(set) var picker: NSSharingServicePicker?
    private let present: @MainActor (NSSharingServicePicker, NSView) -> Void
    private var service: NSSharingService?
    private var finish: (() -> Void)?
    private var snapshot: ScreenshotCardModel?
    init(model: ScreenshotCardModel, pause: @escaping (ScreenshotCardDwell.Pause, Bool) -> Void,
         present: @escaping @MainActor (NSSharingServicePicker, NSView) -> Void = { picker, anchor in
             picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
         }) { self.model = model; self.pause = pause; self.present = present }
    func share(_ anchor: NSView) {
        guard picker == nil, model.isAlive else { return }
        let pause = pause
        pause(.sharing, true); finish = { pause(.sharing, false) }; snapshot = model
        let picker = NSSharingServicePicker(items: [model.dragProvider()])
        self.picker = picker; picker.delegate = self
        present(picker, anchor)
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
