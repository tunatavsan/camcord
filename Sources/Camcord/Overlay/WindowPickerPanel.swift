import AppKit
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// A Discord-style "pick a window to record" surface: a centered floating panel showing a
/// grid of every capturable window with a live thumbnail + app icon/name. Selecting one
/// records THAT window via `SCContentFilter(desktopIndependentWindow:)`, which follows the
/// window across Spaces and keeps capturing it even when it's occluded or sent to the back —
/// the reliable way to grab a full-screen game the region overlay can't reach.
///
/// One instance is owned by `RecordingController`; `pick()` presents it and suspends until
/// the user chooses a window or dismisses (Esc / close button / clicking away is not
/// dismiss — the panel is explicit, like the system's).
@MainActor
final class WindowPickerPanel: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var continuation: CheckedContinuation<WindowPickerChoice?, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private let model = WindowPickerModel()

    /// Presents the picker for the windows in `content` and returns what the user chose,
    /// or nil if they dismissed it (or there was nothing to pick).
    func pick(content: SCShareableContent) async -> WindowPickerChoice? {
        guard window == nil else { return nil }   // one at a time
        var items = Self.eligibleWindows(content)
        if let card = Self.fullscreenCard(content: content, context: FullscreenContext.covering(), eligible: items) {
            items.insert(card, at: 0)
        }
        model.windows = items

        return await withCheckedContinuation { (c: CheckedContinuation<WindowPickerChoice?, Never>) in
            self.continuation = c
            present()
            startLoadingThumbnails()
        }
    }

    // MARK: - Presentation

    private func present() {
        let view = WindowPickerView(
            model: model,
            onPick: { [weak self] choice in self?.finish(with: choice) },
            onCancel: { [weak self] in self?.finish(with: nil) }
        )
        // The window tray, as the card and the preview stand on it: frost, rim and a shadow
        // cast outside, carrying the picker's glass cells.
        let hosting = NSHostingView(rootView: view)
        let inset = WindowPickerView.shadowInset
        let surface = TraySurface(content: hosting, shadowRadius: 16, cornerRadius: WindowPickerView.cornerRadius)
        let container = NSView(frame: CGRect(origin: .zero, size: CGSize(width: WindowPickerView.size.width + 2 * inset,
                                                                         height: WindowPickerView.size.height + 2 * inset)))
        surface.frame = container.bounds.insetBy(dx: inset, dy: inset)
        surface.autoresizingMask = [.width, .height]
        container.addSubview(surface)
        let window = WindowPickerWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        // An accessory (menu-bar) app has no key window by default; activate so the grid
        // takes clicks and Esc, and the picker comes to the front where the user expects it.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let layer = surface.layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.16
            let rise = CASpringAnimation.card(keyPath: "transform.translation.y", from: -10, to: 0, response: 0.38, dampingRatio: 0.8)
            rise.preferFullRefreshRate(on: window.screen)
            layer.add(fade, forKey: "picker-fade"); layer.add(rise, forKey: "picker-rise")
        }
    }

    private func startLoadingThumbnails() {
        let windows = model.windows
        thumbnailTask = Task { @MainActor [weak self] in
            // Sequential, front-to-back: the windows the user is most likely to pick fill in
            // first, and we never fan out many SCK grabs at once.
            var batch: [(CGWindowID, NSImage)] = []

            for item in windows {
                if Task.isCancelled { return }
                // The fullscreen card has no window to grab; its app icon is the placeholder.
                guard case .window(let scWindow) = item.choice else { continue }
                let image = try? await ScreenshotService.captureWindowThumbnail(scWindow, maxWidth: 480)
                if Task.isCancelled { return }

                if let image {
                    batch.append((item.id, NSImage(cgImage: image, size: .zero)))
                }

                if batch.count >= 4 {
                    self?.model.setThumbnails(batch)
                    batch.removeAll()
                }
            }

            if !batch.isEmpty {
                self?.model.setThumbnails(batch)
            }
        }
    }

    private func finish(with result: WindowPickerChoice?) {
        guard let continuation else { return }
        self.continuation = nil
        thumbnailTask?.cancel()
        thumbnailTask = nil
        if let window {
            window.delegate = nil
            window.orderOut(nil)
            self.window = nil
        }
        continuation.resume(returning: result)
    }

    /// The red close button (or Cmd-W) resolves as a cancel. Clicking away is NOT a
    /// dismiss — the class contract above promises an explicit panel (the user may
    /// alt-tab to double-check the target window before picking it).
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { finish(with: nil) }
    }

    // MARK: - Eligible windows

    private static func eligibleWindows(_ content: SCShareableContent) -> [PickableWindow] {
        let ownBundleID = Bundle.main.bundleIdentifier
        let displayFrames = content.displays.map(\.frame)
        var rejected = 0
        // content.windows is front-to-back, so the grid mirrors the on-screen z-order.
        let items: [PickableWindow] = content.windows.compactMap { window in
            let pid = window.owningApplication?.processID
            let runningApp = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
            // No title requirement: borderless/exclusive-fullscreen render windows (games)
            // often report an empty title — the grid cell falls back to the app name.
            let candidate = PickerCandidate(
                bundleID: window.owningApplication?.bundleIdentifier,
                appName: window.owningApplication?.applicationName ?? "",
                title: window.title ?? "",
                frame: window.frame,
                isOnScreen: window.isOnScreen,
                activationPolicy: runningApp?.activationPolicy
            )
            if let rejection = rejection(for: candidate, ownBundleID: ownBundleID, displayFrames: displayFrames) {
                rejected += 1
                // Our own windows are expected noise; every other rejection is written once
                // per open so a missing game window is explained by the file.
                if rejection != .ownApp { DiagnosticsLog.append(diagnosticsLine(candidate, rejection)) }
                return nil
            }
            return PickableWindow(
                id: window.windowID,
                choice: .window(window),
                bundleID: candidate.bundleID,
                frame: candidate.frame,
                appName: candidate.appName,
                title: candidate.title,
                appIcon: runningApp?.icon,
                aspect: window.frame.height > 0 ? window.frame.width / window.frame.height : 16.0 / 9.0
            )
        }
        DiagnosticsLog.append("picker open windows=\(content.windows.count) eligible=\(items.count) rejected=\(rejected)")
        return items
    }

    /// A game whose window the eligibility rules (or ScreenCaptureKit itself) never
    /// surfaced still has to be reachable: when the frontmost app covers a display and no
    /// eligible card belongs to it, offer the DISPLAY — the best capture path for a
    /// fullscreen game anyway (window-surface capture freezes when the game loses focus).
    private static func fullscreenCard(
        content: SCShareableContent,
        context: FullscreenContext,
        eligible: [PickableWindow]
    ) -> PickableWindow? {
        guard context.isGameLike,
              let bundleID = context.frontmostBundleID,
              let display = content.displays.first(where: { $0.displayID == context.displayID }),
              needsFullscreenCard(
                  bundleID: bundleID,
                  eligible: eligible.map { (bundleID: $0.bundleID, frame: $0.frame) },
                  displayFrame: display.frame
              )
        else { return nil }

        // Resolve the covering app itself: clicking our panel makes Camcord frontmost, which
        // is the reason `covering()` exists — so frontmost is only a last-resort name.
        let covering = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let frontmost = NSWorkspace.shared.frontmostApplication
        let name = content.applications.first { $0.bundleIdentifier == bundleID }?.applicationName
            ?? covering?.localizedName
            ?? frontmost?.localizedName
            ?? String(localized: "App", comment: "Window picker: an app whose name is unknown")
        DiagnosticsLog.append("picker fullscreen-card app=\(name) bundle=\(bundleID) display=\(context.displayID)")
        return PickableWindow(
            id: kCGNullWindowID,
            choice: .display(display),
            bundleID: bundleID,
            frame: display.frame,
            appName: name,
            title: String(localized: "\(name) — full screen", comment: "Window picker card: an app covering the whole screen"),
            appIcon: covering?.icon ?? frontmost?.icon,
            aspect: display.frame.height > 0 ? display.frame.width / display.frame.height : 16.0 / 9.0
        )
    }

    // MARK: - Decision table (pure, so the rules are testable without ScreenCaptureKit)

    /// True when the covering (game) window did not survive the eligibility rules, so the
    /// display card is the only way to reach it.
    static func needsFullscreenCard(
        bundleID: String,
        eligible: [(bundleID: String?, frame: CGRect)],
        displayFrame: CGRect
    ) -> Bool {
        !eligible.contains { $0.bundleID == bundleID && covers(frame: $0.frame, displayFrames: [displayFrame]) }
    }

    /// Nil when the window belongs in the grid; otherwise the rule that rejected it.
    static func rejection(
        for candidate: PickerCandidate,
        ownBundleID: String?,
        displayFrames: [CGRect]
    ) -> PickerRejection? {
        if let ownBundleID, candidate.bundleID == ownBundleID { return .ownApp }
        guard candidate.frame.width >= 80, candidate.frame.height >= 80 else { return .tooSmall }
        // Only windows of a user-facing GUI application: this keeps menu-bar apps,
        // background daemons, tooltips and the Desktop out, so SCK is not asked for
        // hundreds of invisible/uncapturable surfaces.
        guard let policy = candidate.activationPolicy else { return .noApplication }
        let coversDisplay = covers(frame: candidate.frame, displayFrames: displayFrames)
        // A fullscreen game can run as an .accessory app (no Dock tile). When its window
        // covers a whole display it is precisely the target the user came here for.
        guard policy == .regular || (policy == .accessory && coversDisplay) else { return .activationPolicy }
        // The cache queries with onScreenWindowsOnly: false so a fullscreen surface living
        // on another Space stays pickable — but ordinary off-screen/minimized windows
        // can't deliver frames, so only display-sized ones pass.
        guard candidate.isOnScreen || coversDisplay else { return .offScreen }
        return nil
    }

    static func covers(frame: CGRect, displayFrames: [CGRect]) -> Bool {
        displayFrames.contains { frame.width >= $0.width - 2 && frame.height >= $0.height - 2 }
    }

    /// One diagnostics line per rejected window: enough to say why the game is missing.
    static func diagnosticsLine(_ candidate: PickerCandidate, _ rejection: PickerRejection) -> String {
        let frame = candidate.frame
        let geometry = "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
        return "picker reject rule=\(rejection.rawValue)"
            + " app=\(candidate.appName.isEmpty ? "-" : candidate.appName)"
            + " bundle=\(candidate.bundleID ?? "-")"
            + " title=\(candidate.title.isEmpty ? "-" : candidate.title)"
            + " frame=\(geometry) onScreen=\(candidate.isOnScreen)"
            + " policy=\(policyName(candidate.activationPolicy))"
    }

    private static func policyName(_ policy: NSApplication.ActivationPolicy?) -> String {
        switch policy {
        case .some(.regular): "regular"
        case .some(.accessory): "accessory"
        case .some(.prohibited): "prohibited"
        case .some: "other"
        case .none: "no-app"
        }
    }
}

/// What the picker hands back: a window to capture directly, or the display a fullscreen
/// app covers when its own window is unreachable.
enum WindowPickerChoice {
    case window(SCWindow)
    case display(SCDisplay)
}

/// One window as the eligibility rules see it — primitives only, so the decision table
/// runs in tests without ScreenCaptureKit.
struct PickerCandidate {
    let bundleID: String?
    let appName: String
    let title: String
    let frame: CGRect
    let isOnScreen: Bool
    let activationPolicy: NSApplication.ActivationPolicy?
}

/// The rule that kept a window out of the grid; the raw value is what the log says.
enum PickerRejection: String {
    case ownApp = "own-app"
    case tooSmall = "smaller-than-80pt"
    case noApplication = "no-running-app"
    case activationPolicy = "not-regular-app"
    case offScreen = "off-screen-not-display-sized"
}

/// One entry the user can pick. Carries the live target to hand back on selection.
struct PickableWindow: Identifiable {
    let id: CGWindowID
    let choice: WindowPickerChoice
    let bundleID: String?
    let frame: CGRect
    let appName: String
    let title: String
    let appIcon: NSImage?
    let aspect: CGFloat
    var thumbnail: NSImage?
}

/// Observable list backing the grid; thumbnails are merged in as each capture completes.
@MainActor
final class WindowPickerModel: ObservableObject {
    @Published var windows: [PickableWindow] = []

    func setThumbnail(_ image: NSImage, for id: CGWindowID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].thumbnail = image
    }

    func setThumbnails(_ items: [(CGWindowID, NSImage)]) {
        for (id, image) in items {
            if let index = windows.firstIndex(where: { $0.id == id }) {
                windows[index].thumbnail = image
            }
        }
    }
}

// MARK: - SwiftUI

/// A borderless window that still takes the keyboard, for Esc and the grid.
private final class WindowPickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private struct WindowPickerView: View {
    @ObservedObject var model: WindowPickerModel
    let onPick: (WindowPickerChoice) -> Void
    let onCancel: () -> Void
    @State private var focus: CGWindowID?

    static let size = CGSize(width: 736, height: 540)
    static let shadowInset: CGFloat = 40
    /// Concentric with the cells inside: their radius plus the tray's ring.
    static let cornerRadius: CGFloat = Theme.Radius.floating + 8

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12)]

    var body: some View {
        VStack(spacing: 8) {
            header
                .frame(height: 64)
            Group {
                if model.windows.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(model.windows) { item in
                                WindowCell(item: item, focus: focus.map { $0 == item.id }) {
                                    onPick(item.choice)
                                } hover: { inside in
                                    if inside { focus = item.id } else if focus == item.id { focus = nil }
                                }
                            }
                        }
                        .padding(12)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .panelCell()
        }
        .padding(8)
        .frame(width: Self.size.width, height: Self.size.height)
        .foregroundStyle(Theme.Palette.ink.color)
        .onExitCommand(perform: onCancel)
    }

    private var header: some View {
        HStack(spacing: 12) {
            InkSymbol(name: "macwindow.on.rectangle", pointSize: 16, canvas: 26)
                .foregroundStyle(Theme.Palette.ink2.color)
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose a window to record")
                    .font(Theme.Font.bodyStrong)
                Text("Recording continues when the window is behind other apps")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.ink3.color)
            }
            Spacer()
            WindowPickerCancel(action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
        .panelCell()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            InkSymbol(name: "macwindow.badge.plus", pointSize: 20, canvas: 30)
                .foregroundStyle(Theme.Palette.ink3.color)
            Text("No windows available")
                .font(Theme.Font.bodyStrong)
                .foregroundStyle(Theme.Palette.ink2.color)
            Text("Open a window and try again")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.ink3.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The panel's quieter capsule button, with its soft bloom.
private struct WindowPickerCancel: View {
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Text("Cancel").font(Theme.Font.bodyStrong)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(hovered ? Theme.Palette.pressed.color : Theme.Palette.hover.color, in: .capsule)
                .overlay(Capsule().strokeBorder(.white.opacity(hovered ? 0.18 : 0.08), lineWidth: 1))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.14), value: hovered)
    }
}

/// One window: its live picture whole in a frame of one ratio over a muted blur of itself,
/// its app and title beneath. Hovered it lifts and the others step back; a click records it.
private struct WindowCell: View {
    let item: PickableWindow
    /// nil: nothing hovered; true: this one; false: another.
    let focus: Bool?
    let action: () -> Void
    let hover: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lifted = focus == true
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                thumbnail
                    .shadow(color: .black.opacity(lifted ? 0.32 : 0.12), radius: lifted ? 10 : 4, y: lifted ? 4 : 1)
                HStack(spacing: 7) {
                    if let icon = item.appIcon {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title.isEmpty ? item.appName : item.title)
                            .font(Theme.Font.captionStrong)
                            .lineLimit(1)
                        if !item.title.isEmpty {
                            Text(item.appName)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.ink3.color)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 2)
            }
            .scaleEffect(lifted && !reduceMotion ? 1.03 : 1)
            .offset(y: lifted && !reduceMotion ? -3 : 0)
            .opacity(focus == false ? 0.6 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover(perform: hover)
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.65), value: focus)
        .accessibilityLabel(item.title.isEmpty ? item.appName : item.title)
        .accessibilityValue(item.title.isEmpty ? "" : item.appName)
        .accessibilityHint("Select this window for recording")
    }

    private var thumbnail: some View {
        ZStack {
            Theme.Palette.well.color
            if let thumb = item.thumbnail {
                Color.clear.overlay {
                    Image(nsImage: thumb).resizable().scaledToFill().blur(radius: 14).saturation(0.75)
                }
                .clipped()
                Color.black.opacity(0.3)
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .padding(6)
            } else if let icon = item.appIcon {
                Image(nsImage: icon).resizable().frame(width: 46, height: 46).opacity(0.7)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: Theme.Radius.thumb, style: .continuous))
    }
}
