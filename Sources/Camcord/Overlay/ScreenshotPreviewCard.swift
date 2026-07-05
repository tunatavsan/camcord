import AppKit

/// A floating preview of the screenshot that was just copied — a framed thumbnail with a
/// soft shadow that springs in at the BOTTOM-RIGHT of the active screen (where macOS's own
/// capture thumbnail sits). It replaces the small center HUD toast for screenshot captures:
/// the preview itself is the "it landed on the clipboard" confirmation.
///
/// Interactions, all with our springy motion: it springs in, a click opens the shot for
/// editing (Preview/Markup), and a drag flings it off to the right to dismiss (release
/// short of the threshold and it springs back). No close button — the swipe IS the close.
///
/// One instance is owned by `AppDelegate`; showing again replaces the current card.
@MainActor
final class ScreenshotPreviewCard {
    /// Transparent padding baked into the panel around the card so the drop shadow isn't
    /// clipped by the window bounds.
    static let shadowInset: CGFloat = 28
    /// Gap from the screen's visible bottom-right corner (above the Dock, inside the edge).
    private static let screenMargin: CGFloat = 34
    /// How far the card slides on its spring-in entrance.
    private static let slide: CGFloat = 52
    /// A springy ease-out-back — the same "fun" feel as the window-snap highlight.
    private static let springTiming = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    /// The panel's resting origin, so a drag can move it and snap it back.
    private var restOrigin: CGPoint = .zero
    private var cardWidth: CGFloat = 0

    /// Shows the preview for a freshly captured `image`. `fileURL` is the on-disk PNG when
    /// disk-saving is on (the card opens that exact file); nil means clipboard-only, and the
    /// card lazily writes a temp PNG when opened. Respects the "show copy confirmation" pref.
    func show(image: CGImage, fileURL: URL?) {
        guard HUDToast.isEnabled() else { return }
        hide()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        else { return }

        let card = PreviewCardView(image: image, fileURL: fileURL)
        card.onOpened = { [weak self] in self?.flingOff() }
        card.onHoverChange = { [weak self] hovering in self?.hoverChanged(hovering) }
        card.onDragChanged = { [weak self] dx in self?.dragChanged(dx) }
        card.onDragEnded = { [weak self] dx in self?.dragEnded(dx) }
        cardWidth = card.cardSize.width

        let panelSize = CGSize(
            width: card.cardSize.width + Self.shadowInset * 2,
            height: card.cardSize.height + Self.shadowInset * 2
        )
        // Bottom-right: card right edge `screenMargin` inside the visible edge, bottom edge
        // `screenMargin` above the Dock. Back out the panel's transparent shadow border.
        let visible = screen.visibleFrame
        let finalOrigin = CGPoint(
            x: visible.maxX - Self.screenMargin - panelSize.width + Self.shadowInset,
            y: visible.minY + Self.screenMargin - Self.shadowInset
        )
        restOrigin = finalOrigin
        let startOrigin = CGPoint(x: finalOrigin.x + Self.slide, y: finalOrigin.y)

        let panel = NSPanel(
            contentRect: CGRect(origin: startOrigin, size: panelSize),
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
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.36
            ctx.timingFunction = Self.springTiming
            panel.animator().setFrameOrigin(finalOrigin)
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        armDismiss(after: 5.0)
    }

    /// Removes the card immediately (no animation) — used when replacing it.
    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func hoverChanged(_ hovering: Bool) {
        if hovering {
            // Give the user time to read/click: freeze the countdown while the pointer is on it.
            dismissTask?.cancel()
            dismissTask = nil
        } else {
            armDismiss(after: 2.6)
        }
    }

    private func armDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.flingOff()
        }
    }

    // MARK: - Swipe-to-dismiss

    /// The card follows the drag (mostly rightward), fading as it goes so the dismissal
    /// reads before you let go.
    private func dragChanged(_ dx: CGFloat) {
        guard let panel else { return }
        dismissTask?.cancel()
        dismissTask = nil
        // A little rubber-band to the left, free travel to the right.
        let x = restOrigin.x + max(dx, -22)
        panel.setFrameOrigin(CGPoint(x: x, y: restOrigin.y))
        panel.alphaValue = dx > 0 ? max(0.35, 1 - dx / max(1, cardWidth) * 0.6) : 1
    }

    /// Past ~a third of the card's width → fling it off; otherwise spring it back home.
    private func dragEnded(_ dx: CGFloat) {
        guard panel != nil else { return }
        if dx > max(80, cardWidth * 0.3) {
            flingOff()
        } else {
            snapBack()
        }
    }

    private func snapBack() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            ctx.timingFunction = Self.springTiming
            panel.animator().setFrameOrigin(restOrigin)
            panel.animator().alphaValue = 1
        }
        armDismiss(after: 3.0)
    }

    /// Sends the card off the right edge and fades it out, then orders it away. Shared by
    /// the swipe, the auto-dismiss timer, and a click (which opens the editor).
    private func flingOff() {
        guard let panel else { return }
        self.panel = nil
        dismissTask?.cancel()
        dismissTask = nil
        let target = CGPoint(x: restOrigin.x + cardWidth + Self.shadowInset * 2 + 48, y: panel.frame.origin.y)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrameOrigin(target)
            panel.animator().alphaValue = 0
        }
        // Order out once the fade completes (we're already on the main actor).
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            panel.orderOut(nil)
        }
    }
}

/// The panel's content: a shadow-padded container holding the framed thumbnail. Owns the
/// hover tracking (pauses auto-dismiss); the card box owns the click / swipe interaction.
private final class PreviewCardView: NSView {
    var onOpened: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: ((CGFloat) -> Void)?

    let cardSize: CGSize
    private let box: CardBoxView

    init(image: CGImage, fileURL: URL?) {
        let inset = ScreenshotPreviewCard.shadowInset
        box = CardBoxView(image: image, fileURL: fileURL)
        cardSize = box.cardSize
        super.init(frame: .zero)
        wantsLayer = true

        box.frame = CGRect(x: inset, y: inset, width: cardSize.width, height: cardSize.height)
        box.onOpened = { [weak self] in self?.onOpened?() }
        box.onDragChanged = { [weak self] dx in self?.onDragChanged?(dx) }
        box.onDragEnded = { [weak self] dx in self?.onDragEnded?(dx) }
        addSubview(box)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

/// The framed thumbnail: an appearance-adaptive rounded frame around the shot, with a soft
/// drop shadow and a small "copied" check. Click opens it for editing; drag swipes it away.
private final class CardBoxView: NSView {
    var onOpened: (() -> Void)?
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: ((CGFloat) -> Void)?

    private let image: CGImage
    private let diskURL: URL?
    private var tempURL: URL?

    let cardSize: CGSize
    private let imageView = NSImageView()
    /// Card corner radius — a touch smaller so it reads as a floating photo, not a panel.
    private static let cornerRadius: CGFloat = 8

    /// Drag tracking, in absolute screen X so it stays correct while the window itself moves.
    private var dragStartX: CGFloat = 0
    private var didDrag = false

    init(image: CGImage, fileURL: URL?) {
        self.image = image
        self.diskURL = fileURL
        let thumb = Self.thumbnailSize(for: image)
        // No surrounding frame — the shot itself IS the card, floating on a soft shadow with
        // just a hairline dark edge so it never bleeds into a light background behind it.
        cardSize = thumb
        super.init(frame: CGRect(origin: .zero, size: cardSize))

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = false   // let the drop shadow spill past the bounds
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.42
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -4)

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

        // A small green "copied" check, tucked into the shot's top-right corner.
        let badge = CheckBadgeView(frame: CGRect(x: cardSize.width - 24, y: cardSize.height - 24, width: 18, height: 18))
        badge.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    // Drive appearance updates through updateLayer so the shadow path refreshes on resize.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // MARK: - Click vs. swipe

    override func mouseDown(with event: NSEvent) {
        dragStartX = NSEvent.mouseLocation.x
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = NSEvent.mouseLocation.x - dragStartX
        if !didDrag, abs(dx) > 4 { didDrag = true }
        if didDrag { onDragChanged?(dx) }
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            onDragEnded?(NSEvent.mouseLocation.x - dragStartX)
        } else {
            openForEditing()
        }
    }

    // MARK: - Open for editing

    /// Opens the shot for editing. Prefers Preview (which carries the Markup tools) so a
    /// click gives real "edit it" behavior until an in-app editor exists; falls back to the
    /// default image handler if Preview isn't present.
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
        onOpened?()
    }

    /// A real on-disk PNG to open: the saved file if it exists, else a temp PNG written once
    /// and cached. (The disk save is async and best-effort, so verify it before using it.)
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

    /// Fits the shot into a tasteful thumbnail box, preserving aspect and never upscaling.
    /// Image dimensions are in pixels (Retina = 2×), so normal captures land near 1:1.
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
