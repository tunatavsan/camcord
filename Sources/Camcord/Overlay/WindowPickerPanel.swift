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
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        window.center()
        self.window = window

        // An accessory (menu-bar) app has no key window by default; activate so the grid
        // takes clicks and Esc, and the picker comes to the front where the user expects it.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
            ?? "Uygulama"
        DiagnosticsLog.append("picker fullscreen-card app=\(name) bundle=\(bundleID) display=\(context.displayID)")
        return PickableWindow(
            id: kCGNullWindowID,
            choice: .display(display),
            bundleID: bundleID,
            frame: display.frame,
            appName: name,
            title: "\(name) — tam ekran",
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
        // covers a whole display it is precisely the target the owner came here for.
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

private struct WindowPickerView: View {
    @ObservedObject var model: WindowPickerModel
    let onPick: (WindowPickerChoice) -> Void
    let onCancel: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 208, maximum: 260), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.windows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.windows) { item in
                            WindowCell(item: item) { onPick(item.choice) }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 736, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: onCancel)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Kaydedilecek pencereyi seç")
                    .font(.system(size: 14, weight: .semibold))
                Text("Seçtiğin pencere arkaya atılsa bile kaydedilmeye devam eder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onCancel) {
                Text("İptal").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Kaydedilecek uygun pencere bulunamadı")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Bir uygulama penceresi aç ve tekrar dene.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A single window tile: live thumbnail (or an app-icon placeholder while it loads), with
/// the app icon + window title beneath. Soft hover lift; click records it.
private struct WindowCell: View {
    let item: PickableWindow
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                thumbnail
                HStack(spacing: 7) {
                    if let icon = item.appIcon {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title.isEmpty ? item.appName : item.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if !item.title.isEmpty {
                            Text(item.appName)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(hovering ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor.opacity(hovering ? 0.9 : 0), lineWidth: 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityLabel(item.title.isEmpty ? item.appName : item.title)
        .accessibilityValue(item.title.isEmpty ? "" : item.appName)
        .accessibilityHint("Bu pencereyi kaydetmek için seç")
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.28))
            if let thumb = item.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let icon = item.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 46, height: 46)
                    .opacity(0.7)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 128)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
