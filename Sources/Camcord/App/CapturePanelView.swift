import AVFoundation
import AppKit
import SwiftUI

/// Shared recording state for SwiftUI surfaces (the panel). Pushed by
/// `RecordingController.onUIChange` via AppDelegate — single source of truth, the
/// same feed that drives the status-item glyph.
@MainActor
final class RecordingStateModel: ObservableObject {
    @Published var state: RecordingController.UIState = .idle
    @Published var elapsed: String?
    /// True from the moment Stop is pressed until the file is finalized on disk.
    @Published var isFinishing = false
    /// The just-finished recording, shown as a "done" card until dismissed / reopened.
    @Published var finishedURL: URL?
    /// Bumped by PanelController on every show. The popover's hosting controller is
    /// retained across shows, so `@State` persists and `onAppear` fires only once —
    /// this token re-reads persisted toggles per open.
    @Published var panelOpenToken = 0
}

/// The panel's actions, injected by AppDelegate. Each closure owns its own
/// popover-closing/delay choreography.
@MainActor
struct PanelActions {
    var captureRegion: () -> Void = {}
    var captureWindow: () -> Void = {}
    var captureScreen: () -> Void = {}
    /// Scrolling capture — the whole scrollable area stitched into one tall image.
    var captureScroll: () -> Void = {}
    /// Start an interactive recording when idle; stop it otherwise.
    var toggleRecording: () -> Void = {}
    var recordFullScreen: () -> Void = {}
    var pauseResume: () -> Void = {}
    var revealRecording: (URL) -> Void = { _ in }
    var openRecording: (URL) -> Void = { _ in }
    /// Reveal the newest saved screenshot in Finder.
    var revealScreenshot: (URL) -> Void = { _ in }
    var openSettings: () -> Void = {}
}

/// The menu-bar panel: one quiet page, 268pt wide. A capture grid (region / window /
/// full-screen / text), a recording row that morphs into a live session bar, and a
/// footer of quick toggles plus the gear that opens the full Settings window.
/// Everything heavier (shortcuts, mouse bindings, quality) lives in Settings.
struct CapturePanelView: View {
    @ObservedObject var model: RecordingStateModel
    let actions: PanelActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recordSystemAudio = true
    @State private var recordMicrophone = true
    @State private var soundEnabled = true
    @State private var saveScreenshots = false
    @State private var isMicrophoneDenied = false
    @State private var lastRecordingURL: URL?
    @State private var lastScreenshotURL: URL?

    /// One physical signature for every elastic transition in the panel.
    static let panelSpring: Animation = .spring(response: 0.34, dampingFraction: 0.86)

    /// Fixed width; the height switches between the compact grid and the taller "done"
    /// card (which carries rename + metadata). A definite size per state keeps the
    /// popover beak anchored correctly under the status item.
    static let panelWidth: CGFloat = 268
    static let panelHeight: CGFloat = 178
    static let finishedHeight: CGFloat = 306

    private var currentHeight: CGFloat {
        model.finishedURL != nil ? Self.finishedHeight : Self.panelHeight
    }

    var body: some View {
        ZStack {
            if let url = model.finishedURL {
                FinishedCard(
                    url: url,
                    reveal: actions.revealRecording,
                    open: actions.openRecording,
                    dismiss: { model.finishedURL = nil }
                )
                .transition(.opacity)
            } else if model.isFinishing {
                FinishingCard()
                    .transition(.opacity)
            } else {
                mainContent
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.panelWidth, height: currentHeight)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: currentHeight)
        // A near-opaque backdrop so the panel reads as a solid control surface, not a
        // see-through pane of glass over whatever is behind it.
        .background(PanelBackdrop())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.finishedURL)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.isFinishing)
        .onAppear(perform: reloadPersistedState)
        .onChange(of: model.panelOpenToken) { _, _ in
            // A fresh open always returns to the capture grid.
            model.finishedURL = nil
            reloadPersistedState()
        }
    }

    private var mainContent: some View {
        VStack(spacing: 10) {
            captureGrid

            recordRow
                .animation(reduceMotion ? nil : Self.panelSpring, value: model.state)

            PanelDivider()
                .padding(.vertical, 2)

            footer
        }
        .padding(12)
    }

    // MARK: - Capture grid

    private var captureGrid: some View {
        HStack(spacing: 6) {
            CaptureTile(symbol: "rectangle.dashed", title: "Bölge", action: actions.captureRegion)
            CaptureTile(symbol: "macwindow", title: "Pencere", action: actions.captureWindow)
            CaptureTile(symbol: "display", title: "Ekran", action: actions.captureScreen)
            CaptureTile(symbol: "doc.viewfinder", title: "Kaydır", action: actions.captureScroll)
        }
    }

    // MARK: - Recording row

    @ViewBuilder
    private var recordRow: some View {
        switch model.state {
        case .idle:
            HStack(spacing: 6) {
                HoverScaleButton(action: actions.toggleRecording) { hovering in
                    HStack(spacing: 9) {
                        ZStack {
                            Circle().fill(.red.opacity(hovering ? 0.22 : 0)).frame(width: 18, height: 18)
                            Circle().fill(.red).frame(width: 8, height: 8)
                        }
                        Text("Kayıt başlat")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.primary.opacity(hovering ? 0.07 : 0.045))
                    )
                }
                RecordTargetButton(symbol: "display", help: "Tüm ekranı kaydet", action: actions.recordFullScreen)
            }

        case .recording, .paused:
            HStack(spacing: 9) {
                PulsingDot(paused: model.state == .paused, reduceMotion: reduceMotion)
                Text(model.elapsed ?? "0:00")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .default, value: model.elapsed)
                if model.state == .paused {
                    Text("duraklatıldı")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.62))
                }
                Spacer()
                RoundIconButton(
                    symbol: model.state == .paused ? "play.fill" : "pause.fill",
                    help: model.state == .paused ? "Sürdür" : "Duraklat",
                    action: actions.pauseResume
                )
                RoundIconButton(symbol: "stop.fill", tint: .red, help: "Kaydı bitir", action: actions.toggleRecording)
            }
            .padding(.horizontal, 11)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill((model.state == .paused ? Color.orange : .red).opacity(model.state == .paused ? 0.07 : 0.11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                (model.state == .paused ? Color.orange : .red)
                                    .opacity(model.state == .paused ? 0.12 : 0.2),
                                lineWidth: 1
                            )
                    )
            )
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 5) {
            ToggleChip(
                onSymbol: "speaker.wave.2.fill", offSymbol: "speaker.slash.fill",
                help: "Sistem sesini kaydet", isOn: $recordSystemAudio
            ) {
                saveRecordingSettings()
            }
            ToggleChip(
                onSymbol: "mic.fill", offSymbol: "mic.slash.fill",
                help: isMicrophoneDenied ? "Mikrofonu kaydet — mikrofon İZNİ YOK" : "Mikrofonu kaydet",
                warning: isMicrophoneDenied,
                isOn: $recordMicrophone
            ) {
                saveRecordingSettings()
            }
            ToggleChip(onSymbol: "bell.fill", offSymbol: "bell.slash.fill", help: "Geri bildirim sesleri", isOn: $soundEnabled) {
                FeedbackSound.setEnabled(soundEnabled)
            }
            ToggleChip(
                onSymbol: "square.and.arrow.down.fill", offSymbol: "square.and.arrow.down",
                help: "Ekran görüntülerini diske de kaydet", isOn: $saveScreenshots
            ) {
                var s = ScreenshotSettings.load(from: .standard)
                s.saveToDisk = saveScreenshots
                s.save(to: .standard)
            }

            Spacer()

            if let url = lastScreenshotURL {
                FooterIconButton(symbol: "photo", help: "Son ekran görüntüsünü Finder'da göster") {
                    actions.revealScreenshot(url)
                }
            }
            if let url = lastRecordingURL {
                FooterIconButton(symbol: "film", help: "Son kaydı Finder'da göster") {
                    actions.revealRecording(url)
                }
            }
            FooterIconButton(symbol: "gearshape.fill", help: "Ayarlar", action: actions.openSettings)
        }
    }

    // MARK: - Persistence

    private func reloadPersistedState() {
        let settings = RecordingSettings.load(from: .standard)
        recordSystemAudio = settings.systemAudio
        recordMicrophone = settings.microphone
        soundEnabled = FeedbackSound.isEnabled()
        saveScreenshots = ScreenshotSettings.load(from: .standard).saveToDisk
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        isMicrophoneDenied = micStatus == .denied || micStatus == .restricted
        // A single directory listing per open — cheap for a personal capture folder, and
        // reliably synchronous so the reveal buttons always reflect the latest files
        // (an async .task can be skipped by the retained popover hosting controller).
        lastRecordingURL = Self.newestRecording()
        lastScreenshotURL = Self.newestScreenshot()
    }

    /// The most recently modified recording in the output folder, or nil. Matches ALL
    /// container types the app can produce (mp4 is now the default, mov for ProRes) so
    /// the reveal button appears regardless of the chosen codec/container.
    private static func newestRecording() -> URL? {
        let settings = RecordingSettings.load(from: .standard)
        let dirPath = settings.outputDirectoryPath ?? RecordingSettings.defaultDirectoryPath()
        return newestFile(inDirectory: dirPath, exts: ["mp4", "mov", "m4v"])
    }

    /// The most recently modified `.png` in the screenshot output folder, or nil.
    /// (Region shots and scrolling captures both land here when disk-saving is on.)
    private static func newestScreenshot() -> URL? {
        let settings = ScreenshotSettings.load(from: .standard)
        let dirPath = (settings.saveDirectoryPath?.isEmpty == false)
            ? settings.saveDirectoryPath!
            : ScreenshotSettings.defaultDirectoryPath()
        return newestFile(inDirectory: dirPath, exts: ["png"])
    }

    /// The most recently modified file whose extension is in `exts`, in `dirPath`, or nil.
    private static func newestFile(inDirectory dirPath: String, exts: Set<String>) -> URL? {
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        let key: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: key, options: [.skipsHiddenFiles]
        ) else { return nil }
        return urls
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da < db
            }
    }

    private func saveRecordingSettings() {
        var settings = RecordingSettings.load(from: .standard)
        settings.systemAudio = recordSystemAudio
        settings.microphone = recordMicrophone
        settings.save(to: .standard)
    }
}

/// A near-solid, appearance-adaptive backdrop that sits over the popover's own
/// translucent material so the panel reads as a solid surface rather than glass.
private struct PanelBackdrop: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
    }
}

// MARK: - Recording finished / finishing

/// The "recording is being finalized" state — shown for the brief window between
/// pressing Stop and the moov atom being written, so the panel never flashes back to
/// the capture grid first.
private struct FinishingCard: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Kaydediliyor…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 12)
    }
}

/// The "recording done" card: an animated check, an inline RENAME field, file metadata
/// (size + duration + dimensions), and reveal/open actions. Stays until dismissed or the
/// panel is reopened — it deliberately does NOT snap back to the capture grid.
private struct FinishedCard: View {
    let reveal: (URL) -> Void
    let open: (URL) -> Void
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var currentURL: URL
    @State private var name: String
    @State private var meta: RecordingMeta?

    init(url: URL, reveal: @escaping (URL) -> Void, open: @escaping (URL) -> Void, dismiss: @escaping () -> Void) {
        self.reveal = reveal
        self.open = open
        self.dismiss = dismiss
        _currentURL = State(initialValue: url)
        _name = State(initialValue: url.deletingPathExtension().lastPathComponent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(.green.opacity(0.14)).frame(width: 28, height: 28)
                        .scaleEffect(appeared ? 1 : 0.5).opacity(appeared ? 1 : 0)
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.green)
                        .scaleEffect(appeared ? 1 : 0.2).opacity(appeared ? 1 : 0)
                }
                Text("Kayıt bitti").font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            // Inline rename: edit the stem; the extension is fixed. Commits on Enter and
            // when an action is taken.
            HStack(spacing: 4) {
                TextField("Ad", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { commitRename() }
                Text("." + currentURL.pathExtension)
                    .font(.system(size: 11)).monospaced()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                MetaLabel(symbol: "internaldrive", text: meta?.size ?? "…")
                MetaLabel(symbol: "clock", text: meta?.duration ?? "…")
                if let dims = meta?.dimensions {
                    MetaLabel(symbol: "rectangle.ratio.16.to.9", text: dims)
                }
                Spacer()
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)

            Spacer(minLength: 2)

            HStack(spacing: 8) {
                CardButton(title: "Finder'da Göster", symbol: "folder") { commitRename(); reveal(currentURL) }
                CardButton(title: "Aç", symbol: "play.fill", prominent: true) { commitRename(); open(currentURL) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(12)
        .overlay(alignment: .topTrailing) {
            HoverScaleButton(action: dismiss) { hovering in
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            }
            .padding(6)
            .help("Kapat")
        }
        .onAppear {
            if reduceMotion { appeared = true }
            else { withAnimation(.spring(response: 0.5, dampingFraction: 0.58)) { appeared = true } }
        }
        .task(id: currentURL) { meta = await RecordingMeta.load(currentURL) }
    }

    /// Renames the file on disk (sanitized, collision-safe) and re-copies the new URL to
    /// the clipboard so a paste yields the renamed file. No-op if unchanged/taken/invalid.
    private func commitRename() {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)).joined()
            .trimmingCharacters(in: .whitespaces)
        let original = currentURL.deletingPathExtension().lastPathComponent
        guard !cleaned.isEmpty, cleaned != original else { name = original; return }
        let target = currentURL.deletingLastPathComponent()
            .appendingPathComponent(cleaned).appendingPathExtension(currentURL.pathExtension)
        guard !FileManager.default.fileExists(atPath: target.path) else { name = original; return }
        do {
            try FileManager.default.moveItem(at: currentURL, to: target)
            currentURL = target
            name = cleaned
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([target as NSURL])
        } catch {
            name = original
        }
    }
}

/// A small icon + value pair for the finished card's metadata row.
private struct MetaLabel: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(text).monospacedDigit()
        }
    }
}

/// Recording metadata for the finished card, loaded off the main thread via AVFoundation.
private struct RecordingMeta {
    let size: String
    let duration: String
    let dimensions: String?

    static func load(_ url: URL) async -> RecordingMeta {
        let asset = AVURLAsset(url: url)
        var durationText = "—"
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds >= 0 { durationText = timeString(seconds) }
        }
        var dims: String?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
            let natural = try? await track.load(.naturalSize) {
            dims = "\(Int(abs(natural.width)))×\(Int(abs(natural.height)))"
        }
        return RecordingMeta(size: byteString(url), duration: durationText, dimensions: dims)
    }

    private static func byteString(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private static func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A pill button used in the finished card. `prominent` gives it a filled accent look.
private struct CardButton: View {
    let title: String
    let symbol: String
    var prominent: Bool = false
    let action: () -> Void

    var body: some View {
        HoverScaleButton(action: action) { hovering in
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(prominent
                        ? AnyShapeStyle(Color.accentColor.opacity(hovering ? 0.95 : 0.85))
                        : AnyShapeStyle(Color.primary.opacity(hovering ? 0.11 : 0.07)))
            )
        }
        .help(title)
    }
}

// MARK: - Components

/// One capture action: icon over a tiny label, generous hit target, soft hover fill,
/// gentle press scale.
private struct CaptureTile: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        HoverScaleButton(action: action) { hovering in
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(height: 20)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    // .secondary measures ~3.8:1 against the light-mode backdrop at
                    // this size — a fixed 0.62 primary clears 4.5:1 in both schemes.
                    .foregroundStyle(Color.primary.opacity(0.62))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(hovering ? 0.11 : 0.045))
            )
        }
        .help(title)
    }
}

/// The recording indicator: solid when paused, breathing while live.
private struct PulsingDot: View {
    let paused: Bool
    let reduceMotion: Bool
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(paused ? Color.orange : .red)
            .frame(width: 9, height: 9)
            .opacity(dimmed && !paused && !reduceMotion ? 0.35 : 1)
            .animation(
                paused || reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: dimmed
            )
            .onAppear { dimmed = true }
    }
}

/// Small circular control inside the live-recording bar.
private struct RoundIconButton: View {
    let symbol: String
    var tint: Color? = nil
    let help: String
    let action: () -> Void

    var body: some View {
        HoverScaleButton(action: action) { hovering in
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill((tint ?? Color.primary).opacity(
                            tint == nil ? (hovering ? 0.13 : 0.07) : (hovering ? 0.16 : 0.09)
                        ))
                )
        }
        .help(help)
    }
}

/// Secondary recording target next to the primary "Kayıt başlat" (e.g. full screen).
private struct RecordTargetButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        HoverScaleButton(action: action) { hovering in
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(hovering ? 0.07 : 0.045))
                )
        }
        .help(help)
    }
}

/// Footer toggle: filled symbol when on, slashed + faint when off. `warning` tints the
/// symbol orange (e.g. mic wanted but the OS permission is denied).
private struct ToggleChip: View {
    let onSymbol: String
    let offSymbol: String
    let help: String
    var warning: Bool = false
    @Binding var isOn: Bool
    let onChange: () -> Void

    var body: some View {
        HoverScaleButton(action: {
            isOn.toggle()
            onChange()
        }) { hovering in
            Image(systemName: isOn ? onSymbol : offSymbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(
                    warning && isOn
                        ? AnyShapeStyle(Color.orange)
                        : isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary)
                )
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(isOn ? (hovering ? 0.12 : 0.08) : (hovering ? 0.05 : 0)))
                )
        }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

private struct FooterIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        HoverScaleButton(action: action) { hovering in
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(hovering ? 0.07 : 0))
                )
        }
        .help(help)
    }
}

private struct PanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
    }
}

/// Shared hover + press treatment: content closure receives the hover flag; the button
/// applies a gentle press scale. One motion language for every control.
private struct HoverScaleButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            content(hovering)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PressScaleStyle(reduceMotion: reduceMotion))
        .onHover { isHovering in
            if reduceMotion {
                hovering = isHovering
            } else {
                withAnimation(.easeOut(duration: 0.14)) {
                    hovering = isHovering
                }
            }
        }
    }
}

private struct PressScaleStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
