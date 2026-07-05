import AppKit
import QuartzCore

/// A floating preview of the screenshot that was just copied — a framed thumbnail with a
/// soft shadow at the BOTTOM-RIGHT of the active screen (where macOS's own capture
/// thumbnail sits). It replaces the small center HUD toast for screenshot captures: the
/// preview itself is the "it landed on the clipboard" confirmation.
///
/// All motion is Core Animation on the card's LAYER (not the window frame, which doesn't
/// animate reliably for a borderless panel): it springs in from the right edge, and a
/// while later it leaves the exact same way — reverse motion, back out to the edge. A click
/// opens the shot for editing (Preview/Markup); a drag flings it off to the right (release
/// short and it springs back home).
///
/// One instance is owned by `AppDelegate`; showing again replaces the current card.
@MainActor
final class ScreenshotPreviewCard {
    /// Transparent padding baked into the panel around the card: room for the drop shadow
    /// AND for the card to slide in/out without the window clipping it.
    static let shadowInset: CGFloat = 34
    /// Gap from the screen's visible bottom-right corner (above the Dock, inside the edge).
    private static let screenMargin: CGFloat = 34

    private var panel: NSPanel?
    private var card: PreviewCardView?
    private var dismissTask: Task<Void, Never>?

    /// Shows the preview for a freshly captured `image`. `fileURL` is the on-disk PNG when
    /// disk-saving is on; nil means clipboard-only (a temp PNG is written on demand).
    func show(image: CGImage, fileURL: URL?) {
        guard HUDToast.isEnabled() else { return }
        hide()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        else { return }

        let card = PreviewCardView(image: image, fileURL: fileURL)
        card.onHoverChange = { [weak self] hovering in self?.hoverChanged(hovering) }
        card.onDismiss = { [weak self] in self?.dismiss() }

        let panelSize = CGSize(
            width: card.cardSize.width + Self.shadowInset * 2,
            height: card.cardSize.height + Self.shadowInset * 2
        )
        // Static window: the card slides WITHIN it (layer transform), so there's no window
        // animation to misbehave. Positioned so the card rests `screenMargin` inside the
        // visible bottom-right corner.
        let visible = screen.visibleFrame
        let origin = CGPoint(
            x: visible.maxX - Self.screenMargin - panelSize.width + Self.shadowInset,
            y: visible.minY + Self.screenMargin - Self.shadowInset
        )

        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the card draws its own soft, rounded layer shadow
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        card.frame = CGRect(origin: .zero, size: panelSize)
        panel.contentView = card
        panel.orderFrontRegardless()

        self.panel = panel
        self.card = card
        card.animateIn()
        armDismiss(after: 4.5)
    }

    /// Removes the card immediately (no animation) — used when replacing it.
    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
        card = nil
    }

    private func hoverChanged(_ hovering: Bool) {
        if hovering {
            dismissTask?.cancel()
            dismissTask = nil
        } else {
            armDismiss(after: 2.4)
        }
    }

    private func armDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Leaves the way it came in — reverse motion out to the right edge + fade — then orders
    /// the panel away. Shared by the auto-dismiss timer, a completed swipe, and a click.
    private func dismiss() {
        guard let panel, let card else { return }
        self.panel = nil
        self.card = nil
        dismissTask?.cancel()
        dismissTask = nil
        card.animateOut {
            panel.orderOut(nil)
        }
    }
}

/// The panel's content: a shadow-padded container holding the framed thumbnail. Owns hover
/// tracking (pauses auto-dismiss) and forwards the box's dismiss request; the card box owns
/// the layer motion and the click / swipe interaction.
private final class PreviewCardView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var onDismiss: (() -> Void)?

    let cardSize: CGSize
    private let box: CardBoxView

    init(image: CGImage, fileURL: URL?) {
        let inset = ScreenshotPreviewCard.shadowInset
        box = CardBoxView(image: image, fileURL: fileURL)
        cardSize = box.cardSize
        super.init(frame: .zero)
        wantsLayer = true

        box.frame = CGRect(x: inset, y: inset, width: cardSize.width, height: cardSize.height)
        box.onDismiss = { [weak self] in self?.onDismiss?() }
        addSubview(box)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    func animateIn() { box.animateIn() }
    func animateOut(completion: @escaping () -> Void) { box.animateOut(completion: completion) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Track only the card's rect (not the transparent shadow margin) so hover reflects
        // the card itself.
        addTrackingArea(NSTrackingArea(
            rect: box.frame,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

/// The framed thumbnail: an appearance-adaptive rounded frame around the shot, with a soft
/// drop shadow and a small "copied" check. All entrance/exit/swipe motion lives on this
/// view's layer transform. Click opens it for editing; drag swipes it away.
private final class CardBoxView: NSView {
    var onDismiss: (() -> Void)?

    private let image: CGImage
    private let diskURL: URL?
    private var tempURL: URL?

    let cardSize: CGSize
    private let imageView = NSImageView()
    private static let cornerRadius: CGFloat = 8
    /// How far the card sits off to the right at the start/end of its travel.
    private var enterSlide: CGFloat { 34 }

    /// Absolute-screen-X drag tracking (stays correct even as the card translates).
    private var dragStartX: CGFloat = 0
    private var didDrag = false
    private var currentTranslation: CGFloat = 0

    init(image: CGImage, fileURL: URL?) {
        self.image = image
        self.diskURL = fileURL
        let thumb = Self.thumbnailSize(for: image)
        cardSize = thumb
        super.init(frame: CGRect(origin: .zero, size: cardSize))

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.42
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        // Start hidden so the window can order in before `animateIn` fades/springs it — no
        // one-frame flash of the card sitting at rest.
        layer?.opacity = 0

        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.image = NSImage(cgImage: image, size: thumb)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Self.cornerRadius
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.black.withAlphaComponent(0.5).cgColor
        addSubview(imageView)

        let badge = CheckBadgeView(frame: CGRect(x: cardSize.width - 24, y: cardSize.height - 24, width: 18, height: 18))
        badge.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // MARK: - Motion (layer transform + opacity)

    /// Springs in from the right edge with a bit of bounce — our "fun" motion.
    func animateIn() {
        guard let layer else { return }
        let spring = CASpringAnimation(keyPath: "transform.translation.x")
        spring.fromValue = enterSlide
        spring.toValue = 0
        spring.mass = 1
        spring.stiffness = 210
        spring.damping = 19
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.26
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        currentTranslation = 0
        layer.add(spring, forKey: "translate")
        layer.add(fade, forKey: "fade")
    }

    /// Leaves the exact reverse way — a small anticipation, then flies off to the right +
    /// fade. `completion` runs when it's fully gone.
    func animateOut(completion: @escaping () -> Void) {
        guard let layer else { completion(); return }
        let target = cardSize.width * 0.8 + 40
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = currentTranslation
        move.toValue = target
        move.duration = 0.34
        // Ease-in with a touch of anticipation (dips left before flying right) — the mirror
        // of the spring-in.
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, -0.32, 0.75, 0.1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = 0.32
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.transform = CATransform3DMakeTranslation(target, 0, 0)
        layer.opacity = 0
        currentTranslation = target
        layer.add(move, forKey: "translate")
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    /// Springs the card back to rest after an incomplete swipe.
    private func springBack() {
        guard let layer else { return }
        let spring = CASpringAnimation(keyPath: "transform.translation.x")
        spring.fromValue = currentTranslation
        spring.toValue = 0
        spring.mass = 1
        spring.stiffness = 240
        spring.damping = 20
        spring.duration = spring.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = 1
        fade.duration = 0.2
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        currentTranslation = 0
        layer.add(spring, forKey: "translate")
        layer.add(fade, forKey: "fade")
    }

    private func setDragTranslation(_ dx: CGFloat) {
        guard let layer else { return }
        let x = max(dx, -22)   // free rightward travel, a little rubber-band left
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(x, 0, 0)
        layer.opacity = dx > 0 ? Float(max(0.35, 1 - dx / max(1, bounds.width) * 0.6)) : 1
        CATransaction.commit()
        currentTranslation = x
    }

    // MARK: - Click vs. swipe

    override func mouseDown(with event: NSEvent) {
        dragStartX = NSEvent.mouseLocation.x
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = NSEvent.mouseLocation.x - dragStartX
        if !didDrag, abs(dx) > 4 { didDrag = true }
        if didDrag { setDragTranslation(dx) }
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            let dx = NSEvent.mouseLocation.x - dragStartX
            if dx > max(80, bounds.width * 0.3) {
                onDismiss?()          // past the threshold → leave (controller drives animateOut)
            } else {
                springBack()
            }
        } else {
            openForEditing()
        }
    }

    // MARK: - Open for editing

    private func openForEditing() {
        guard let url = exportedFileURL() else { NSSound.beep(); return }
        let workspace = NSWorkspace.shared
        if let preview = workspace.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            workspace.open([url], withApplicationAt: preview, configuration: config, completionHandler: nil)
        } else {
            workspace.open(url)
        }
        onDismiss?()
    }

    private func exportedFileURL() -> URL? {
        if let diskURL, FileManager.default.fileExists(atPath: diskURL.path) { return diskURL }
        if let tempURL, FileManager.default.fileExists(atPath: tempURL.path) { return tempURL }
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ekran Görüntüsü \(UUID().uuidString.prefix(8)).png")
        do {
            try data.write(to: url)
            tempURL = url
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Sizing

    private static func thumbnailSize(for image: CGImage) -> CGSize {
        let maxW: CGFloat = 320, maxH: CGFloat = 236
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return CGSize(width: maxW, height: maxH) }
        let scale = min(maxW / w, maxH / h, 1)
        return CGSize(width: max(60, (w * scale).rounded()), height: max(44, (h * scale).rounded()))
    }
}

/// A small green check that reads as "copied to the clipboard".
private final class CheckBadgeView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.set()
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        NSGraphicsContext.restoreGraphicsState()

        let path = NSBezierPath()
        path.move(to: CGPoint(x: bounds.width * 0.28, y: bounds.height * 0.50))
        path.line(to: CGPoint(x: bounds.width * 0.44, y: bounds.height * 0.35))
        path.line(to: CGPoint(x: bounds.width * 0.72, y: bounds.height * 0.66))
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.white.setStroke()
        path.stroke()
    }
}
