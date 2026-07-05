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

    /// Live window-follow state (window recording): while set, a display-synced timer
    /// repositions the border + stop pill as the recorded window is moved/resized, and
    /// hides them while the window is occluded so the border never floats over the app
    /// that covered it.
    private var followWindowID: CGWindowID?
    private var followTimer: DispatchSourceTimer?
    private var lastFollowedBounds: CGRect?
    private var followTick = 0
    /// Ticks between occlusion checks (position tracks every tick; occlusion ~12 Hz).
    private var occlusionCheckInterval = 8
    /// True while the recorded window is currently covered/off-screen (border hidden).
    private var occluded = false

    private static let borderPad: CGFloat = 16

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
        followTick = 0
        occluded = false
        borderView = nil
        borderPanel?.orderOut(nil)
        borderPanel = nil
        stopPanel?.orderOut(nil)
        stopPanel = nil
    }

    // MARK: - Live window follow

    private func startFollowing() {
        // Track at the display's native refresh (120 Hz on ProMotion) so the border stays
        // glued to a dragged window instead of stuttering a frame behind. A single-window
        // CGWindowList query per tick is cheap; occlusion (the full-list query) runs at a
        // much lower cadence since it only changes when the user reshuffles windows.
        let fps = max(60, NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60)
        occlusionCheckInterval = max(1, fps / 12)
        followTick = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let intervalNs = Int(1_000_000_000 / fps)
        timer.schedule(deadline: .now() + .nanoseconds(intervalNs), repeating: .nanoseconds(intervalNs))
        timer.setEventHandler { [weak self] in
            guard let self, let id = self.followWindowID else { return }
            self.followTick &+= 1
            if let bounds = Self.windowBounds(id), bounds != self.lastFollowedBounds {
                self.lastFollowedBounds = bounds
                self.reposition(to: bounds)
            }
            if self.followTick % self.occlusionCheckInterval == 0 {
                let nowOccluded = !Self.isWindowVisible(id)
                if nowOccluded != self.occluded {
                    self.occluded = nowOccluded
                    self.applyOcclusion()
                }
            }
        }
        timer.resume()
        followTimer = timer
    }

    /// Hides the border + stop pill while the recorded window is covered/off-screen, and
    /// brings them back (in place) when it's visible again — so the indicator behaves like
    /// it's attached to the window rather than always floating on top.
    private func applyOcclusion() {
        if occluded {
            borderPanel?.orderOut(nil)
            stopPanel?.orderOut(nil)
        } else {
            borderPanel?.orderFrontRegardless()
            stopPanel?.orderFrontRegardless()
        }
    }

    /// True when the recorded window is currently on-screen AND the topmost normal window
    /// at its own center — i.e. not covered there by another app. A conservative "can't
    /// tell" (no window list) counts as visible so the indicator never blinks off wrongly.
    private static func isWindowVisible(_ windowID: CGWindowID) -> Bool {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return true
        }
        // Our window's live on-screen bounds — absent means it's minimized/hidden.
        var targetBounds: CGRect?
        for info in infoList {
            guard let number = info[kCGWindowNumber as String] as? Int, CGWindowID(number) == windowID,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            targetBounds = bounds
            break
        }
        guard let targetBounds else { return false }
        let center = CGPoint(x: targetBounds.midX, y: targetBounds.midY)
        // Front-to-back: the first normal window covering the center decides — if it's us,
        // we're visible there; if it's someone else's window, we're occluded.
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let number = info[kCGWindowNumber as String] as? Int,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                bounds.contains(center)
            else { continue }
            return CGWindowID(number) == windowID
        }
        return true
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
        // A slightly tighter corner than before (7 vs 10) so it hugs the window edge.
        let path = NSBezierPath(roundedRect: strokeRect, xRadius: 7, yRadius: 7)
        path.lineWidth = lineWidth

        // A soft, static glow so the frame reads as lit (not just a hairline). Drawn as a
        // wider, translucent, blurred stroke UNDER the crisp line — never animated.
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.75)
        glow.shadowBlurRadius = 9
        glow.shadowOffset = .zero
        glow.set()
        color.withAlphaComponent(0.5).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // The crisp accent line on top.
        color.withAlphaComponent(0.95).setStroke()
        path.stroke()
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
