import AppKit
import CoreGraphics

/// A subtle glowing border drawn around a window while it is being recorded, so you
/// can tell at a glance which window the recording is capturing. It lives in its own
/// borderless panel — a different window from the one being recorded — so it never
/// appears inside the recording (window capture only captures the target window's own
/// content). The border follows the window if it moves.
///
/// Only used for the window target; full-screen and region recordings show nothing.
@MainActor
final class RecordingIndicator {
    private var panel: NSPanel?
    private var borderView: GlowBorderView?
    private var followTimer: Timer?
    private var windowID: CGWindowID?

    /// Padding around the window frame for the glow to bloom into.
    private static let pad: CGFloat = 8

    func showWindow(_ windowID: CGWindowID) {
        hide()
        self.windowID = windowID

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let view = GlowBorderView(frame: .zero)
        panel.contentView = view
        self.panel = panel
        self.borderView = view

        // Position immediately, then follow the window as it moves/resizes.
        updateFrame()
        // updateFrame() calls hide() if the window is already gone on this first check,
        // which nils out `self.panel` — don't resurrect the just-torn-down panel.
        guard self.panel === panel else { return }
        panel.orderFrontRegardless()

        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    func hide() {
        followTimer?.invalidate()
        followTimer = nil
        panel?.orderOut(nil)
        panel = nil
        borderView = nil
        windowID = nil
    }

    private func updateFrame() {
        guard let windowID, let panel else { return }
        guard let cgBounds = Self.windowBounds(windowID) else {
            // The window is gone (closed) — nothing to indicate.
            hide()
            return
        }
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let appKitFrame = Geometry.cgToAppKit(cgBounds, primaryScreenHeight: primaryHeight)
        let padded = appKitFrame.insetBy(dx: -Self.pad, dy: -Self.pad)
        panel.setFrame(padded, display: true)
        borderView?.frame = CGRect(origin: .zero, size: padded.size)
        borderView?.inset = Self.pad
        borderView?.needsDisplay = true
    }

    /// Live on-screen bounds for a window id (top-left CG coordinates), or nil if the
    /// window no longer exists.
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

/// Draws a rounded, glowing stroke sitting just OUTSIDE the target rect (the target is
/// `inset` points in from every edge of this view), so no part of the stroke overlaps
/// the recorded area.
private final class GlowBorderView: NSView {
    var inset: CGFloat = 8

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > inset * 2, bounds.height > inset * 2 else { return }
        let lineWidth: CGFloat = 3
        // Target rect in local coords, then push the stroke path outward by half the
        // line width so the stroke's inner edge hugs the target boundary and the rest
        // lives in the padding — never over the captured window.
        let target = bounds.insetBy(dx: inset, dy: inset)
        let strokeRect = target.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        let path = NSBezierPath(roundedRect: strokeRect, xRadius: 9, yRadius: 9)
        path.lineWidth = lineWidth

        let color = NSColor.systemRed
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.9)
        glow.shadowBlurRadius = 7
        glow.shadowOffset = .zero
        glow.set()
        color.withAlphaComponent(0.95).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
