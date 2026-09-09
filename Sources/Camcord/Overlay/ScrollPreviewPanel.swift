import AppKit
import CoreGraphics

/// A small floating HUD shown beside the scroll region during a manual scrolling
/// capture. It displays the stitched image growing in real time (tailing the newest
/// content at the bottom) plus a section count and Done / Cancel controls. Living in
/// its own nonactivating panel OUTSIDE the captured region, it never appears in the
/// capture and never steals scroll focus from the target.
@MainActor
final class ScrollPreviewPanel {
    private var panel: NSPanel?
    private var content: ScrollPreviewView?

    private static let size = CGSize(width: 208, height: 372)

    func show(
        near region: CGRect,
        onDone: @escaping () -> Void,
        onCancel: @escaping () -> Void
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
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
        self.content = view
    }

    func update(image: CGImage?, sections: Int) {
        content?.update(image: image, sections: sections)
    }

    /// Shows a transient message in the status line (e.g. the scrolled-too-fast warning).
    func flashHint(_ message: String) {
        content?.flashHint(message)
    }

    /// A blocking continuity/cap warning stays visible until the stitcher proves recovery.
    func setBlockingHint(_ message: String?) {
        content?.setBlockingHint(message)
    }

    func setFinishing(_ finishing: Bool) {
        content?.setFinishing(finishing)
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

/// The HUD's content: title, live status line, the tailing preview image, and the
/// Done / Cancel buttons drawn on a rounded dark card.
final class ScrollPreviewView: NSView {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    private let card = NSView()
    private let title = NSTextField(labelWithString: "Kaydırarak Çek")
    private let subtitle = NSTextField(labelWithString: "aşağı kaydır")
    private let imageView = TailingImageView()
    private let doneButton = HUDButton(title: "✓ Bitti", accent: true)
    private let cancelButton = HUDButton(title: "İptal", accent: false)

    private var sections = 0
    // Transient status-line hint (precedence over the section count while visible).
    private var hint: String?
    private var blockingHint: String?
    private var hintGeneration = 0
    private var isFinishing = false

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
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.96).cgColor
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.55).cgColor
        addSubview(card)

        title.frame = CGRect(x: 14, y: b.height - 32, width: b.width - 28, height: 20)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.backgroundColor = .clear
        title.isBezeled = false
        title.isEditable = false
        card.addSubview(title)

        subtitle.frame = CGRect(x: 14, y: b.height - 50, width: b.width - 28, height: 16)
        subtitle.font = .systemFont(ofSize: 11, weight: .regular)
        subtitle.textColor = NSColor(calibratedWhite: 1, alpha: 0.6)
        subtitle.backgroundColor = .clear
        subtitle.isBezeled = false
        subtitle.isEditable = false
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.usesSingleLineMode = false
        subtitle.maximumNumberOfLines = 0
        subtitle.cell?.wraps = true
        subtitle.cell?.isScrollable = false
        card.addSubview(subtitle)

        imageView.frame = CGRect(x: 12, y: 50, width: b.width - 24, height: (b.height - 56) - 50)
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        card.addSubview(imageView)

        let bw: CGFloat = (b.width - 14 * 2 - 10) / 2
        cancelButton.frame = CGRect(x: 14, y: 14, width: bw, height: 30)
        cancelButton.onClick = { [weak self] in self?.onCancel?() }
        card.addSubview(cancelButton)

        doneButton.frame = CGRect(x: 14 + bw + 10, y: 14, width: bw, height: 30)
        doneButton.onClick = { [weak self] in self?.onDone?() }
        card.addSubview(doneButton)
    }

    func update(image: CGImage?, sections: Int) {
        imageView.cgImage = image
        imageView.needsDisplay = true
        self.sections = sections
        refreshStatus()
    }

    func flashHint(_ message: String) {
        hint = message
        hintGeneration &+= 1
        let generation = hintGeneration
        refreshStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self, self.hintGeneration == generation else { return }
            self.hint = nil
            self.refreshStatus()
        }
    }

    func setBlockingHint(_ message: String?) {
        blockingHint = message
        refreshStatus()
    }

    func setFinishing(_ finishing: Bool) {
        isFinishing = finishing
        doneButton.isEnabled = !finishing
        doneButton.setTitle(finishing ? "Kontrol…" : "✓ Bitti")
        refreshStatus()
    }

    private func refreshStatus() {
        if isFinishing {
            subtitle.stringValue = "Son kare kontrol ediliyor…"
        } else if let blockingHint {
            subtitle.stringValue = blockingHint
        } else if let hint {
            subtitle.stringValue = hint
        } else {
            switch sections {
            case 0: subtitle.stringValue = "aşağı kaydır"
            case 1: subtitle.stringValue = "1 bölüm · aşağı kaydır"
            default: subtitle.stringValue = "\(sections) bölüm · Esc iptal"
            }
        }
        subtitle.textColor = NSColor(calibratedWhite: 1, alpha: blockingHint == nil ? 0.7 : 0.9)
        subtitle.toolTip = subtitle.stringValue
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Keep the card and controls still. Only the preview gives up the few pixels
        // needed to show a complete recovery instruction above it.
        let width = bounds.width - 28
        let textHeight = subtitle.cell?.cellSize(forBounds: CGRect(
            x: 0, y: 0, width: width, height: 1_000
        )).height ?? 16
        let height = max(16, ceil(textHeight))
        subtitle.frame = CGRect(x: 14, y: bounds.height - 34 - height, width: width, height: height)
        imageView.frame = CGRect(
            x: 12, y: 50, width: bounds.width - 24,
            height: max(0, subtitle.frame.minY - 6 - 50)
        )
    }
}

/// Draws its CGImage scaled to fit the width, pinned to the BOTTOM so the newest
/// captured content is always visible as the panorama grows.
private final class TailingImageView: NSView {
    var cgImage: CGImage?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        bounds.fill()
        guard let cgImage, cgImage.width > 0 else { return }
        let s = bounds.width / CGFloat(cgImage.width)
        let drawnH = CGFloat(cgImage.height) * s

        let croppedImage: CGImage
        let finalDrawnH: CGFloat

        if drawnH > bounds.height {
            let scaleBack = 1.0 / s
            let visiblePixelH = bounds.height * scaleBack
            // CGImage coordinates are top-left origin; bottom is at the highest Y.
            let cropRect = CGRect(x: 0, y: CGFloat(cgImage.height) - visiblePixelH, width: CGFloat(cgImage.width), height: visiblePixelH)
            if let cropped = cgImage.cropping(to: cropRect) {
                croppedImage = cropped
                finalDrawnH = bounds.height
            } else {
                croppedImage = cgImage
                finalDrawnH = drawnH
            }
        } else {
            croppedImage = cgImage
            finalDrawnH = drawnH
        }

        NSBezierPath(rect: bounds).addClip()
        let image = NSImage(cgImage: croppedImage, size: NSSize(width: bounds.width, height: finalDrawnH))
        image.draw(in: CGRect(x: 0, y: 0, width: bounds.width, height: finalDrawnH))
    }
}

/// A minimal click-through-safe button for a nonactivating HUD panel (mouseDown fires
/// the action directly, so it works without activating the app).
private final class HUDButton: NSView {
    var onClick: (() -> Void)?
    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : 0.45
            setAccessibilityEnabled(isEnabled)
            window?.invalidateCursorRects(for: self)
        }
    }
    private let accent: Bool
    private let label: NSTextField

    init(title: String, accent: Bool) {
        self.accent = accent
        self.label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = idleColor
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityEnabled(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setTitle(_ title: String) {
        label.stringValue = title
        setAccessibilityLabel(title)
    }

    private var idleColor: CGColor {
        accent ? NSColor.systemBlue.cgColor : NSColor(calibratedWhite: 1, alpha: 0.14).cgColor
    }

    override func layout() {
        super.layout()
        label.frame = CGRect(x: 0, y: (bounds.height - 17) / 2, width: bounds.width, height: 17)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let onClick else { return false }
        onClick()
        return true
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
