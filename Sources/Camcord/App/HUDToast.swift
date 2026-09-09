import AppKit

/// What to show in a transient HUD toast. Passed from the capture/recording controllers
/// up to `AppDelegate`, which owns the single `HUDToast`.
struct ToastRequest {
    let text: String
    var thumbnail: NSImage? = nil
    var systemSymbol: String = "checkmark.circle.fill"
    var tint: NSColor = .systemGreen
    /// Bypasses the user's "show copy toast" preference (for important notices such as an
    /// automatic stop on low disk / max duration).
    var important: Bool = false
}

/// A small, transient "it landed" confirmation — a rounded HUD near the bottom of the
/// active screen with a thumbnail (or an SF Symbol) and a short message, e.g. what just
/// went to the clipboard. Auto-dismisses; writes nothing to disk. Non-activating and
/// click-through, so it never steals focus or blocks the window under it.
///
/// One instance is owned by `AppDelegate`; showing again while one is up replaces it.
@MainActor
final class HUDToast {
    /// Master on/off (default on). The visual companion to a copy is opt-out for anyone
    /// who finds transient HUDs distracting.
    static let enabledDefaultsKey = "copyToastEnabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledDefaultsKey) == nil ? true : defaults.bool(forKey: enabledDefaultsKey)
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledDefaultsKey)
    }

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// Shows the toast. `thumbnail` (a captured image) takes precedence over
    /// `systemSymbol` when both are given. `respectsSetting` false shows it regardless of
    /// the user preference (used for important auto-stop notices, not routine copies).
    func show(
        text: String,
        thumbnail: NSImage? = nil,
        systemSymbol: String = "checkmark.circle.fill",
        tint: NSColor = .systemGreen,
        respectsSetting: Bool = true,
        duration: TimeInterval = 1.4
    ) {
        if respectsSetting, !Self.isEnabled() { return }
        hide()

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }

        let content = ToastView(text: text, thumbnail: thumbnail, systemSymbol: systemSymbol, tint: tint)
        let size = content.fittingSize
        let origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.minY + 96
        )
        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()

        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 1
            }
        }
        self.panel = panel

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func fadeOut() {
        guard let panel else { return }
        self.panel = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        }
        // Order the panel out once the fade finishes. A @MainActor Task (we're already on
        // the main actor) keeps `panel` from crossing an actor boundary — unlike the
        // animation's nonisolated completion handler, which warns on the isolated call.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(240))
            panel.orderOut(nil)
        }
    }
}

/// The toast's content: a translucent HUD capsule with a leading thumbnail/glyph and a
/// message label.
private final class ToastView: NSVisualEffectView {
    init(text: String, thumbnail: NSImage?, systemSymbol: String, tint: NSColor) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = CamcordStyle.Radius.surface
        layer?.masksToBounds = true

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let iconSize: CGFloat = thumbnail != nil ? 40 : 22
        if let thumbnail {
            iconView.image = thumbnail
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.wantsLayer = true
            iconView.layer?.cornerRadius = CamcordStyle.Radius.control
            iconView.layer?.masksToBounds = true
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            iconView.image = NSImage(systemSymbolName: systemSymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            iconView.contentTintColor = tint
        }

        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        addSubview(iconView)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: thumbnail != nil ? 60 : 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }
}
