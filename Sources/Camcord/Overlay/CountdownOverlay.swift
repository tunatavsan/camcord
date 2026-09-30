import AppKit

/// A CleanShot-style 3-2-1 countdown shown centered on the display about to be
/// recorded: gives the user a beat to tidy the screen and keeps the panel-close
/// animation + pointer parked on the record button out of the first frames.
/// Returns true to proceed; false on task cancellation, Esc, clicking the badge or an accessible press.
@MainActor
enum CountdownOverlay {
    static func run(onScreenFrame frame: NSRect, seconds: Int = 3,
                    presenter: (@MainActor (NSPanel) -> Void)? = nil,
                    sleepBeat: @escaping @MainActor () async throws -> Void = {
                        try await Task.sleep(for: .milliseconds(100))
                    }) async -> Bool {
        guard !Task.isCancelled else { return false }
        let size = CGSize(width: 140, height: 140)
        let origin = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        let panel = CountdownPanel(
            contentRect: CGRect(origin: origin, size: size),
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
        panel.ignoresMouseEvents = false

        let view = CountdownView(frame: CGRect(origin: .zero, size: size))
        let chrome = CountdownChrome()
        chrome.applyCamcord(.hud, cornerRadius: 70)
        chrome.badge = view
        chrome.setAccessibilityElement(true)
        chrome.setAccessibilityRole(.button)
        chrome.setAccessibilityLabel(String(localized: "Recording countdown"))
        chrome.setAccessibilityHelp(String(localized: "Cancel the recording countdown"))
        chrome.setAccessibilityChildren([])
        chrome.contentView = view
        panel.contentView = chrome
        panel.makeFirstResponder(view)
        if let presenter { presenter(panel) } else {
            panel.orderFrontRegardless()
            panel.makeKey() // A nonactivating panel receives Esc without activating Camcord.
        }

        defer { panel.orderOut(nil) }
        for n in stride(from: seconds, through: 1, by: -1) {
            view.show(n)
            chrome.setAccessibilityValue("\(n)")
            // Sleep in short beats so a cancel click is honored within ~100ms.
            for _ in 0..<10 {
                do { try await sleepBeat() } catch { return false }
                if Task.isCancelled || view.cancelled { return false }
            }
        }
        return !Task.isCancelled && !view.cancelled
    }
}

private final class CountdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Dark translucent rounded badge: big digit + a small cancel hint. Click = cancel.
private final class CountdownView: NSView {
    private(set) var cancelled = false
    private let digit = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: String(localized: "Click or press Esc to cancel", comment: "Countdown cancellation hint"))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = Theme.Radius.floating
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Recording countdown", comment: "Accessibility: recording countdown badge"))
        setAccessibilityHelp(String(localized: "Cancel the recording countdown", comment: "Accessibility: countdown cancellation action"))

        digit.font = Theme.Font.ns.mono(Theme.Font.Size.countdown, weight: .light)
        digit.textColor = Theme.Palette.ink.dark.nsColor
        digit.alignment = .center
        digit.isBezeled = false
        digit.isEditable = false
        digit.backgroundColor = .clear
        addSubview(digit)

        hint.font = Theme.Font.ns.caption
        hint.textColor = Theme.Palette.ink2.dark.nsColor
        hint.alignment = .center
        hint.isBezeled = false
        hint.isEditable = false
        hint.backgroundColor = .clear
        addSubview(hint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        digit.frame = CGRect(x: 0, y: bounds.midY - 20, width: bounds.width, height: 68)
        hint.frame = CGRect(x: 4, y: 18, width: bounds.width - 8, height: 28)
        hint.maximumNumberOfLines = 2
        hint.lineBreakMode = .byWordWrapping
    }

    func show(_ number: Int) {
        digit.stringValue = "\(number)"
        setAccessibilityValue("\(number)")
        // A quick settle-pop per beat, matching the app's spring signature.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            digit.layer?.removeAnimation(forKey: "pop")
            return
        }
        guard let layer = digit.layer else { return }
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 1.18
        pop.toValue = 1
        pop.mass = 1
        pop.stiffness = 210
        pop.damping = 19
        pop.duration = pop.settlingDuration
        layer.add(pop, forKey: "pop")
    }

    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { cancelled = true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) } else { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) { cancelled = true }

    override func accessibilityPerformPress() -> Bool {
        cancelled = true
        return true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The native chrome is the public event/AX target; it forwards to the same cancellation
/// state the countdown loop observes, including callers that act on panel.contentView.
private final class CountdownChrome: NSGlassEffectView {
    weak var badge: NSView?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { badge?.keyDown(with: event) }
    override func cancelOperation(_ sender: Any?) { badge?.cancelOperation(sender) }
    override func mouseDown(with event: NSEvent) { badge?.mouseDown(with: event) }
    override func accessibilityPerformPress() -> Bool { badge?.accessibilityPerformPress() ?? false }
}
