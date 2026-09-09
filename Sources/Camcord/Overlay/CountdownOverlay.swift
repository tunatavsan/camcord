import AppKit

/// A CleanShot-style 3-2-1 countdown shown centered on the display about to be
/// recorded: gives the user a beat to tidy the screen and keeps the panel-close
/// animation + pointer parked on the record button out of the first frames.
/// Returns true to proceed; false when the user cancelled by clicking the badge.
@MainActor
enum CountdownOverlay {
    static func run(onScreenFrame frame: NSRect, seconds: Int = 3) async -> Bool {
        let size = CGSize(width: 128, height: 128)
        let origin = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        let panel = NSPanel(
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
        panel.contentView = view
        panel.orderFrontRegardless()

        defer { panel.orderOut(nil) }
        for n in stride(from: seconds, through: 1, by: -1) {
            view.show(n)
            // Sleep in short beats so a cancel click is honored within ~100ms.
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                if view.cancelled { return false }
            }
        }
        return true
    }
}

/// Dark translucent rounded badge: big digit + a small cancel hint. Click = cancel.
private final class CountdownView: NSView {
    private(set) var cancelled = false
    private let digit = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "iptal için tıkla")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 28
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Kayıt geri sayımı")
        setAccessibilityHelp("Geri sayımı iptal etmek için tıkla")

        digit.font = .monospacedDigitSystemFont(ofSize: 58, weight: .bold)
        digit.textColor = .white
        digit.alignment = .center
        digit.isBezeled = false
        digit.isEditable = false
        digit.backgroundColor = .clear
        addSubview(digit)

        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = NSColor.white.withAlphaComponent(0.55)
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
        digit.frame = CGRect(x: 0, y: bounds.midY - 34, width: bounds.width, height: 68)
        hint.frame = CGRect(x: 0, y: 14, width: bounds.width, height: 14)
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

    override func mouseDown(with event: NSEvent) { cancelled = true }

    override func accessibilityPerformPress() -> Bool {
        cancelled = true
        return true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
