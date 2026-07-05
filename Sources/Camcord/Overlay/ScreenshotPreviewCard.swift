import AppKit

/// A floating preview of the screenshot that was just copied — a framed thumbnail with a
/// soft shadow that slides in at the BOTTOM-RIGHT of the active screen (where macOS's own
/// capture thumbnail lives). It replaces the small center HUD toast for screenshot
/// captures: the preview itself is the "it landed on the clipboard" confirmation.
///
/// Fully interactive (unlike the click-through toast): hover pauses the auto-dismiss and
/// reveals a close button, clicking opens the shot for editing (Preview/Markup — the bridge
/// until an in-app editor lands), and dragging lifts the file out into any other app.
///
/// One instance is owned by `AppDelegate`; showing again replaces the current card.
@MainActor
final class ScreenshotPreviewCard {
    /// Transparent padding baked into the panel around the card so the drop shadow isn't
    /// clipped by the window bounds.
    static let shadowInset: CGFloat = 28
    /// Gap from the screen's visible bottom-right corner (above the Dock, inside the edge).
    private static let screenMargin: CGFloat = 22
    /// How far the card slides horizontally on enter/exit (in from / out to the right edge).
    private static let slide: CGFloat = 48

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// Shows the preview for a freshly captured `image`. `fileURL` is the on-disk PNG when
    /// disk-saving is on (the card opens/drags that exact file); nil means clipboard-only,
    /// and the card lazily writes a temp PNG when the user acts on it. Respects the same
    /// "show copy confirmation" preference the toast does.
    func show(image: CGImage, fileURL: URL?) {
        guard HUDToast.isEnabled() else { return }
        hide()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        else { return }

        let card = PreviewCardView(image: image, fileURL: fileURL)
        card.onClose = { [weak self] in self?.dismiss() }
        card.onOpened = { [weak self] in self?.dismiss() }
        card.onHoverChange = { [weak self] hovering in self?.hoverChanged(hovering) }

        let panelSize = CGSize(
            width: card.cardSize.width + Self.shadowInset * 2,
            height: card.cardSize.height + Self.shadowInset * 2
        )
        // Bottom-right: the card's right edge sits `screenMargin` inside the visible right
        // edge, its bottom edge `screenMargin` above the Dock. The panel carries a
        // `shadowInset` transparent border, so back that out of the visible-corner target.
        let visible = screen.visibleFrame
        let finalOrigin = CGPoint(
            x: visible.maxX - Self.screenMargin - panelSize.width + Self.shadowInset,
            y: visible.minY + Self.screenMargin - Self.shadowInset
        )
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
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
            self?.dismiss()
        }
    }

    private func dismiss() {
        guard let panel else { return }
        self.panel = nil
        dismissTask?.cancel()
        dismissTask = nil
        let target = CGPoint(x: panel.frame.origin.x + Self.slide, y: panel.frame.origin.y)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(target)
        }
        // Order out once the fade completes (we're already on the main actor).
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            panel.orderOut(nil)
        }
    }
}

/// The panel's content: a shadow-padded container holding the framed thumbnail and a
/// hover-revealed close button. Owns the hover tracking; the card box itself owns the
/// click/drag interaction.
private final class PreviewCardView: NSView {
    var onClose: (() -> Void)?
    var onOpened: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    let cardSize: CGSize
    private let box: CardBoxView
    private let closeButton = CloseButtonView()

    init(image: CGImage, fileURL: URL?) {
        let inset = ScreenshotPreviewCard.shadowInset
        box = CardBoxView(image: image, fileURL: fileURL)
        cardSize = box.cardSize
        super.init(frame: .zero)
        wantsLayer = true

        box.frame = CGRect(x: inset, y: inset, width: cardSize.width, height: cardSize.height)
        box.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        box.onOpened = { [weak self] in self?.onOpened?() }
        addSubview(box)

        // The close button sits just inside the card's top-left corner — away from the
        // screen's right edge (the card is at the bottom-RIGHT) and clear of the check badge.
        let c: CGFloat = 22
        let corner: CGFloat = 6
        closeButton.frame = CGRect(x: inset + corner, y: inset + cardSize.height - c - corner, width: c, height: c)
        closeButton.onClick = { [weak self] in self?.onClose?() }
        closeButton.alphaValue = 0
        addSubview(closeButton)
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

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ hovering: Bool) {
        onHoverChange?(hovering)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            closeButton.animator().alphaValue = hovering ? 1 : 0
        }
    }
}

/// The framed thumbnail: an appearance-adaptive rounded frame around the shot, with a soft
/// drop shadow and a small "copied" check. Click opens it for editing; drag lifts the file.
private final class CardBoxView: NSView, NSDraggingSource {
    var onOpened: (() -> Void)?

    private let image: CGImage
    private let diskURL: URL?
    private var tempURL: URL?

    let cardSize: CGSize
    private let imageView = NSImageView()
    /// Card corner radius — a touch smaller so it reads as a floating photo, not a panel.
    private static let cornerRadius: CGFloat = 8

    private var mouseDownPoint: NSPoint = .zero
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

    // Drive appearance updates through updateLayer so the shadow path + cgColors refresh on
    // a light/dark switch (raw cgColors captured at init would otherwise not adapt).
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Keep the shadow path in sync with the rounded corner so the shadow is rounded
        // (not a rectangle). The hairline border is a fixed dark tone (not appearance-
        // adaptive): it reads as a thin edge on light content and vanishes on dark, which
        // is exactly the "floating photo" look.
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // MARK: - Click vs. drag

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag else { return }
        let dx = event.locationInWindow.x - mouseDownPoint.x
        let dy = event.locationInWindow.y - mouseDownPoint.y
        guard (dx * dx + dy * dy).squareRoot() > 4 else { return }
        didDrag = true
        guard let url = exportedFileURL() else { return }

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let dragImage = NSImage(cgImage: image, size: imageView.frame.size)
        item.setDraggingFrame(imageView.frame, contents: dragImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { openForEditing() }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    // MARK: - Actions

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

    /// A real on-disk PNG for opening/dragging: the saved file if it exists, else a temp PNG
    /// written once and cached. (The disk save is async and best-effort, so verify it before
    /// handing its path out.)
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

/// A small circular close button (× on a soft fill) shown on hover.
private final class CloseButtonView: NSView {
    var onClick: (() -> Void)?

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 1, dy: 1)
        NSColor(calibratedWhite: 0.14, alpha: 0.92).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let inset = bounds.width * 0.34
        let path = NSBezierPath()
        path.move(to: CGPoint(x: inset, y: inset))
        path.line(to: CGPoint(x: bounds.width - inset, y: bounds.height - inset))
        path.move(to: CGPoint(x: bounds.width - inset, y: inset))
        path.line(to: CGPoint(x: inset, y: bounds.height - inset))
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        NSColor.white.setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
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
