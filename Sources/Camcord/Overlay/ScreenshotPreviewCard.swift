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
    static func shadowInset(for size: CGSize) -> CGFloat {
        max(34, ceil(CameraOptions.cornerRadius(for: size) * 3))
    }
    /// Gap from the screen's visible bottom-right corner (above the Dock, inside the edge).
    private static let screenMargin: CGFloat = 34

    private var panel: NSPanel?
    private var card: PreviewCardView?
    private var dismissTask: Task<Void, Never>?

    /// Shows the preview for a freshly captured `image`. `fileURL` is the on-disk PNG when
    /// disk-saving is on; nil means clipboard-only (a temp PNG is written on demand).
    func show(image: CGImage, fileURL: URL?) {
        Self.cleanupTempFiles()
        guard HUDToast.isEnabled() else { return }
        hide()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        else { return }

        let card = PreviewCardView(image: image, fileURL: fileURL)
        let shadowInset = Self.shadowInset(for: card.cardSize)
        card.onHoverChange = { [weak self] hovering in self?.hoverChanged(hovering) }
        card.onDismiss = { [weak self] in self?.dismiss() }

        let panelSize = CGSize(
            width: card.cardSize.width + shadowInset * 2,
            height: card.cardSize.height + shadowInset * 2
        )
        // Static window: the card slides WITHIN it (layer transform), so there's no window
        // animation to misbehave. Positioned so the card rests `screenMargin` inside the
        // visible bottom-right corner.
        let visible = screen.visibleFrame
        let origin = CGPoint(
            x: visible.maxX - Self.screenMargin - panelSize.width + shadowInset,
            y: visible.minY + Self.screenMargin - shadowInset
        )

        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.animationBehavior = .none
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
        armDismiss(after: 1.8)
    }

    /// A late disk completion can update only its own still-visible image.
    func saved(image: CGImage, to url: URL) { card?.saved(image: image, to: url) }

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
            armDismiss(after: 0.8)
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

    private static var hasCleanedUpTempFiles = false

    private static func cleanupTempFiles() {
        guard !hasCleanedUpTempFiles else { return }
        hasCleanedUpTempFiles = true
        Task.detached(priority: .background) {
            let tempDir = FileManager.default.temporaryDirectory
            guard let urls = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.creationDateKey]) else { return }
            let threshold = Date().addingTimeInterval(-3600 * 24) // 24 hours old
            for url in urls where url.lastPathComponent.hasPrefix("Ekran Görüntüsü") {
                if let values = try? url.resourceValues(forKeys: [.creationDateKey]),
                   let date = values.creationDate, date < threshold {
                    try? FileManager.default.removeItem(at: url)
                }
            }
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
        box = CardBoxView(image: image, fileURL: fileURL)
        cardSize = box.cardSize
        let inset = ScreenshotPreviewCard.shadowInset(for: cardSize)
        super.init(frame: .zero)
        wantsLayer = true

        box.frame = CGRect(x: inset, y: inset, width: cardSize.width, height: cardSize.height)
        box.onDismiss = { [weak self] in self?.onDismiss?() }
        addSubview(box)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    func saved(image: CGImage, to url: URL) { box.saved(image: image, to: url) }
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
/// drop shadow. All entrance/exit/swipe motion lives on this
/// view's layer transform. Click opens it for editing; drag swipes it away.
private final class CardBoxView: NSView {
    var onDismiss: (() -> Void)?

    func saved(image: CGImage, to url: URL) {
        guard self.image === image else { return }
        diskURL = url
    }

    private let image: CGImage
    private var diskURL: URL?
    private var tempURL: URL?

    let cardSize: CGSize
    private let imageView = NSImageView()
    private var cornerRadius: CGFloat { CameraOptions.cornerRadius(for: cardSize) }
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
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.55
        layer?.shadowRadius = cornerRadius * 1.6
        layer?.shadowOffset = CGSize(width: 0, height: -cornerRadius * 0.4)
        // Start hidden so the window can order in before `animateIn` fades/springs it — no
        // one-frame flash of the card sitting at rest.
        layer?.opacity = 0

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Ekran görüntüsü panoya kopyalandı")
        setAccessibilityHelp("Görüntüyü Önizleme uygulamasında aç")
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.image = NSImage(cgImage: image, size: thumb)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = cornerRadius
        imageView.layer?.masksToBounds = true
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { openForEditing(); return true }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: - Motion (layer transform + opacity)

    /// Springs in from the right edge with a bit of bounce — our "fun" motion.
    func animateIn() {
        guard let layer else { return }
        if reduceMotion {
            layer.removeAllAnimations()
            layer.transform = CATransform3DIdentity
            layer.opacity = 1
            currentTranslation = 0
            return
        }
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
        if reduceMotion {
            layer.removeAllAnimations()
            layer.opacity = 0
            completion()
            return
        }
        let target = cardSize.width * 0.8 + 40
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = currentTranslation
        move.toValue = target
        move.duration = 0.22
        // Ease-in with a touch of anticipation (dips left before flying right) — the mirror
        // of the spring-in.
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, -0.32, 0.75, 0.1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = 0.20
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
        if reduceMotion {
            layer.removeAllAnimations()
            layer.transform = CATransform3DIdentity
            layer.opacity = 1
            currentTranslation = 0
            return
        }
        let spring = CASpringAnimation(keyPath: "transform.translation.x")
        spring.fromValue = currentTranslation
        spring.toValue = 0
        spring.mass = 1
        spring.stiffness = 210
        spring.damping = 19
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
        Task {
            // Dismiss only on success — a failed export beeps and keeps the card so
            // the user can retry (or copy is still on the clipboard).
            guard let url = await exportedFileURL() else { NSSound.beep(); return }
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
    }

    private func exportedFileURL() async -> URL? {
        if let diskURL, FileManager.default.fileExists(atPath: diskURL.path) { return diskURL }
        if let tempURL, FileManager.default.fileExists(atPath: tempURL.path) { return tempURL }

        let cgImage = image
        let url = await Task.detached(priority: .userInitiated) { () -> URL? in
            guard let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return nil }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("Ekran Görüntüsü \(UUID().uuidString.prefix(8)).png")
            do {
                try data.write(to: dest)
                return dest
            } catch {
                return nil
            }
        }.value

        self.tempURL = url
        return url
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
