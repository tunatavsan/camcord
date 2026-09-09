import AVFoundation
import AppKit
import KeyboardShortcuts
import SwiftUI

/// Shared recording state for SwiftUI surfaces (the panel). Pushed by
/// `RecordingController.onUIChange` via AppDelegate — single source of truth, the
/// same feed that drives the status-item glyph.
@MainActor
final class RecordingStateModel: ObservableObject {
    @Published var state: RecordingController.UIState = .idle
    @Published var elapsed: String?
    @Published var health: RecordingHealth?
    /// True from the moment Stop is pressed until the file is finalized on disk.
    @Published var isFinishing = false
    /// The just-finished recording, shown as a "done" card until dismissed / reopened.
    @Published var finishedURL: URL?
    /// Bumped by PanelController on every show. The popover's hosting controller is
    /// retained across shows, so `@State` persists and `onAppear` fires only once —
    /// this token re-reads persisted toggles per open.
    @Published var panelOpenToken = 0
    @Published var isPanelVisible = false
    @Published var isStarting = false
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
    /// Open the window picker and record the chosen window.
    var recordWindow: () -> Void = {}
    var recordFullScreen: () -> Void = {}
    var pauseResume: () -> Void = {}
    var revealRecording: (URL) -> Void = { _ in }
    var openRecording: (URL) -> Void = { _ in }
    /// Reveal the newest saved screenshot in Finder.
    var revealScreenshot: (URL) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var reportError: (String) -> Void = { _ in }
}

/// The menu-bar capture palette: a stable 320-point native surface for capture,
/// recording, live audio, and the two output libraries.
struct CapturePanelView: View {
    @ObservedObject var model: RecordingStateModel
    let actions: PanelActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.camcordDesignPreview) private var designPreview
    @State private var cameraEnabled = false
    @State private var recordSystemAudio = true
    @State private var recordMicrophone = true
    @State private var systemGainDB: Double = 0
    @State private var microphoneGainDB: Double = 0
    @State private var soundEnabled = true
    @State private var saveScreenshots = false
    @State private var isMicrophoneDenied = false
    @State private var lastRecordingURL: URL?
    @State private var lastScreenshotURL: URL?
    @State private var shortcuts = PanelShortcuts()
    @State private var recordingDirectoryURL = URL(
        fileURLWithPath: RecordingSettings.defaultDirectoryPath(), isDirectory: true
    )
    @State private var screenshotDirectoryURL = URL(
        fileURLWithPath: ScreenshotSettings.defaultDirectoryPath(), isDirectory: true
    )

    /// One physical signature for every elastic transition in the panel.
    static let panelSpring: Animation = .spring(response: 0.22, dampingFraction: 0.84)

    /// Fixed width; the height switches between the compact grid and the taller "done"
    /// card (which carries rename + metadata). A definite size per state keeps the
    /// popover beak anchored correctly under the status item.
    static let panelWidth: CGFloat = 320
    static let panelHeight: CGFloat = 458
    static let activeHeight: CGFloat = 458
    static let finishingHeight: CGFloat = 220
    static let finishedHeight: CGFloat = 418

    private var currentHeight: CGFloat {
        if model.finishedURL != nil { return Self.finishedHeight }
        if model.isFinishing { return Self.finishingHeight }
        if model.state != .idle { return Self.activeHeight }
        return Self.panelHeight
    }

    var body: some View {
        ZStack {
            if let url = model.finishedURL {
                FinishedCard(
                    url: url,
                    reveal: actions.revealRecording,
                    open: actions.openRecording,
                    renamed: { renamedURL in
                        // An outside click or a recording shortcut can remove this
                        // card while its file move awaits. Update matching ownership
                        // only; never resurrect it over a newer live recording.
                        let ownsCard = model.finishedURL == url
                        if ownsCard { model.finishedURL = renamedURL }
                        if ownsCard || lastRecordingURL == url { lastRecordingURL = renamedURL }
                    },
                    dismiss: { model.finishedURL = nil }
                )
                .transition(panelTransition)
            } else if model.isFinishing {
                FinishingCard()
                    .transition(panelTransition)
            } else {
                mainContent
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(panelTransition)
            }
        }
        .frame(width: Self.panelWidth, height: currentHeight)
        .animation(reduceMotion ? nil : Self.panelSpring, value: currentHeight)
        .background {
            CamcordMaterial()
                .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.18))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(CamcordStyle.innerBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(reduceMotion ? nil : Self.panelSpring, value: model.finishedURL)
        .animation(reduceMotion ? nil : Self.panelSpring, value: model.isFinishing)
        .onAppear(perform: reloadPersistedState)
        .onChange(of: model.panelOpenToken) { _, _ in
            // A fresh open always returns to the capture grid.
            model.finishedURL = nil
            reloadPersistedState()
        }
        .onChange(of: model.finishedURL) { _, url in
            guard let url else { return }
            lastRecordingURL = url
            recordingDirectoryURL = url.deletingLastPathComponent()
        }
        .onChange(of: model.isPanelVisible) { _, visible in
            guard !designPreview else { return }
            if visible {
                if cameraEnabled { CameraOverlayController.shared.showPreview() }
            } else if !CameraPreviewMonitor.shared.recordingLocked {
                CameraOverlayController.shared.hide()
            }
        }
        // The hosting controller is retained across opens, so key this task to the explicit
        // open token. SwiftUI cancels the previous scan; the generation/path guards below
        // also reject a synchronous directory read that finished after cancellation.
        .task(id: model.panelOpenToken) {
            guard !designPreview else { return }
            await reloadCaptureLibrary(generation: model.panelOpenToken)
        }
    }

    private var panelTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4))
    }

    private var mainContent: some View {
        VStack(spacing: 12) {
            header
            captureGrid

            recordRow
                .frame(height: 84, alignment: .top)
                .animation(reduceMotion ? nil : Self.panelSpring, value: model.state)

            VStack(spacing: 8) {
                    AudioControlRow(title: "Sistem", symbol: "speaker.wave.2", health: model.health?.systemAudio ?? AudioSourceHealth(enabled: recordSystemAudio),
                                    gainDB: $systemGainDB, range: -60...12, paused: model.state == .paused)
                    AudioControlRow(title: "Mikrofon", symbol: "mic", health: model.health?.microphone ?? AudioSourceHealth(enabled: recordMicrophone),
                                    gainDB: $microphoneGainDB, range: -24...24, paused: model.state == .paused)
                }
                .onChange(of: systemGainDB) { _, value in saveGain(system: value, microphone: nil) }
                .onChange(of: microphoneGainDB) { _, value in
                    saveGain(system: nil, microphone: value)
                }

            cameraRow

            quickControls
            libraryRow
        }
        .padding(12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(CamcordStyle.recording)
            Text("Camcord")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            HeaderButton(symbol: "gearshape", title: "Ayarlar", action: actions.openSettings)
        }
        .frame(height: 28)
    }

    // MARK: - Capture grid

    private var captureGrid: some View {
        HStack(spacing: 6) {
            CaptureTile(symbol: "rectangle.dashed", title: "Bölge", shortcut: shortcuts.region, action: actions.captureRegion)
            CaptureTile(symbol: "macwindow", title: "Pencere", shortcut: shortcuts.window, action: actions.captureWindow)
            CaptureTile(symbol: "display", title: "Ekran", shortcut: shortcuts.screen, action: actions.captureScreen)
            CaptureTile(symbol: "rectangle.and.hand.point.up.left", title: "Kaydır", shortcut: shortcuts.scroll, action: actions.captureScroll)
        }
    }

    // MARK: - Recording row

    @ViewBuilder
    private var recordRow: some View {
        switch model.state {
        case .idle:
            VStack(spacing: 6) {
                HoverScaleButton(action: actions.toggleRecording) { hovering in
                    ZStack {
                        HStack(spacing: 8) {
                            if model.isStarting {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Image(systemName: "record.circle")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            Text(model.isStarting ? "Hazırlanıyor…" : "Kayıt başlat")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        if let shortcut = shortcuts.record, !model.isStarting {
                            HStack { Spacer(); ShortcutBadge(shortcut) }
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(CamcordStyle.recording.opacity(hovering ? 1 : 0.92))
                    )
                }
                .disabled(model.isStarting)
                .accessibilityLabel(model.isStarting ? "Kayıt hazırlanıyor" : "Kayıt başlat")
                .accessibilityValue(shortcuts.record ?? "")

                HStack(spacing: 6) {
                    RecordTargetButton(symbol: "macwindow", title: "Pencere kaydet", action: actions.recordWindow)
                    RecordTargetButton(
                        symbol: "display",
                        title: NSScreen.screens.count > 1 ? "İmleç ekranını kaydet" : "Ekranı kaydet",
                        action: actions.recordFullScreen
                    )
                }
                .disabled(model.isStarting)
            }

        case .recording, .paused:
            HStack(spacing: 9) {
                PulsingDot(paused: model.state == .paused, reduceMotion: reduceMotion)
                Text(model.elapsed ?? "0:00")
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 58, alignment: .leading)
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
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill((model.state == .paused ? Color.orange : CamcordStyle.recording).opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                (model.state == .paused ? Color.orange : CamcordStyle.recording).opacity(0.24),
                                lineWidth: 1
                            )
                    )
            )
        }
    }

    private var cameraRow: some View {
        HStack(spacing: 8) {
            Image(systemName: cameraEnabled ? "video.fill" : "video.slash")
                .foregroundStyle(cameraEnabled ? Color.accentColor : Color.secondary)
            Text("Kamera").font(.system(size: 12, weight: .medium))
            Spacer()
            if cameraEnabled {
                Button("Önizleme") {
                    if !designPreview { CameraOverlayController.shared.showPreview(requestPermission: true) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Toggle("Kamera", isOn: Binding(
                get: { cameraEnabled },
                set: { enabled in
                    cameraEnabled = enabled
                    guard !designPreview else { return }
                    var settings = RecordingSettings.load(from: .standard)
                    if settings.camera.enabled != enabled {
                        settings.camera.enabled = enabled
                        settings.save(to: .standard)
                    }
                    if enabled, model.isPanelVisible {
                        CameraOverlayController.shared.showPreview(requestPermission: true)
                    } else if !enabled {
                        CameraOverlayController.shared.hide()
                    }
                }
            ))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(model.state != .idle || model.isStarting)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }

    private var quickControls: some View {
        HStack(spacing: 4) {
            ToggleChip(
                title: "Sistem",
                onSymbol: "speaker.wave.2.fill", offSymbol: "speaker.slash.fill",
                help: audioToggleHelp("Sistem sesini kaydet"),
                isEnabled: model.state == .idle && !model.isStarting,
                isOn: $recordSystemAudio
            ) {
                saveRecordingSettings()
            }
            ToggleChip(
                title: "Mikrofon",
                onSymbol: "mic.fill", offSymbol: "mic.slash.fill",
                help: audioToggleHelp(
                    isMicrophoneDenied ? "Mikrofonu kaydet — mikrofon izni yok" : "Mikrofonu kaydet"
                ),
                warning: isMicrophoneDenied,
                isEnabled: model.state == .idle && !model.isStarting,
                isOn: $recordMicrophone
            ) {
                saveRecordingSettings()
            }
            ToggleChip(title: "Bildirim", onSymbol: "bell.fill", offSymbol: "bell.slash.fill", help: "Geri bildirim sesleri", isOn: $soundEnabled) {
                FeedbackSound.setEnabled(soundEnabled)
            }
            ToggleChip(
                title: "Diske kaydet",
                onSymbol: "square.and.arrow.down.fill", offSymbol: "square.and.arrow.down",
                help: "Ekran görüntülerini diske de kaydet", isOn: $saveScreenshots
            ) {
                var s = ScreenshotSettings.load(from: .standard)
                s.saveToDisk = saveScreenshots
                s.save(to: .standard)
            }

        }
    }

    private var libraryRow: some View {
        HStack(spacing: 6) {
            LibraryButton(
                symbol: "photo",
                title: "Görüntüler",
                detail: lastScreenshotURL == nil ? "Klasörü aç" : "Son çekim",
                help: lastScreenshotURL == nil
                    ? "Ekran görüntüleri klasörünü Finder'da göster"
                    : "Son ekran görüntüsünü Finder'da göster"
            ) {
                revealScreenshotDestination()
            }
            LibraryButton(
                symbol: "film",
                title: "Kayıtlar",
                detail: lastRecordingURL == nil ? "Klasörü aç" : "Son kayıt",
                help: lastRecordingURL == nil
                    ? "Kayıt klasörünü Finder'da göster"
                    : "Son kaydı Finder'da göster"
            ) {
                revealRecordingDestination()
            }
        }
    }

    // MARK: - Persistence

    private func saveGain(system: Double?, microphone: Double?) {
        guard !designPreview else { return }
        var settings = RecordingSettings.load(from: .standard)
        if let system { settings.systemAudioGainDB = system }
        if let microphone { settings.microphoneGainDB = microphone }
        settings.save(to: .standard)
    }

    private func reloadPersistedState() {
        let gainSettings = RecordingSettings.load(from: .standard)
        systemGainDB = gainSettings.resolvedSystemAudioGainDB
        microphoneGainDB = gainSettings.resolvedMicrophoneGainDB
        let settings = RecordingSettings.load(from: .standard)
        let screenshotSettings = ScreenshotSettings.load(from: .standard)
        recordSystemAudio = settings.systemAudio
        recordMicrophone = settings.microphone
        cameraEnabled = settings.camera.enabled
        soundEnabled = FeedbackSound.isEnabled()
        saveScreenshots = screenshotSettings.saveToDisk
        shortcuts = PanelShortcuts.load()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        isMicrophoneDenied = micStatus == .denied || micStatus == .restricted
        let directories = CaptureLibrary.directories(
            recordingSettings: settings, screenshotSettings: screenshotSettings
        )
        recordingDirectoryURL = directories.recording
        screenshotDirectoryURL = directories.screenshot
    }

    private func reloadCaptureLibrary(generation: Int) async {
        let settings = RecordingSettings.load(from: .standard)
        let screenshotSettings = ScreenshotSettings.load(from: .standard)
        let directories = CaptureLibrary.directories(
            recordingSettings: settings, screenshotSettings: screenshotSettings
        )
        recordingDirectoryURL = directories.recording
        screenshotDirectoryURL = directories.screenshot
        lastRecordingURL = nil
        lastScreenshotURL = nil

        let snapshot = await CaptureLibrary.scan(
            recordingDirectory: directories.recording,
            screenshotDirectory: directories.screenshot
        )
        guard !Task.isCancelled,
              generation == model.panelOpenToken,
              model.finishedURL == nil,
              snapshot.recordingDirectory == recordingDirectoryURL,
              snapshot.screenshotDirectory == screenshotDirectoryURL
        else { return }
        lastRecordingURL = snapshot.newestRecording
        lastScreenshotURL = snapshot.newestScreenshot
    }

    private func audioToggleHelp(_ base: String) -> String {
        model.state == .idle ? base : "\(base) — bir sonraki kayıt için kayıt bittikten sonra değiştir"
    }

    private func revealScreenshotDestination() {
        reveal(lastScreenshotURL, or: screenshotDirectoryURL, using: actions.revealScreenshot)
    }

    private func revealRecordingDestination() {
        reveal(lastRecordingURL, or: recordingDirectoryURL, using: actions.revealRecording)
    }

    private func reveal(_ recent: URL?, or directory: URL, using action: @escaping (URL) -> Void) {
        if let recent {
            action(recent)
            return
        }
        Task {
            guard await CaptureLibrary.prepareDirectory(directory) else {
                actions.reportError("Kayıt klasörü açılamadı — Ayarlar’dan konumu kontrol et")
                return
            }
            guard !Task.isCancelled else { return }
            action(directory)
        }
    }

    private func saveRecordingSettings() {
        var settings = RecordingSettings.load(from: .standard)
        settings.systemAudio = recordSystemAudio
        settings.microphone = recordMicrophone
        settings.save(to: .standard)
    }
}

private struct PanelShortcuts {
    var region: String?
    var window: String?
    var screen: String?
    var scroll: String?
    var record: String?

    @MainActor
    static func load() -> PanelShortcuts {
        PanelShortcuts(
            region: KeyboardShortcuts.getShortcut(for: .captureRegion)?.description,
            window: KeyboardShortcuts.getShortcut(for: .captureActiveWindow)?.description,
            screen: KeyboardShortcuts.getShortcut(for: .captureFullScreen)?.description,
            scroll: KeyboardShortcuts.getShortcut(for: .captureScrolling)?.description,
            record: KeyboardShortcuts.getShortcut(for: .toggleRecording)?.description
        )
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
    let renamed: (URL) -> Void
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var currentURL: URL
    @State private var name: String
    @State private var presentation: RecordingPresentation?
    @State private var renameMessage: String?
    @State private var isRenaming = false

    init(
        url: URL,
        reveal: @escaping (URL) -> Void,
        open: @escaping (URL) -> Void,
        renamed: @escaping (URL) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.reveal = reveal
        self.open = open
        self.renamed = renamed
        self.dismiss = dismiss
        _currentURL = State(initialValue: url)
        _name = State(initialValue: url.deletingPathExtension().lastPathComponent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(.green.opacity(0.14)).frame(width: 28, height: 28)
                        .scaleEffect(appeared ? 1 : 0.5).opacity(appeared ? 1 : 0)
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.green)
                        .scaleEffect(appeared ? 1 : 0.2).opacity(appeared ? 1 : 0)
                }
                Text("Kayıt hazır").font(.system(size: 16, weight: .semibold))
                Spacer()
                HoverScaleButton(action: dismiss) { hovering in
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 28)
                        .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0.045)))
                }
                .disabled(isRenaming)
                .help("Kapat")
                .accessibilityLabel("Kapat")
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(CamcordStyle.quietFill)
                if let thumbnail = presentation?.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(4)
                } else if presentation == nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Kayıt önizlemesi yükleniyor")
                } else {
                    Label("Önizleme yok", systemImage: "film")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 144)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Kayıt önizlemesi")
            .accessibilityValue(presentation?.thumbnail == nil ? "Kullanılamıyor" : "Hazır")

            HStack(spacing: 4) {
                TextField("Ad", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .disabled(isRenaming)
                    .onSubmit { Task { _ = await commitRename() } }
                Text("." + currentURL.pathExtension)
                    .font(.system(size: 11)).monospaced()
                    .foregroundStyle(.secondary)
                if isRenaming { ProgressView().controlSize(.mini) }
            }

            HStack(spacing: 12) {
                MetaLabel(symbol: "internaldrive", text: presentation?.size ?? "…")
                MetaLabel(symbol: "clock", text: presentation?.duration ?? "…")
                if let dims = presentation?.dimensions {
                    MetaLabel(symbol: "rectangle.ratio.16.to.9", text: dims)
                }
                Spacer()
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)

            if let renameMessage {
                Label(renameMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .accessibilityLabel(renameMessage)
            }

            Label {
                Text((currentURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "folder")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .help(currentURL.deletingLastPathComponent().path)
            .accessibilityLabel("Kayıt klasörü")
            .accessibilityValue(currentURL.deletingLastPathComponent().path)

            Spacer(minLength: 2)

            HStack(spacing: 8) {
                CardButton(title: "Finder'da Göster", symbol: "folder") {
                    Task { await performAfterRename(reveal) }
                }
                CardButton(title: "Aç", symbol: "play.fill", prominent: true) {
                    Task { await performAfterRename(open) }
                }
            }
            .disabled(isRenaming)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(12)
        .onAppear {
            if reduceMotion { appeared = true }
            else { withAnimation(CapturePanelView.panelSpring) { appeared = true } }
        }
        .task(id: currentURL) {
            let requestedURL = currentURL
            presentation = nil
            let loaded = await RecordingPresentation.load(requestedURL)
            guard !Task.isCancelled, currentURL == requestedURL else { return }
            presentation = loaded
        }
    }

    private func performAfterRename(_ action: @escaping (URL) -> Void) async {
        guard let url = await commitRename() else { return }
        action(url)
    }

    /// File-system validation and movement stay off the main actor. Actions wait for this
    /// result, and a collision/failure remains visible instead of silently reverting text.
    private func commitRename() async -> URL? {
        guard !isRenaming else { return nil }
        renameMessage = nil
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = currentURL.deletingPathExtension().lastPathComponent
        guard !cleaned.isEmpty else {
            renameMessage = "Dosya adı boş olamaz."
            return nil
        }
        guard cleaned.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)) == nil else {
            renameMessage = "Dosya adında /, \\ veya : kullanılamaz."
            return nil
        }
        if cleaned == original {
            name = cleaned
            return currentURL
        }
        let target = currentURL.deletingLastPathComponent()
            .appendingPathComponent(cleaned).appendingPathExtension(currentURL.pathExtension)
        isRenaming = true
        defer { isRenaming = false }
        switch await RecordingRename.move(from: currentURL, to: target) {
        case .success:
            currentURL = target
            name = cleaned
            renamed(target)
            return target
        case .collision:
            renameMessage = "Bu adda bir kayıt zaten var."
        case .failure:
            renameMessage = "Dosya yeniden adlandırılamadı. Klasör izinlerini kontrol et."
        }
        return nil
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

/// Poster frame and metadata are loaded asynchronously from the actual completed file.
private struct RecordingPresentation: @unchecked Sendable {
    let thumbnail: NSImage?
    let size: String
    let duration: String
    let dimensions: String?

    static func load(_ url: URL) async -> RecordingPresentation {
        let asset = AVURLAsset(url: url)
        var durationText = "—"
        var previewTime = CMTime.zero
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds >= 0 {
                durationText = timeString(seconds)
                previewTime = CMTime(seconds: min(max(seconds * 0.15, 0), 1), preferredTimescale: 600)
            }
        }
        var dims: String?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
            let natural = try? await track.load(.naturalSize) {
            dims = "\(Int(abs(natural.width)))×\(Int(abs(natural.height)))"
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 592, height: 288)
        let thumbnail: NSImage?
        if let result = try? await generator.image(at: previewTime) {
            thumbnail = NSImage(cgImage: result.image, size: .zero)
        } else {
            thumbnail = nil
        }
        return RecordingPresentation(
            thumbnail: thumbnail,
            size: byteString(url),
            duration: durationText,
            dimensions: dims
        )
    }

    private static func byteString(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private static func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

enum RecordingRename {
    enum Outcome: Sendable, Equatable { case success, collision, failure }

    static func move(from source: URL, to target: URL) async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: target.path) {
                // A case-insensitive volume reports a capitalization-only target as
                // existing even though it is the source itself. Prove both paths name
                // the same inode before asking the filesystem for an in-place rename;
                // every other existing target remains a collision.
                guard isSafeCaseOnlyRename(
                    from: source,
                    to: target,
                    fileManager: fileManager
                ) else { return .collision }
                do {
                    try fileManager.moveItem(at: source, to: target)
                    return .success
                } catch {
                    return .failure
                }
            }
            do {
                try fileManager.moveItem(at: source, to: target)
                return .success
            } catch {
                return fileManager.fileExists(atPath: target.path) ? .collision : .failure
            }
        }.value
    }

    private static func isSafeCaseOnlyRename(
        from source: URL,
        to target: URL,
        fileManager: FileManager
    ) -> Bool {
        let sourcePath = source.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard sourcePath != targetPath,
              sourcePath.caseInsensitiveCompare(targetPath) == .orderedSame,
              let supportsCaseSensitiveNames = try? source.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames,
              supportsCaseSensitiveNames == false,
              let sourceAttributes = try? fileManager.attributesOfItem(atPath: sourcePath),
              let targetAttributes = try? fileManager.attributesOfItem(atPath: targetPath),
              let sourceDevice = sourceAttributes[.systemNumber] as? NSNumber,
              let targetDevice = targetAttributes[.systemNumber] as? NSNumber,
              let sourceInode = sourceAttributes[.systemFileNumber] as? NSNumber,
              let targetInode = targetAttributes[.systemFileNumber] as? NSNumber
        else { return false }
        return sourceDevice == targetDevice && sourceInode == targetInode
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
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent
                        ? AnyShapeStyle(CamcordStyle.accent.opacity(hovering ? 1 : 0.92))
                        : AnyShapeStyle(Color.primary.opacity(hovering ? 0.10 : 0.06)))
            )
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - Components

/// One capture action: icon over a tiny label, generous hit target, soft hover fill,
/// gentle press scale.
private struct CaptureTile: View {
    let symbol: String
    let title: String
    let shortcut: String?
    let action: () -> Void

    var body: some View {
        HoverScaleButton(action: action) { hovering in
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(hovering ? AnyShapeStyle(CamcordStyle.accent) : AnyShapeStyle(.secondary))
                    .frame(height: 20)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Group {
                    if let shortcut { Text(shortcut) } else { Text(" ").accessibilityHidden(true) }
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(height: 11)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.10 : 0.055))
            )
        }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(shortcut ?? "")
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
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill((tint ?? Color.primary).opacity(
                            tint == nil ? (hovering ? 0.13 : 0.07) : (hovering ? 0.16 : 0.09)
                        ))
                )
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Secondary recording target next to the primary "Kayıt başlat" (e.g. full screen).
private struct RecordTargetButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        HoverScaleButton(action: action) { hovering in
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.09 : 0.05))
                )
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Footer toggle: filled symbol when on, slashed + faint when off. `warning` tints the
/// symbol orange (e.g. mic wanted but the OS permission is denied).
private struct ToggleChip: View {
    let title: String
    let onSymbol: String
    let offSymbol: String
    let help: String
    var warning: Bool = false
    var isEnabled: Bool = true
    @Binding var isOn: Bool
    let onChange: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HoverScaleButton(action: {
            isOn.toggle()
            onChange()
        }) { hovering in
            VStack(spacing: 3) {
                Image(systemName: isOn ? onSymbol : offSymbol)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
            }
                .foregroundStyle(
                    warning && isOn
                        ? AnyShapeStyle(Color.orange)
                        : isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
                )
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(isOn ? (hovering ? 0.11 : 0.07) : 0.025))
                )
        }
        .help(help)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.48)
        .accessibilityLabel(help)
        .accessibilityValue(isOn ? "Açık" : "Kapalı")
        .accessibilityHint(isEnabled ? "Durumu değiştirir" : "Kayıt bittikten sonra değiştirilebilir")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isOn)
    }
}

private struct LibraryButton: View {
    let symbol: String
    let title: String
    let detail: String
    let help: String
    let action: () -> Void

    var body: some View {
        HoverScaleButton(action: action) { hovering in
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CamcordStyle.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11, weight: .medium))
                    Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0.05))
            )
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct HeaderButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        HoverScaleButton(action: action) { hovering in
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 30, height: 28)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0.045)))
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct ShortcutBadge: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .monospaced()
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.16)))
            .accessibilityHidden(true)
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
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.84),
                value: configuration.isPressed
            )
    }
}
