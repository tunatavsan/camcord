import AppKit
import CoreGraphics

/// A minimal, STATIC border around a captured area (a recorded window, or a scrolling-
/// capture region), with an optional "Stop" pill. It lives in its own borderless panel
/// — a different window than the one being captured — and its stroke sits OUTSIDE the
/// target rect, so it never appears in the capture. Clicking the border/pill stops the
/// operation; clicks inside the target pass through so the underlying content stays
/// usable. Red for recording, blue for scrolling capture.
@MainActor
final class CaptureAreaIndicator {
    private var panel: NSPanel?

    func show(cgRect: CGRect, color: NSColor, label: String?, onStop: (() -> Void)?) {
        hide()
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let target = Geometry.cgToAppKit(cgRect, primaryScreenHeight: primaryHeight)

        let padSide: CGFloat = 14
        let padBottom: CGFloat = 14
        let padTop: CGFloat = label != nil ? 44 : 14  // room for the pill above the target

        let panelFrame = CGRect(
            x: target.minX - padSide,
            y: target.minY - padBottom,
            width: target.width + padSide * 2,
            height: target.height + padTop + padBottom
        )
        let targetInView = CGRect(x: padSide, y: padBottom, width: target.width, height: target.height)

        let panel = NSPanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let view = AreaBorderView(frame: CGRect(origin: .zero, size: panelFrame.size))
        view.targetRect = targetInView
        view.color = color
        view.label = label
        view.onStop = onStop
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Convenience for a window target: looks up the window's current bounds.
    func showWindow(_ windowID: CGWindowID, color: NSColor, label: String?, onStop: (() -> Void)?) {
        guard let bounds = Self.windowBounds(windowID) else { return }
        show(cgRect: bounds, color: color, label: label, onStop: onStop)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private static func windowBounds(_ windowID: CGWindowID) -> CGRect? {
        guard
            let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
            let info = infoList.first,
            let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else {
            return nil
        }
        return bounds
    }
}

/// Draws a thin rounded stroke just outside `targetRect`, plus an optional pill above
/// it. Only the outer band + pill are clickable; the target interior passes through.
private final class AreaBorderView: NSView {
    var targetRect: CGRect = .zero
    var color: NSColor = .systemRed
    var label: String?
    var onStop: (() -> Void)?

    override var isFlipped: Bool { false }

    private var pillRect: CGRect {
        guard let label else { return .zero }
        let attrs = pillAttributes
        let textSize = NSAttributedString(string: label, attributes: attrs).size()
        let w = textSize.width + 30  // padding + stop glyph
        let h: CGFloat = 24
        var x = targetRect.midX - w / 2
        x = max(2, min(x, bounds.width - w - 2))
        let y = targetRect.maxY + 8
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private var pillAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.white]
    }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = 2
        let strokeRect = targetRect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        let path = NSBezierPath(roundedRect: strokeRect, xRadius: 10, yRadius: 10)
        path.lineWidth = lineWidth
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.5)
        glow.shadowBlurRadius = 4
        glow.shadowOffset = .zero
        glow.set()
        color.withAlphaComponent(0.9).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        if let label {
            let r = pillRect
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
            // small white stop square + label
            let square = CGRect(x: r.minX + 9, y: r.midY - 4, width: 8, height: 8)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: square, xRadius: 1.5, yRadius: 1.5).fill()
            let attributed = NSAttributedString(string: label, attributes: pillAttributes)
            attributed.draw(at: CGPoint(x: square.maxX + 6, y: r.midY - attributed.size().height / 2))
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if label != nil, pillRect.contains(point) { return self }
        // Clickable ring band; interior passes through.
        let interior = targetRect.insetBy(dx: 3, dy: 3)
        return interior.contains(point) ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        onStop?()
    }

    override func resetCursorRects() {
        if label != nil { addCursorRect(pillRect, cursor: .pointingHand) }
    }
}
