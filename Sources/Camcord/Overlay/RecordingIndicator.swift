import AppKit
import CoreGraphics

/// A minimal, STATIC glow border around a recorded window: a thin rounded outline that
/// marks which window is being captured. It is drawn once at record start and does not
/// follow the window or animate — a moving/pulsing border is distracting on camera. It
/// lives in its own borderless panel (a different window than the one being recorded),
/// so it never appears inside the recording. Clicking the border stops the recording.
///
/// Window target only; full-screen and region recordings show nothing.
@MainActor
final class RecordingIndicator {
    private var panel: NSPanel?

    /// Padding around the window frame: the glow blooms into it and it is the clickable
    /// "stop" band.
    private static let pad: CGFloat = 10

    func showWindow(_ windowID: CGWindowID, onStop: @escaping () -> Void) {
        hide()
        guard let cgBounds = Self.windowBounds(windowID) else { return }
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let appKitFrame = Geometry.cgToAppKit(cgBounds, primaryScreenHeight: primaryHeight)
        let padded = appKitFrame.insetBy(dx: -Self.pad, dy: -Self.pad)

        let panel = NSPanel(
            contentRect: padded,
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

        let view = GlowBorderView(frame: CGRect(origin: .zero, size: padded.size))
        view.inset = Self.pad
        view.onStop = onStop
        view.toolTip = "Kaydı durdurmak için tıkla"
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// On-screen bounds for a window id (top-left CG coordinates), or nil if gone.
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

/// Draws a thin, softly glowing rounded stroke sitting just OUTSIDE the target rect
/// (the target is `inset` points in from every edge), so no part of it overlaps the
/// recorded area. Only the outer band (over the padding) is clickable — clicks over the
/// window interior pass straight through so the recorded window stays fully usable.
private final class GlowBorderView: NSView {
    var inset: CGFloat = 10
    var onStop: (() -> Void)?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > inset * 2, bounds.height > inset * 2 else { return }
        let lineWidth: CGFloat = 2
        let target = bounds.insetBy(dx: inset, dy: inset)
        let strokeRect = target.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        let path = NSBezierPath(roundedRect: strokeRect, xRadius: 10, yRadius: 10)
        path.lineWidth = lineWidth

        let color = NSColor.systemRed
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.55)
        glow.shadowBlurRadius = 4
        glow.shadowOffset = .zero
        glow.set()
        color.withAlphaComponent(0.9).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Claim clicks only in the outer band (the padding ring); everything inside the
    /// window passes through (returns nil).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let interior = bounds.insetBy(dx: inset + 2, dy: inset + 2)
        return interior.contains(point) ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        onStop?()
    }

    override func resetCursorRects() {
        // Pointing hand over the clickable ring (four bands around the interior).
        let b = inset + 2
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: b), cursor: .pointingHand)
        addCursorRect(NSRect(x: 0, y: bounds.height - b, width: bounds.width, height: b), cursor: .pointingHand)
        addCursorRect(NSRect(x: 0, y: 0, width: b, height: bounds.height), cursor: .pointingHand)
        addCursorRect(NSRect(x: bounds.width - b, y: 0, width: b, height: bounds.height), cursor: .pointingHand)
    }
}
