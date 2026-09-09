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
    private var continuation: CheckedContinuation<SCWindow?, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private let model = WindowPickerModel()

    /// Presents the picker for the windows in `content` and returns the chosen `SCWindow`,
    /// or nil if the user dismissed it (or there was nothing to pick).
    func pick(content: SCShareableContent) async -> SCWindow? {
        guard window == nil else { return nil }   // one at a time
        model.windows = Self.eligibleWindows(content)

        return await withCheckedContinuation { (c: CheckedContinuation<SCWindow?, Never>) in
            self.continuation = c
            present()
            startLoadingThumbnails()
        }
    }

    // MARK: - Presentation

    private func present() {
        let view = WindowPickerView(
            model: model,
            onPick: { [weak self] window in self?.finish(with: window) },
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
                let image = try? await ScreenshotService.captureWindowThumbnail(item.window, maxWidth: 480)
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

    private func finish(with result: SCWindow?) {
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
        // content.windows is front-to-back, so the grid mirrors the on-screen z-order.
        return content.windows.compactMap { window in
            // No title requirement: borderless/exclusive-fullscreen render windows (games)
            // often report an empty title — the grid cell falls back to the app name.
            guard window.owningApplication?.bundleIdentifier != ownBundleID,
                  window.frame.width >= 80, window.frame.height >= 80
            else { return nil }

            let pid = window.owningApplication?.processID
            let runningApp = pid.flatMap { NSRunningApplication(processIdentifier: $0) }

            // Only allow windows that belong to a standard user-facing GUI application.
            // This filters out menu bar apps, background daemons, tooltips, and the Desktop,
            // preventing SCK from choking on hundreds of invisible/uncapturable windows.
            guard let runningApp, runningApp.activationPolicy == .regular else {
                return nil
            }
            // The cache queries with onScreenWindowsOnly: false so a fullscreen surface
            // living on another Space stays pickable — but ordinary off-screen/minimized
            // windows can't deliver frames, so only display-sized ones pass.
            if !window.isOnScreen {
                guard content.displays.contains(where: {
                    window.frame.width >= $0.frame.width - 2 && window.frame.height >= $0.frame.height - 2
                }) else { return nil }
            }
            let icon = runningApp.icon
            return PickableWindow(
                id: window.windowID,
                window: window,
                appName: window.owningApplication?.applicationName ?? "",
                title: window.title ?? "",
                appIcon: icon,
                aspect: window.frame.height > 0 ? window.frame.width / window.frame.height : 16.0 / 9.0
            )
        }
    }
}

/// One window the user can pick. Carries the live `SCWindow` to hand back on selection.
struct PickableWindow: Identifiable {
    let id: CGWindowID
    let window: SCWindow
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
    let onPick: (SCWindow) -> Void
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
                            WindowCell(item: item) { onPick(item.window) }
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
