import AppKit
import Combine
import QuartzCore
import UniformTypeIdentifiers

/// The card keeps one size for every capture; the whole capture fits inside its preview well.
struct ScreenshotCardGeometry {
    static let card = CGSize(width: 320, height: 232)
    /// The tray around the well; the well's radius stays concentric with the card's.
    static let ring: CGFloat = 8
    static let well = CGSize(width: card.width - 2 * ring, height: card.height - 2 * ring)
    /// The hover band over the well's lower edge.
    static let band: CGFloat = 72
    /// Room around the card for its shadow.
    static let shadowInset: CGFloat = 12
    static let window = CGSize(width: card.width + 2 * shadowInset, height: card.height + 2 * shadowInset)
    /// The capture's frame inside a well: aspect-fit, centred, never magnified past its own size.
    let imageRect: CGRect
    init(sourceSize: CGSize, in well: CGSize = Self.well) {
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0 else { imageRect = .zero; return }
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
    /// Opens the capture in the system's Preview: a click on the capture or its Preview action.
    var onOpen: (@MainActor () -> Void)?
    /// Pins the capture: its preview opens pinned, in front of every window.
    var onPin: (@MainActor () -> Void)?
    /// Keeps this capture in the Library when screenshots are not kept by themselves.
    var onKeep: (@MainActor () -> Void)?
    private let model: ScreenshotCardModel
    private let canEdit: Bool
    private var copied: Bool
    private var kept: Bool
    /// Shadow, frost, content and rim move as one surface: entrance, reflow and the dismissal swipe.
    private let surface: TraySurface
    let well: ScreenshotCardWell
    private let share: ScreenshotCardShare
    private var observers: Set<AnyCancellable> = []
    private var alive = true
    private var hovering = false
    private var reducedMotion = false
    private var tracking: NSTrackingArea?
    private(set) var animationDuration: TimeInterval = 0
    var measuredHeight: CGFloat { ScreenshotCardGeometry.card.height }
    private var cardRect: CGRect { bounds.insetBy(dx: ScreenshotCardGeometry.shadowInset, dy: ScreenshotCardGeometry.shadowInset) }
    /// - Parameters: copied and kept say what the capture already did by itself; the card offers the rest.
    init(model: ScreenshotCardModel, copied: Bool = true, kept: Bool = true, canEdit: Bool) {
        self.model = model; self.copied = copied; self.kept = kept; self.canEdit = canEdit
        well = ScreenshotCardWell(capture: model.capture, size: ScreenshotCardGeometry.well)
        surface = TraySurface(content: ScreenshotCardContent(well: well))
        share = ScreenshotCardShare(model: model, pause: { _, _ in })
        super.init(frame: CGRect(origin: .zero, size: ScreenshotCardGeometry.window))
        wantsLayer = true
        addSubview(surface)
        wire()
    }
    required init?(coder: NSCoder) { nil }
    private func wire() {
        share.pause = { [weak self] reason, active in self?.onPause?(reason, active) }
        let image = well.imageView
        image.export = model.export
        image.open = { [weak self] in self?.onOpen?() }
        image.swipe = { [weak self] translation, velocity, ended, cancelled in
            self?.pan(translation, velocity: velocity, ended: ended, cancelled: cancelled)
        }
        image.pause = { [weak self] in self?.onPause?(.dragging, $0) }
        image.canInteract = { [weak model] in model?.isAlive == true }
        image.prepareDrag = { [weak model] in model?.prepareDragFile() }
        image.dragFile = { [weak model] in (model?.dragFile, model?.dragFileFailed ?? true) }
        well.closeButton.action = { [weak self] in self?.onDismiss?("close") }
        refreshActions()
        model.$isBusy.sink { [weak self] busy in self?.update(busy: busy, error: self?.model.error) }.store(in: &observers)
        model.$error.sink { [weak self] error in self?.update(busy: self?.model.isBusy ?? false, error: error) }.store(in: &observers)
        model.$preparedExportURL.sink { image.preparedURL = $0 }.store(in: &observers)
        model.$preparedExportPNG.sink { image.preparedPNG = $0 }.store(in: &observers)
    }
    /// Copy and Add to Library appear only for what the capture did not already do.
    private func refreshActions() {
        var actions: [ScreenshotCardActionBand.Action] = []
        if !copied {
            actions.append(.init(title: String(localized: "Copy"), symbol: "doc.on.doc") { [weak self] _ in self?.copy() })
        }
        if !kept {
            actions.append(.init(title: String(localized: "Add to Library"), symbol: "tray.and.arrow.down") { [weak self] _ in self?.keep() })
        }
        actions += [
            .init(title: String(localized: "Edit"), symbol: "pencil", enabled: canEdit) { [weak self] _ in self?.onEdit?() },
            .init(title: String(localized: "Pin"), symbol: "pin") { [weak self] _ in self?.onPin?() },
            .init(title: String(localized: "Preview"), symbol: "eye") { [weak self] _ in self?.onOpen?() },
            .init(title: String(localized: "Share"), symbol: "square.and.arrow.up") { [weak self] anchor in self?.share.share(anchor) },
        ]
        well.band.actions = actions
        updateBadge()
    }
    private func updateBadge() {
        let status = copied ? String(localized: "Copied") : kept ? String(localized: "In Library") : nil
        well.badge.show(status: status, busy: model.isBusy, error: model.error)
    }
    private func copy() {
        Task { [weak self, model] in
            guard await model.copy(), let self, self.alive else { return }
            self.copied = true; self.refreshActions()
        }
    }
    private func keep() {
        guard alive else { return }
        onKeep?(); kept = true; refreshActions()
    }
    private func update(busy: Bool, error: String?) {
        guard alive else { return }
        updateBadge()
        well.band.isEnabled = !busy
        well.setHovering(hovering, busy: busy, reduceMotion: reducedMotion)
    }
    override func layout() {
        super.layout()
        if surface.frame != cardRect { surface.frame = cardRect }
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
        well.setHovering(active, busy: model.isBusy, reduceMotion: reducedMotion)
    }
    override func cancelOperation(_ sender: Any?) { if alive { onDismiss?("escape") } }
    func invalidate() {
        alive = false; observers.removeAll(); share.close()
        onPause = nil; onDismiss = nil; onEdit = nil; onOpen = nil; onPin = nil; onKeep = nil
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
        if entering { well.badge.pop(after: reduceMotion ? 0 : 0.18, reduceMotion: reduceMotion) }
    }
    /// Hidden while a capture flies into it.
    func awaitLanding() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        surface.layer?.opacity = 0
        CATransaction.commit()
    }
    /// The card's tray opens out from behind the capture that has just landed on it: it starts
    /// small enough to hide behind the capture and grows until its frost and rim stand around it.
    /// The landed capture stays on top until the tray is open, so nothing changes under the eye.
    func land(completion: @escaping @MainActor () -> Void) {
        layoutSubtreeIfNeeded()
        guard let layer = surface.layer, cardRect.width > 0, cardRect.height > 0 else { completion(); return }
        let shown = ScreenshotCardGeometry(sourceSize: model.capture.pointSize).imageRect
        let behind = max(0.2, min(shown.width / cardRect.width, shown.height / cardRect.height) * 0.96)
        let centre = CGPoint(x: layer.bounds.width * (0.5 - layer.anchorPoint.x), y: layer.bounds.height * (0.5 - layer.anchorPoint.y))
        let small = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-centre.x, -centre.y, 0),
                                                            CATransform3DMakeScale(behind, behind, 1)),
                                        CATransform3DMakeTranslation(centre.x, centre.y, 0))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        layer.opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.1
        layer.add(fade, forKey: "card-land-fade")
        let open = CASpringAnimation.card(keyPath: "transform", from: NSValue(caTransform3D: small),
                                          to: NSValue(caTransform3D: CATransform3DIdentity), response: 0.38, dampingRatio: 0.9)
        open.preferFullRefreshRate(on: window?.screen)
        layer.add(open, forKey: "card-land")
        animationDuration = open.duration
        CATransaction.commit()
        well.badge.pop(after: CaptureFlight.wait + 0.1, reduceMotion: false)
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
            if !cancelled, ScreenshotCardSwipe.commits(translation: translation, velocity: velocity) { onDismiss?("fling"); return }
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

/// A rightward swipe on the capture dismisses the card once it travels far or fast enough.
enum ScreenshotCardSwipe {
    static func commits(translation: CGPoint, velocity: CGPoint) -> Bool {
        translation.x > 0 && abs(translation.x) >= 1.5 * abs(translation.y)
            && (translation.x >= 60 || (translation.x >= 12 && velocity.x >= 600))
    }
}

extension CAAnimation {
    /// Card motion asks for the display's full rate (120 Hz on ProMotion).
    func preferFullRefreshRate(on screen: NSScreen?) {
        let fps = Float(min(120, max(1, screen?.maximumFramesPerSecond ?? 60)))
        preferredFrameRateRange = CAFrameRateRange(minimum: min(80, fps), maximum: fps, preferred: fps)
    }
}

/// The card's content: the preview well inside the tray's ring.
private final class ScreenshotCardContent: NSView {
    private let well: NSView
    init(well: NSView) {
        self.well = well
        super.init(frame: .zero)
        addSubview(well)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        well.frame = bounds.insetBy(dx: ScreenshotCardGeometry.ring, dy: ScreenshotCardGeometry.ring)
    }
}

/// The whole capture over a dimmed blur of itself. Over it: the status badge, the close
/// button, and the action band that rises over its lower edge.
@MainActor final class ScreenshotCardWell: NSView {
    let imageView = ScreenshotCardImageView(frame: .zero)
    let band = ScreenshotCardActionBand(frame: .zero)
    let badge = ScreenshotCardBadge(frame: .zero)
    let closeButton = ScreenshotCardCloseButton(frame: .zero)
    private let backdrop = NSView()
    private let fill = CALayer()
    private let dim = CALayer()
    private let capture: CapturedScreenshot
    private var renderedSize: CGSize = .zero
    private var renderGeneration = 0
    init(capture: CapturedScreenshot, size: CGSize) {
        self.capture = capture
        super.init(frame: CGRect(origin: .zero, size: size))
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
        imageView.setAccessibilityHelp(String(localized: "Click to preview; drag to use the file; swipe right to dismiss"))
        let lift = NSShadow()
        lift.shadowColor = NSColor.black.withAlphaComponent(0.35); lift.shadowBlurRadius = 6; lift.shadowOffset = CGSize(width: 0, height: -1)
        imageView.shadow = lift
        for view in [backdrop, imageView, band, badge, closeButton] { addSubview(view) }
        rerender()
    }
    /// Renders the blurs for the well's current size; a resized preview calls it again.
    func rerender() {
        let size = bounds.size
        guard size != renderedSize, size.width > 0, size.height > 0 else { return }
        renderedSize = size
        renderGeneration += 1
        let generation = renderGeneration, capture = capture
        let geometry = ScreenshotCardGeometry(sourceSize: capture.pointSize, in: size)
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        Task { [weak self] in
            let rendered = await ScreenshotCardBlur.render(capture.image, imageRect: geometry.imageRect, wellSize: size, scale: scale)
            guard let self, self.renderGeneration == generation else { return }
            self.apply(rendered)
        }
    }
    required init?(coder: NSCoder) { nil }
    func setHovering(_ hovering: Bool, busy: Bool, reduceMotion: Bool) {
        band.setRevealed(hovering || busy, reduceMotion: reduceMotion)
        closeButton.setRevealed(hovering, reduceMotion: reduceMotion)
    }
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
        let inset: CGFloat = 8
        let badgeSize = badge.preferredSize
        badge.frame = CGRect(x: inset, y: bounds.maxY - inset - badgeSize.height, width: badgeSize.width, height: badgeSize.height)
        let close = ScreenshotCardCloseButton.side
        closeButton.frame = CGRect(x: bounds.maxX - inset - close, y: bounds.maxY - inset - close, width: close, height: close)
    }
}

@MainActor final class ScreenshotCardImageView: NSImageView, NSDraggingSource {
    var export: ScreenshotCardExport?
    var preparedURL: URL?
    var preparedPNG: Data?
    /// A short click: opens the screenshot preview.
    var open: (() -> Void)?
    /// The preview's capture moves its window like a title bar instead of dragging the file out.
    var movesWindow = false
    /// Asked on every press: the file a drag will carry is prepared before the drag needs it.
    var prepareDrag: (() -> Void)?
    /// The prepared file, or whether preparing it failed (the drag then falls back to a file promise).
    var dragFile: () -> (url: URL?, failed: Bool) = { (nil, true) }
    /// When set, a rightward drag dismisses instead of dragging the file out:
    /// (translation, velocity, ended, cancelled). Every other direction drags the file.
    var swipe: ((CGPoint, CGPoint, Bool, Bool) -> Void)?
    var pause: ((Bool) -> Void)?
    var canInteract: @MainActor () -> Bool = { true }
    private enum Gesture { case undecided, swipe, file }
    private var downPoint: CGPoint?
    private var gesture = Gesture.undecided
    private var velocity = CGPoint.zero
    private var lastSample: (point: CGPoint, time: TimeInterval)?
    private var dragging = false
    private var promiseDelegate: ScreenshotCardPromiseDelegate?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); imageScaling = .scaleProportionallyUpOrDown; setAccessibilityLabel(String(localized: "Screenshot preview")) }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        guard canInteract(), let open else { return false }
        open(); return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { _ = accessibilityPerformPress() }
        else { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        guard canInteract() else { downPoint = nil; return }
        if movesWindow { window?.performDrag(with: event); return }
        prepareDrag?()
        let location = convert(event.locationInWindow, from: nil)
        downPoint = location; gesture = .undecided; velocity = .zero
        lastSample = (location, event.timestamp)
    }
    override func mouseDragged(with event: NSEvent) {
        guard canInteract(), let origin = downPoint, !dragging else { return }
        let location = convert(event.locationInWindow, from: nil)
        if let last = lastSample, event.timestamp > last.time {
            let dt = event.timestamp - last.time
            let sample = CGPoint(x: (location.x - last.point.x) / dt, y: (location.y - last.point.y) / dt)
            velocity = CGPoint(x: velocity.x * 0.4 + sample.x * 0.6, y: velocity.y * 0.4 + sample.y * 0.6)
        }
        lastSample = (location, event.timestamp)
        let translation = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
        switch gesture {
        case .swipe: swipe?(translation, velocity, false, false)
        case .file: beginFileDrag(with: event)
        case .undecided:
            guard hypot(translation.x, translation.y) >= 4 else { return }
            if let swipe, translation.x > 0, abs(translation.x) >= 1.5 * abs(translation.y) {
                gesture = .swipe; swipe(translation, velocity, false, false)
            } else {
                gesture = .file; beginFileDrag(with: event)
            }
        }
    }
    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil; gesture = .undecided; lastSample = nil }
        guard let origin = downPoint else { return }
        let location = convert(event.locationInWindow, from: nil)
        if gesture == .swipe {
            swipe?(CGPoint(x: location.x - origin.x, y: location.y - origin.y), velocity, true, false)
            return
        }
        guard canInteract(), gesture == .undecided, !dragging, bounds.contains(location) else { return }
        open?()
    }
    /// A real file, like a drag from Finder, so every app accepts the drop. Until it is ready
    /// the drag waits for the next movement; only if preparing it failed does it fall back to a promise.
    private func beginFileDrag(with event: NSEvent) {
        guard !dragging else { return }
        let prepared = dragFile()
        let item: NSDraggingItem
        if let url = prepared.url {
            item = NSDraggingItem(pasteboardWriter: url as NSURL)
        } else if prepared.failed, let export {
            let delegate = ScreenshotCardPromiseDelegate(export: export)
            let writer = ScreenshotCardPromiseWriter(fileType: UTType.png.identifier, delegate: delegate,
                preparedURL: preparedURL, preparedPNG: preparedPNG)
            writer.userInfo = delegate
            promiseDelegate = delegate
            item = NSDraggingItem(pasteboardWriter: writer)
        } else { return }
        item.setDraggingFrame(imageFrame, contents: image)
        dragging = true
        beginDraggingSession(with: [item], event: event, source: self)
    }
    /// Where the capture is actually drawn inside this view.
    private var imageFrame: CGRect {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(1, bounds.width / size.width, bounds.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (bounds.width - drawn.width) / 2, y: (bounds.height - drawn.height) / 2, width: drawn.width, height: drawn.height)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { pause?(true) }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false; downPoint = nil; gesture = .undecided; promiseDelegate = nil
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
