import AppKit
import CoreGraphics

/// A minimal, STATIC border around a captured area (a recorded window, or a scrolling-
/// capture region). It lives in its OWN borderless panels — different windows than the one
/// being captured — and the stroke sits OUTSIDE the target rect, so it never appears in the
/// capture. Red for recording, blue for scrolling capture.
///
/// The border panel is ALWAYS click-through (`ignoresMouseEvents = true`) so the window
/// underneath stays fully usable while it's being recorded/scrolled — returning nil from a
/// view's hitTest does NOT pass clicks through to another app's window, only
/// `ignoresMouseEvents` does. When a stop action is provided, a SEPARATE small pill panel
/// (which IS interactive) floats near the top edge to end the operation.
@MainActor
final class CaptureAreaIndicator {
    private var borderPanel: NSPanel?
    private var stopPanel: NSPanel?
    private var borderView: AreaBorderView?

    /// Live window-follow state (window recording): while set, a timer repositions the
    /// border + stop pill as the recorded window is moved/resized.
    private var followWindowID: CGWindowID?
    private var followTimer: DispatchSourceTimer?
    private var lastFollowedBounds: CGRect?

    private static let borderPad: CGFloat = 14

    func show(cgRect: CGRect, color: NSColor, label: String?, onStop: (() -> Void)?) {
        hide()
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let target = Geometry.cgToAppKit(cgRect, primaryScreenHeight: primaryHeight)

        borderPanel = makeBorderPanel(target: target, color: color)
        if let onStop {
            stopPanel = makeStopPanel(target: target, color: color, onStop: onStop)
        }
    }

    /// Convenience for a window target: looks up the window's current bounds. When
    /// `follow` is true the indicator tracks the window live as it moves/resizes (the
    /// capture itself already follows the window; this keeps the on-screen border on it).
    func showWindow(_ windowID: CGWindowID, color: NSColor, label: String?, follow: Bool = false, onStop: (() -> Void)?) {
        guard let bounds = Self.windowBounds(windowID) else { return }
        show(cgRect: bounds, color: color, label: label, onStop: onStop)
        if follow {
            followWindowID = windowID
            lastFollowedBounds = bounds
            startFollowing()
        }
    }

    func hide() {
        followTimer?.cancel()
        followTimer = nil
        followWindowID = nil
        lastFollowedBounds = nil
        borderView = nil
        borderPanel?.orderOut(nil)
        borderPanel = nil
        stopPanel?.orderOut(nil)
        stopPanel = nil
    }

    // MARK: - Live window follow

    private func startFollowing() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // ~30 Hz: smooth enough to track a dragged window without a perceptible lag,
        // cheap enough (a single-window CGWindowList query) to run during a recording.
        timer.schedule(deadline: .now() + .milliseconds(33), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self, let id = self.followWindowID, let bounds = Self.windowBounds(id) else { return }
            guard bounds != self.lastFollowedBounds else { return }
            self.lastFollowedBounds = bounds
            self.reposition(to: bounds)
        }
        timer.resume()
        followTimer = timer
    }

    private func reposition(to cgBounds: CGRect) {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let target = Geometry.cgToAppKit(cgBounds, primaryScreenHeight: primaryHeight)
        let pad = Self.borderPad

        if let borderPanel, let borderView {
            let frame = target.insetBy(dx: -pad, dy: -pad)
            borderPanel.setFrame(frame, display: true)
            borderView.frame = CGRect(origin: .zero, size: frame.size)
            borderView.targetRect = CGRect(x: pad, y: pad, width: target.width, height: target.height)
            borderView.needsDisplay = true
        }

        if let stopPanel {
            let size = stopPanel.frame.size
            let screenFrame = (NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.main)?.frame ?? target
            var origin = CGPoint(x: target.midX - size.width / 2, y: target.maxY + 8)
            if origin.y + size.height > screenFrame.maxY - 4 {
                origin.y = target.maxY - size.height - 8
            }
            origin.x = min(max(origin.x, screenFrame.minX + 4), screenFrame.maxX - size.width - 4)
            stopPanel.setFrameOrigin(origin)
        }
    }

    // MARK: - Panels

    private func makeBorderPanel(target: CGRect, color: NSColor) -> NSPanel {
        let pad = Self.borderPad
        let frame = target.insetBy(dx: -pad, dy: -pad)
        let panel = borderlessPanel(frame: frame)
        // ALWAYS click-through: the window underneath must stay usable.
        panel.ignoresMouseEvents = true
        let view = AreaBorderView(frame: CGRect(origin: .zero, size: frame.size))
        view.targetRect = CGRect(x: pad, y: pad, width: target.width, height: target.height)
        view.color = color
        panel.contentView = view
        borderView = view
        panel.orderFrontRegardless()
        return panel
    }

    private func makeStopPanel(target: CGRect, color: NSColor, onStop: @escaping () -> Void) -> NSPanel {
        let size = CGSize(width: 148, height: 30)
        let bounds = (NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.main)?.frame ?? target
        var origin = CGPoint(x: target.midX - size.width / 2, y: target.maxY + 8)
        // If there's no room above the window (near the screen top), tuck it just inside.
        if origin.y + size.height > bounds.maxY - 4 {
            origin.y = target.maxY - size.height - 8
        }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 4)

        let panel = borderlessPanel(frame: CGRect(origin: origin, size: size))
        panel.ignoresMouseEvents = false
        let pill = StopPillView(frame: CGRect(origin: .zero, size: size), color: color)
        pill.onClick = onStop
        panel.contentView = pill
        panel.orderFrontRegardless()
        return panel
    }

    private func borderlessPanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
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
        return panel
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

/// Draws a thin rounded stroke just outside `targetRect`. No interactivity — it lives in a
/// click-through panel.
private final class AreaBorderView: NSView {
    var targetRect: CGRect = .zero
    var color: NSColor = .systemRed

    override var isFlipped: Bool { false }

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
    }
}

/// A small clickable "stop" pill (stop square + label) in its own interactive panel.
private final class StopPillView: NSView {
    var onClick: (() -> Void)?
    private let color: NSColor
    private let label = NSTextField(labelWithString: "Kaydı Durdur")

    init(frame: NSRect, color: NSColor) {
        self.color = color
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.backgroundColor = color.cgColor
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        label.frame = CGRect(x: 30, y: (bounds.height - 16) / 2, width: bounds.width - 36, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // A small white stop square on the left.
        let square = CGRect(x: 12, y: bounds.midY - 5, width: 10, height: 10)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: square, xRadius: 2, yRadius: 2).fill()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
