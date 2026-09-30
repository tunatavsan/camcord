import AppKit
import CoreGraphics

/// A small floating HUD shown beside the scroll region during a manual scrolling
/// capture. It displays the stitched image growing in real time (tailing the newest
/// content at the bottom) plus a section count, an "Otomatik" auto-scroll toggle, and
/// Done / Cancel controls. Living in its own nonactivating panel OUTSIDE the captured
/// region, it never appears in the capture and never steals scroll focus from the target.
@MainActor
final class ScrollPreviewPanel {
    private var panel: NSPanel?
    private var content: ScrollPreviewView?

    private static let size = CGSize(width: 208, height: 372)

    func show(
        near region: CGRect,
        onDone: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onToggleAuto: @escaping () -> Void
    ) {
        hide()
        let frame = Self.placement(near: region)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // a soft shadow bleeds onto the adjacent region's edge
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let view = ScrollPreviewView(frame: CGRect(origin: .zero, size: frame.size))
        view.onDone = onDone
        view.onCancel = onCancel
        view.onToggleAuto = onToggleAuto
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
        self.content = view
    }

    func update(image: CGImage?, sections: Int) {
        content?.update(image: image, sections: sections)
    }

    /// Reflects the auto-scroll state in the toggle button and the status line.
    func setAuto(running: Bool, reachedEnd: Bool) {
        content?.setAuto(running: running, reachedEnd: reachedEnd)
    }

    /// Shows a transient message in the status line (e.g. a missing-permission hint).
    func flashHint(_ message: String) {
        content?.flashHint(message)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        content = nil
    }

    /// Places the HUD OUTSIDE the region — right, else left, else below, else above —
    /// choosing the first spot that fits fully on the region's screen without overlapping
    /// it. Coordinates are AppKit (bottom-left origin). For a near-full-screen region no
    /// spot is clean, so we clamp on-screen; the capture filter excludes our own windows,
    /// so even an overlap can't corrupt the shot.
    private static func placement(near region: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? region.height
        let regionAK = Geometry.cgToAppKit(region, primaryScreenHeight: primaryH)
        let bounds = (NSScreen.screens.first { $0.frame.intersects(regionAK) } ?? NSScreen.main)?.frame ?? regionAK
        let gap: CGFloat = 18
        let w = size.width, h = size.height

        let candidates: [CGRect] = [
            CGRect(x: regionAK.maxX + gap, y: regionAK.maxY - h, width: w, height: h),        // right, tops aligned
            CGRect(x: regionAK.minX - gap - w, y: regionAK.maxY - h, width: w, height: h),    // left
            CGRect(x: regionAK.midX - w / 2, y: regionAK.minY - gap - h, width: w, height: h), // below
            CGRect(x: regionAK.midX - w / 2, y: regionAK.maxY + gap, width: w, height: h),     // above
        ]
        for c in candidates where bounds.contains(c) && !c.intersects(regionAK) { return c }

        var fallback = candidates[0]
        fallback.origin.x = min(max(fallback.minX, bounds.minX + 8), bounds.maxX - w - 8)
        fallback.origin.y = min(max(fallback.minY, bounds.minY + 8), bounds.maxY - h - 8)
        return fallback
    }
}

/// The HUD's content: title, live status line, the tailing preview image, an auto-scroll
/// toggle, and the Done / Cancel buttons drawn on a rounded dark card.
private final class ScrollPreviewView: NSView {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggleAuto: (() -> Void)?

    private let card = NSGlassEffectView.camcord(.chrome, cornerRadius: Theme.Radius.floating)
    private let chromeContent = NSView()
    private let title = NSTextField(labelWithString: String(localized: "Scroll capture"))
    private let subtitle = NSTextField(labelWithString: String(localized: "Scroll down"))
    private let imageView = TailingImageView()
    private let autoButton = HUDButton(title: String(localized: "Scroll for me"), accent: false)
    private let doneButton = HUDButton(title: String(localized: "Done"), accent: true)
    private let cancelButton = HUDButton(title: String(localized: "Cancel"), accent: false)

    // Status-line state (precedence: transient hint > auto-running > end-reached > sections).
    private var sections = 0
    private var autoRunning = false
    private var endReached = false
    private var hint: String?
    private var hintGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    private func buildHierarchy() {
        let b = bounds
        card.frame = b
        card.wantsLayer = true
        card.contentView = chromeContent
        chromeContent.frame = b
        card.layer?.cornerRadius = Theme.Radius.floating
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.Palette.hairline.ns.cgColor
        addSubview(card)

        title.frame = CGRect(x: 14, y: b.height - 32, width: b.width - 28, height: 20)
        title.font = Theme.Font.ns.bodyStrong
        title.textColor = Theme.Palette.ink.ns
        title.backgroundColor = .clear
        title.isBezeled = false
        title.isEditable = false
        chromeContent.addSubview(title)

        subtitle.frame = CGRect(x: 14, y: b.height - 50, width: b.width - 28, height: 16)
        subtitle.font = Theme.Font.ns.caption
        subtitle.textColor = Theme.Palette.ink2.ns
        subtitle.backgroundColor = .clear
        subtitle.isBezeled = false
        subtitle.isEditable = false
        subtitle.lineBreakMode = .byTruncatingTail
        chromeContent.addSubview(subtitle)

        imageView.frame = CGRect(x: 12, y: 90, width: b.width - 24, height: (b.height - 56) - 90)
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = Theme.Palette.well.ns.cgColor
        imageView.layer?.cornerRadius = Theme.Radius.well
        imageView.layer?.masksToBounds = true
        chromeContent.addSubview(imageView)

        autoButton.frame = CGRect(x: 14, y: 54, width: b.width - 28, height: 30)
        autoButton.onClick = { [weak self] in self?.onToggleAuto?() }
        chromeContent.addSubview(autoButton)

        let bw: CGFloat = (b.width - 14 * 2 - 10) / 2
        cancelButton.frame = CGRect(x: 14, y: 14, width: bw, height: 30)
        cancelButton.onClick = { [weak self] in self?.onCancel?() }
        chromeContent.addSubview(cancelButton)

        doneButton.frame = CGRect(x: 14 + bw + 10, y: 14, width: bw, height: 30)
        doneButton.onClick = { [weak self] in self?.onDone?() }
        chromeContent.addSubview(doneButton)
    }

    func update(image: CGImage?, sections: Int) {
        imageView.cgImage = image
        imageView.needsDisplay = true
        // Continued manual scrolling after a (possibly premature) "reached end" clears the
        // stale end message so the live section count shows again.
        if sections > self.sections { endReached = false }
        self.sections = sections
        refreshStatus()
    }

    func setAuto(running: Bool, reachedEnd: Bool) {
        autoRunning = running
        endReached = reachedEnd
        hint = nil   // a real state change clears any stale hint
        autoButton.setTitle(running ? String(localized: "Stop auto scroll") : String(localized: "Scroll for me"))
        autoButton.setHighlighted(running)
        refreshStatus()
    }

    func flashHint(_ message: String) {
        hint = message
        hintGeneration &+= 1
        let generation = hintGeneration
        refreshStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self, self.hintGeneration == generation else { return }
            self.hint = nil
            self.refreshStatus()
        }
    }

    private func refreshStatus() {
        if let hint {
            subtitle.stringValue = hint
        } else if autoRunning {
            subtitle.stringValue = String(localized: "Scrolling automatically…")
        } else if endReached {
            subtitle.stringValue = String(localized: "End of page · Press Done")
        } else {
            switch sections {
            case 0: subtitle.stringValue = String(localized: "Scroll down or choose Scroll for me")
            case 1: subtitle.stringValue = String(localized: "1 section · Scroll down")
            default: subtitle.stringValue = String(localized: "\(sections) sections · Esc to cancel")
            }
        }
    }
}

/// Draws its CGImage scaled to fit the width, pinned to the BOTTOM so the newest
/// captured content is always visible as the panorama grows.
private final class TailingImageView: NSView {
    var cgImage: CGImage?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Palette.well.ns.setFill()
        bounds.fill()
        guard let cgImage, cgImage.width > 0 else { return }
        let s = bounds.width / CGFloat(cgImage.width)
        let drawnH = CGFloat(cgImage.height) * s
        NSBezierPath(rect: bounds).addClip()
        let image = NSImage(cgImage: cgImage, size: NSSize(width: bounds.width, height: drawnH))
        // Bottom-pinned: image bottom at y=0, top overflows above and is clipped → the
        // newest (bottom) content stays in view.
        image.draw(in: CGRect(x: 0, y: 0, width: bounds.width, height: drawnH))
    }
}

/// A minimal click-through-safe button for a nonactivating HUD panel (mouseDown fires
/// the action directly, so it works without activating the app).
private final class HUDButton: NSView {
    var onClick: (() -> Void)?
    private let accent: Bool
    private let label: NSTextField

    init(title: String, accent: Bool) {
        self.accent = accent
        self.label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.well
        layer?.backgroundColor = idleColor
        label.font = Theme.Font.ns.bodyStrong
        label.textColor = accent ? Theme.Palette.onInk.ns : Theme.Palette.ink.ns
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var idleColor: CGColor {
        accent ? Theme.Palette.ink.ns.cgColor : Theme.Palette.hover.ns.cgColor
    }

    func setTitle(_ t: String) { label.stringValue = t; setAccessibilityLabel(t) }

    /// Toggles a highlighted (active) fill — used by the auto-scroll toggle when running.
    func setHighlighted(_ on: Bool) {
        layer?.backgroundColor = on ? Theme.Palette.selectionStrong.ns.cgColor : idleColor
    }

    override func layout() {
        super.layout()
        label.frame = CGRect(x: 0, y: (bounds.height - 17) / 2, width: bounds.width, height: 17)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override var acceptsFirstResponder: Bool { true }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { onClick?() } else { super.keyDown(with: event) }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
