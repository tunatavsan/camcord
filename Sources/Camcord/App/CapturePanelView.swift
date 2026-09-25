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
    @Published var isArmed = false
}

/// What a press on the recording stage landed on.
struct StageHit: Equatable, Sendable {
    let corner: CameraCorner?
    let movesCamera: Bool
}

/// The stage's camera rectangle is ~54×31 pt: the floating tile's 44 pt corner zones would
/// cover almost all of it. Here the whole body moves and only small corner zones resize —
/// `max(12 pt, 22% of the side)` on each axis, never more than half of it — and the grips
/// that mark them are drawn INSIDE the rectangle, where a press actually lands.
enum StageGrip {
    static let minimumZone: CGFloat = 12
    static let zoneFraction: CGFloat = 0.22
    /// Radius of the corner curve the grip arcs follow, and their gap inside it.
    static let arcRadius: CGFloat = 5
    static let arcGap: CGFloat = 1.5
    static let strokeWidth: CGFloat = 1

    /// A corner's resize zone, inside `rect` (any y direction: the zones are symmetric).
    static func zone(_ corner: CameraCorner, in rect: CGRect, yDown: Bool = false) -> CGRect {
        let width = min(max(minimumZone, rect.width * zoneFraction), rect.width / 2)
        let height = min(max(minimumZone, rect.height * zoneFraction), rect.height / 2)
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topLeft || corner == .topRight
        let atMaxY = yDown ? !top : top
        return CGRect(x: right ? rect.maxX - width : rect.minX,
                      y: atMaxY ? rect.maxY - height : rect.minY, width: width, height: height)
    }

    /// The zones lie inside `rect`, so a point outside it is never on a grip.
    static func corner(at point: CGPoint, in rect: CGRect, yDown: Bool = false) -> CameraCorner? {
        CameraCorner.allCases.first { zone($0, in: rect, yDown: yDown).contains(point) }
    }

    /// A quarter arc just inside `corner`, concentric with the rectangle's own corner curve
    /// (y-down, the SwiftUI canvas).
    static func arc(_ corner: CameraCorner, in rect: CGRect) -> Path {
        let radius = max(arcRadius, CameraOptions.cornerRadius(for: rect.size))
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topLeft || corner == .topRight
        let center = CGPoint(x: right ? rect.maxX - radius : rect.minX + radius,
                             y: top ? rect.minY + radius : rect.maxY - radius)
        let start: Double
        switch corner {
        case .topLeft: start = 180
        case .topRight: start = 270
        case .bottomRight: start = 0
        case .bottomLeft: start = 90
        }
        var path = Path()
        path.addArc(center: center, radius: radius - arcGap, startAngle: .degrees(start),
                    endAngle: .degrees(start + 90), clockwise: false)
        return path
    }

    /// The pointer a hover shows: open hand over the body, a resize arrow on a grip.
    static func cursor(for hit: StageHit) -> StageCursor? {
        guard hit.movesCamera else { return nil }
        return hit.corner.map(StageCursor.resize) ?? .move
    }
}

enum StageCursor: Equatable {
    case move
    case resize(CameraCorner)

    var style: PointerStyle {
        switch self {
        case .move: return .grabIdle
        case .resize(let corner):
            switch corner {
            case .topLeft: return .frameResize(position: .topLeading)
            case .topRight: return .frameResize(position: .topTrailing)
            case .bottomLeft: return .frameResize(position: .bottomLeading)
            case .bottomRight: return .frameResize(position: .bottomTrailing)
            }
        }
    }
}

/// One still frame of the armed window, with the size the recording will composite
/// into — enough for the panel to draw the camera rectangle before a recording exists.
struct ArmedStageFrame: Sendable {
    let image: CGImage
    let frameSize: CGSize
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
    var cancelArmed: () -> Void = {}
    var pauseResume: () -> Void = {}
    var setStageSink: ((@Sendable (PixelBufferBox) -> Void)?) -> Void = { _ in }
    var recordingFrameSize: () -> CGSize = { .zero }
    /// The armed window's still frame for the stage. nil when nothing is armed.
    var armedStageFrame: () async -> ArmedStageFrame? = { nil }
    var revealRecording: (URL) -> Void = { _ in }
    var openRecording: (URL) -> Void = { _ in }
    /// Reveal the newest saved screenshot in Finder.
    var revealScreenshot: (URL) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var openMainWindow: () -> Void = {}
    var reportError: (String) -> Void = { _ in }
}

/// The menu-bar capture palette: a stable 560-point native surface, two columns wide.
/// The left column holds the controls (capture, record, audio, camera, quick toggles);
/// the right one is the context column — the library at rest, the armed window's still
/// frame while a recording waits for Başlat, and the live stage while it runs.
struct CapturePanelView: View {
    @ObservedObject var model: RecordingStateModel
    let actions: PanelActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.camcordDesignPreview) private var designPreview
    @State private var cameraEnabled = false
    @State private var previewVisible = false
    @State private var cameraRunning = false
    @State private var recordSystemAudio = true
    @State private var recordMicrophone = true
    @State private var systemGainDB: Double = 0
    @State private var microphoneGainDB: Double = 0
    @State private var microphoneDeviceID: String?
    @State private var mixAudioTracks = true
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

    /// Fixed width; the height only ever shrinks for the two cards (finishing, done).
    /// A definite size per state keeps the popover beak anchored correctly under the
    /// status item. Nothing grows the panel downward any more: a running recording is
    /// exactly as tall as an idle one and spends its extra room sideways, in the
    /// context column.
    static let panelWidth: CGFloat = 560
    static let panelHeight: CGFloat = 458
    static let activeHeight: CGFloat = 458
    static let finishingHeight: CGFloat = 220
    static let finishedHeight: CGFloat = 418

    /// The two columns inside the 12 pt padding: 276 + 12 + 248 = 536.
    static let controlColumnWidth: CGFloat = 276
    static let contextColumnWidth: CGFloat = 248
    /// The two end-of-recording cards keep the width they were composed for and sit centred
    /// in the wider panel — stretching a rename field and a 16:9 still across 536 points
    /// makes the state every recording ends in look like a mistake.
    static let cardWidth: CGFloat = 340

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
                .frame(maxWidth: Self.cardWidth)
                .transition(panelTransition)
            } else if model.isFinishing {
                FinishingCard()
                    .frame(maxWidth: Self.cardWidth)
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
            RoundedRectangle(cornerRadius: CamcordStyle.Radius.surface, style: .continuous)
                .strokeBorder(CamcordStyle.innerBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: CamcordStyle.Radius.surface, style: .continuous))
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
        .onChange(of: model.isArmed) { _, _ in
            if !designPreview { previewVisible = CameraOverlayController.shared.previewVisible }
        }
        .onReceive(CameraPreviewMonitor.shared.$isRunning.removeDuplicates()) { running in
            guard !designPreview else { return }
            cameraRunning = running
            previewVisible = CameraOverlayController.shared.previewVisible
        }
        // The shortcut and the tile's own × write the same state this chip draws.
        .onReceive(NotificationCenter.default.publisher(for: CameraOverlayController.previewVisibilityDidChange)) { _ in
            guard !designPreview else { return }
            previewVisible = CameraOverlayController.shared.previewVisible
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingSettings.didChangeNotification)) { _ in
            guard !designPreview else { return }
            cameraEnabled = RecordingSettings.load(from: .standard).camera.enabled
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
            HStack(alignment: .top, spacing: 12) {
                controlColumn
                    .frame(width: Self.controlColumnWidth)
                contextColumn
                    .frame(width: Self.contextColumnWidth)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(12)
    }

    private var controlColumn: some View {
        VStack(spacing: 12) {
            captureGrid

            recordRow
                .frame(height: 84, alignment: .top)
                .animation(reduceMotion ? nil : Self.panelSpring, value: model.state)

            AudioChannelStrip(
                health: model.health,
                state: model.state,
                isStarting: model.isStarting,
                microphoneDenied: isMicrophoneDenied,
                systemEnabled: $recordSystemAudio,
                microphoneEnabled: $recordMicrophone,
                systemGainDB: $systemGainDB,
                microphoneGainDB: $microphoneGainDB,
                microphoneDeviceID: $microphoneDeviceID,
                mixTracks: $mixAudioTracks,
                onChannelToggle: saveRecordingSettings,
                onGainChange: { system, microphone in saveGain(system: system, microphone: microphone) },
                onDeviceChange: saveMicrophoneDevice,
                onMixChange: saveMixAudioTracks
            )

            cameraRow

            Spacer(minLength: 0)
        }
    }

    /// One stable column in every state, so nothing re-lays-out when a recording starts:
    /// the stage viewport on top — empty at rest, the armed window's still frame while a
    /// recording waits, the live composite while it runs — and the two library
    /// destinations underneath.
    private var contextColumn: some View {
        VStack(spacing: 12) {
            StageView(
                state: model.state,
                isArmed: model.isArmed,
                setSink: actions.setStageSink,
                recordingFrameSize: actions.recordingFrameSize,
                armedStageFrame: actions.armedStageFrame
            )
            libraryRow
            quickControls
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(CamcordStyle.recording)
            Text("Camcord")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            HeaderButton(symbol: "macwindow",
                         title: String(localized: "Open Camcord", comment: "Opens the main window"),
                         action: actions.openMainWindow)
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
        if model.isArmed {
            HStack(spacing: 8) {
                CardButton(title: "Başlat", symbol: "play.fill", prominent: true, action: actions.toggleRecording)
                CardButton(title: "İptal", symbol: "xmark", action: actions.cancelArmed)
            }
        } else {
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
                        RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous)
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
                // The preview is reachable while recording too: opening it here confines it
                // to the recorded rect, and dragging it there lands in the file live.
                RoundIconButton(
                    symbol: previewVisible ? "eye.fill" : "eye.slash",
                    help: previewVisible ? "Kamera önizlemesini gizle" : "Kamera önizlemesini aç",
                    // Distinct from the camera row's eye, which is on screen at the same
                    // time and does the same thing: this one belongs to the transport.
                    label: "Önizleme",
                    action: togglePreviewWindow
                )
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
                RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous)
                    .fill((model.state == .paused ? Color.orange : CamcordStyle.recording).opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous)
                            .strokeBorder(
                                (model.state == .paused ? Color.orange : CamcordStyle.recording).opacity(0.24),
                                lineWidth: 1
                            )
                    )
            )
        }
    }

    }

    /// The panel's half of the preview switch -- with the status-menu item, the only two
    /// things that open or close the preview. Recording state never gates it.
    private func togglePreviewWindow() {
        guard !designPreview else { return }
        CameraOverlayController.shared.togglePreview()
        previewVisible = CameraOverlayController.shared.previewVisible
    }

    private var cameraRow: some View {
        HStack(spacing: 8) {
            Image(systemName: cameraEnabled ? "video.fill" : "video.slash")
                .foregroundStyle(cameraEnabled ? Color.accentColor : Color.secondary)
            Text("Kamerayı kaydet")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            if cameraRunning { Circle().fill(.green).frame(width: 6, height: 6) }
            // The same round eye the recording row already offers, rather than a labelled
            // chip: in a 276 pt column the chip's label was the thing that pushed
            // "Kamerayı kaydet" onto two lines and truncated itself to "Önizle…". A filled
            // round button is still a real, visible control — the mistake this replaced was
            // a BARE text button, which read as disabled.
            RoundIconButton(
                symbol: previewVisible ? "eye.fill" : "eye.slash",
                tint: previewVisible ? CamcordStyle.accent : nil,
                help: "Kamera önizleme penceresini açar veya gizler — kayda kamera gömmekten bağımsızdır",
                label: "Kamera önizlemesi",
                action: togglePreviewWindow
            )
            .accessibilityValue(previewVisible ? "Açık" : "Kapalı")
            Toggle("Kamerayı kaydet", isOn: Binding(
                get: { cameraEnabled },
                set: { enabled in
                    cameraEnabled = enabled
                    guard !designPreview else { return }
                    var settings = RecordingSettings.load(from: .standard)
                    if settings.camera.enabled != enabled {
                        settings.camera.enabled = enabled
                        settings.save(to: .standard)
                    }
                }
            ))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .help("Kamerayı kaydedilen dosyaya gömer — önizleme penceresini açmaz")
                .accessibilityLabel("Kamerayı kaydet")
                .disabled(model.state != .idle || model.isStarting)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: CamcordStyle.Radius.control))
    }

    /// The two audio switches used to live here; they are the channel strip's now, so what
    /// is left are the output preferences — which belong next to the two destinations.
    private var quickControls: some View {
        HStack(spacing: 6) {
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

    /// Stacked, not side by side: at the context column's width a two-up row clipped
    /// "Görüntüler", and the column has the height to spare.
    private var libraryRow: some View {
        VStack(spacing: 6) {
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
        microphoneDeviceID = settings.microphoneDeviceID
        mixAudioTracks = settings.mixAudioTracks
        cameraEnabled = settings.camera.enabled
        previewVisible = CameraOverlayController.shared.previewVisible
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
        guard !designPreview else { return }
        var settings = RecordingSettings.load(from: .standard)
        settings.systemAudio = recordSystemAudio
        settings.microphone = recordMicrophone
        settings.save(to: .standard)
    }

    private func saveMicrophoneDevice(_ deviceID: String?) {
        microphoneDeviceID = deviceID
        guard !designPreview else { return }
        var settings = RecordingSettings.load(from: .standard)
        guard settings.microphoneDeviceID != deviceID else { return }
        settings.microphoneDeviceID = deviceID
        settings.save(to: .standard)
    }

    private func saveMixAudioTracks() {
        guard !designPreview else { return }
        var settings = RecordingSettings.load(from: .standard)
        guard settings.mixAudioTracks != mixAudioTracks else { return }
        settings.mixAudioTracks = mixAudioTracks
        settings.save(to: .standard)
    }
}

/// The in-panel viewport onto what is being recorded: the live composite while a
/// recording runs, the armed window's still frame while one waits for Başlat, and an
/// empty frame at rest. The camera rectangle drawn on it is placed by dragging, and that
/// placement is the same one the compositor writes into the file.
///
/// The drag lives on the STATIONARY canvas, never on the rectangle it moves. A gesture
/// attached to a view that the same gesture repositions loses its end event — the
/// placement then never persists and the next press starts from a stale origin, which is
/// exactly how the stage came to feel like it "did not move".
struct StageView: View {
    let state: RecordingController.UIState
    let isArmed: Bool
    let setSink: ((@Sendable (PixelBufferBox) -> Void)?) -> Void
    let recordingFrameSize: () -> CGSize
    let armedStageFrame: () async -> ArmedStageFrame?

    /// What a press on the canvas started: the placement it began from, and whether it
    /// landed on the rectangle at all (a press on the recording itself moves nothing).
    private struct Drag {
        let options: CameraOptions
        let rect: CGRect
        let frameSize: CGSize
        let corner: CameraCorner?
        let movesCamera: Bool
    }

    private static let space = "recording-stage"
    /// The viewport's shape before a frame has arrived to give it one.
    private static let restingAspect: CGFloat = 16.0 / 9.0
    /// Retina: the composite is rendered at twice the canvas points so the stage is sharp
    /// rather than an upscaled thumbnail — capped, because nothing here needs 4K.
    private static let maximumRenderWidth: CGFloat = 960

    @State private var image: NSImage?
    @State private var thumbnailPixelSize = CGSize.zero
    @State private var frameSize = CGSize.zero
    @State private var options = CameraOptions()
    @State private var rendering = false
    @State private var generation: UInt64 = 0
    @State private var canvasWidth: CGFloat = 0
    @State private var drag: Drag?
    @State private var pointer: PointerStyle?
    @Environment(\.camcordDesignPreview) private var designPreview

    private var isLive: Bool { !isArmed && state != .idle }

    private var sourceKey: String { Self.sourceKey(isArmed: isArmed, state: state) }

    /// What the stage is SHOWING, as the key that re-runs its source task. Pausing is not
    /// such a change: no frame arrives while paused, so tearing the source down there would
    /// blank the stage for the whole pause and leave the veil nothing to sit on. Pure, so
    /// that rule is pinned rather than re-derived from the enum's description.
    static func sourceKey(isArmed: Bool, state: RecordingController.UIState) -> String {
        if isArmed { return "armed" }
        return state == .idle ? "idle" : "live"
    }

    private var aspect: CGFloat {
        guard thumbnailPixelSize.width > 0, thumbnailPixelSize.height > 0 else { return Self.restingAspect }
        return thumbnailPixelSize.width / thumbnailPixelSize.height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Sahne")
                    .font(.system(size: 11, weight: .semibold))
                Text("Konum ve boyut tüm hedeflerde ortaktır.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }

            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                let thumbnail = Self.thumbnailRect(for: thumbnailPixelSize, in: bounds)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous)
                        .fill(.black.opacity(0.28))

                    if let image, !thumbnail.isEmpty {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: thumbnail.width, height: thumbnail.height)
                            .clipShape(RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous))
                            .position(x: thumbnail.midX, y: thumbnail.midY)

                        if state == .paused {
                            RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous)
                                .fill(.black.opacity(0.46))
                                .frame(width: thumbnail.width, height: thumbnail.height)
                                .overlay {
                                    Text("duraklatıldı")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.9))
                                }
                                .position(x: thumbnail.midX, y: thumbnail.midY)
                        }

                        cameraOverlay(in: thumbnail)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "rectangle.on.rectangle")
                                .font(.system(size: 18, weight: .light))
                            Text(emptyMessage)
                                .font(.system(size: 10))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .coordinateSpace(name: Self.space)
                // The canvas — which never moves — owns the gesture and the hit area.
                .contentShape(Rectangle())
                .gesture(stageDrag(thumbnail: thumbnail))
                .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                    guard drag == nil else { return }
                    switch phase {
                    case .active(let location):
                        pointer = StageGrip.cursor(for: Self.hit(at: location, options: options,
                                                                 frameSize: frameSize, thumbnail: thumbnail))?.style
                    case .ended:
                        pointer = nil
                    }
                }
                .pointerStyle(drag.map { $0.corner == nil && $0.movesCamera ? .grabActive : pointer } ?? pointer)
                .clipShape(RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous))
                .onAppear { canvasWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in canvasWidth = width }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
        }
        .task(id: sourceKey) { await activateSource() }
        // The armed stage has no frame feed to refresh it, so the camera switch and a drag
        // on the tile itself would otherwise never reach the rectangle drawn here.
        .onReceive(NotificationCenter.default.publisher(for: RecordingSettings.didChangeNotification)) { _ in
            guard !designPreview, drag == nil else { return }
            options = RecordingSettings.load(from: .standard).camera.resolved()
        }
        .onDisappear(perform: deactivate)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kayıt sahnesi")
    }

    private var emptyMessage: String {
        if isArmed { return "Pencere görüntüsü alınıyor…" }
        if isLive { return "Kayıt görüntüsü bekleniyor…" }
        return "Kayıt başlayınca burada görünür"
    }

    /// Purely drawn: the rectangle never takes the press that moves it.
    @ViewBuilder
    private func cameraOverlay(in thumbnail: CGRect) -> some View {
        let rect = options.enabled ? Self.cameraRect(options: options, frameSize: frameSize, thumbnail: thumbnail) : .zero
        if !rect.isEmpty {
            let local = CGRect(origin: .zero, size: rect.size)
            ZStack {
                RoundedRectangle(cornerRadius: max(3, CameraOptions.cornerRadius(for: rect.size)))
                    .inset(by: StageGrip.strokeWidth / 2)
                    .stroke(CamcordStyle.accent, lineWidth: StageGrip.strokeWidth)
                ForEach(CameraCorner.allCases.indices, id: \.self) { index in
                    StageGrip.arc(CameraCorner.allCases[index], in: local.insetBy(dx: 2, dy: 2))
                        .stroke(CamcordStyle.accent, style: StrokeStyle(lineWidth: StageGrip.strokeWidth, lineCap: .round))
                }
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityLabel("Kamera konumu")
            .accessibilityHint("Taşımak için sürükle; köşelerden sürükleyerek boyutlandır")
        }
    }

    // MARK: - Drag

    private func stageDrag(thumbnail: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let started = drag ?? beginDrag(at: value.startLocation, thumbnail: thumbnail)
                drag = started
                guard started.movesCamera else { return }
                updatePlacement(started, translation: value.translation, thumbnail: thumbnail, persists: false)
            }
            .onEnded { value in
                let started = drag ?? beginDrag(at: value.startLocation, thumbnail: thumbnail)
                if started.movesCamera {
                    updatePlacement(started, translation: value.translation, thumbnail: thumbnail, persists: true)
                }
                drag = nil
            }
    }

    private func beginDrag(at start: CGPoint, thumbnail: CGRect) -> Drag {
        let hit = Self.hit(at: start, options: options, frameSize: frameSize, thumbnail: thumbnail)
        return Drag(
            options: options,
            rect: options.rect(in: frameSize),
            frameSize: frameSize,
            corner: hit.corner,
            movesCamera: hit.movesCamera
        )
    }

    /// Where a press on the stage landed, in the recording's own terms: which resize
    /// corner it caught, and whether it touched the camera rectangle at all. Pure, so the
    /// rule that a press on the recording itself moves nothing is testable without a
    /// window.
    static func hit(at start: CGPoint, options: CameraOptions, frameSize: CGSize, thumbnail: CGRect) -> StageHit {
        guard options.enabled, frameSize.width > 0, frameSize.height > 0, !thumbnail.isEmpty else {
            return StageHit(corner: nil, movesCamera: false)
        }
        let scaled = yUpThumbnailRect(options.rect(in: frameSize), frameSize: frameSize, thumbnail: thumbnail)
        let point = CGPoint(
            x: start.x - thumbnail.minX,
            y: thumbnail.height - (start.y - thumbnail.minY)
        )
        let corner = StageGrip.corner(at: point, in: scaled)
        return StageHit(corner: corner, movesCamera: scaled.contains(point))
    }

    private func updatePlacement(_ start: Drag, translation: CGSize, thumbnail: CGRect, persists: Bool) {
        guard start.frameSize.width > 0, start.frameSize.height > 0 else { return }
        let delta = Self.recordingTranslation(
            translation,
            frameSize: start.frameSize,
            thumbnail: thumbnail
        )
        var updated: CameraOptions
        if let corner = start.corner {
            updated = CameraResizeGeometry.resize(
                start: start.rect,
                translation: delta,
                corner: corner,
                options: start.options,
                in: start.frameSize
            )
        } else {
            updated = start.options
            updated.place(
                start.rect.offsetBy(dx: delta.x, dy: delta.y),
                in: start.frameSize,
                snapDistance: min(84, min(start.frameSize.width, start.frameSize.height) * 0.18)
            )
        }
        options = updated.resolved()
        CameraOverlayController.shared.applyPlacement(options, source: .stage, persists: persists)
    }

    // MARK: - Source

    private func activateSource() async {
        generation &+= 1
        let token = generation
        setSink(nil)
        rendering = false
        drag = nil
        image = nil
        thumbnailPixelSize = .zero
        frameSize = .zero
        options = RecordingSettings.load(from: .standard).camera.resolved()

        if isArmed {
            // One retry: the window can be mid-move or the capture can fail transiently, and
            // a stage stuck on "alınıyor…" for the whole arm is worse than a second attempt.
            var armed = await armedStageFrame()
            if armed == nil, token == generation {
                try? await Task.sleep(for: .milliseconds(400))
                armed = await armedStageFrame()
            }
            guard let armed, token == generation else { return }
            let pixelSize = CGSize(width: armed.image.width, height: armed.image.height)
            image = NSImage(cgImage: armed.image, size: pixelSize)
            thumbnailPixelSize = pixelSize
            frameSize = armed.frameSize
        } else if isLive {
            installSink(token: token)
        }
    }

    private func installSink(token: UInt64) {
        setSink { box in
            Task { @MainActor in
                guard token == generation, !rendering else { return }
                let points = recordingFrameSize()
                guard points.width > 0, points.height > 0 else { return }
                rendering = true
                defer { rendering = false }
                let rendered = await CameraPreviewMonitor.shared.renderer.render(
                    box.value, maximumWidth: Self.renderWidth(canvasPoints: canvasWidth)
                )
                guard token == generation, let rendered else { return }
                image = NSImage(cgImage: rendered.image, size: rendered.size)
                thumbnailPixelSize = box.pixelSize
                frameSize = points
                if drag == nil {
                    options = RecordingSettings.load(from: .standard).camera.resolved()
                }
            }
        }
    }

    private func deactivate() {
        // A drag interrupted by the panel closing still meant it: persist what it reached
        // rather than losing the placement to a missing end event.
        if drag?.movesCamera == true {
            CameraOverlayController.shared.applyPlacement(options, source: .stage, persists: true)
        }
        generation &+= 1
        setSink(nil)
        rendering = false
        drag = nil
        image = nil
        thumbnailPixelSize = .zero
        frameSize = .zero
    }

    /// Twice the canvas's points, so a Retina panel is shown the composite rather than an
    /// upscale of it; floored so a canvas that has not been measured yet still gets a usable
    /// image, and capped because a 248 pt viewport has no use for 4K.
    static func renderWidth(canvasPoints: CGFloat) -> CGFloat {
        min(maximumRenderWidth, max(320, canvasPoints * 2))
    }

    /// Aspect-fits the actual recording pixels into the panel canvas.
    static func thumbnailRect(for pixelSize: CGSize, in bounds: CGRect) -> CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
        let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Maps the y-up recording rectangle into SwiftUI's y-down thumbnail coordinates.
    static func cameraRect(options: CameraOptions, frameSize: CGSize, thumbnail: CGRect) -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0, !thumbnail.isEmpty else { return .zero }
        let rect = options.rect(in: frameSize)
        let scale = thumbnail.width / frameSize.width
        return CGRect(
            x: thumbnail.minX + rect.minX * scale,
            y: thumbnail.minY + (frameSize.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    static func recordingTranslation(_ translation: CGSize, frameSize: CGSize, thumbnail: CGRect) -> CGPoint {
        guard frameSize.width > 0, thumbnail.width > 0 else { return .zero }
        let scale = thumbnail.width / frameSize.width
        return CGPoint(x: translation.width / scale, y: -translation.height / scale)
    }

    static func yUpThumbnailRect(_ rect: CGRect, frameSize: CGSize, thumbnail: CGRect) -> CGRect {
        guard frameSize.width > 0 else { return .zero }
        let scale = thumbnail.width / frameSize.width
        return CGRect(x: rect.minX * scale, y: rect.minY * scale,
                      width: rect.width * scale, height: rect.height * scale)
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
                RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous)
                    .fill(CamcordStyle.quietFill)
                if let thumbnail = presentation?.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous))
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
                RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous)
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
                RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous)
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
    /// The name VoiceOver reads. Without it the whole help sentence becomes the name, and
    /// two eye buttons on the same panel are told apart only by a paragraph.
    var label: String? = nil
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
        .accessibilityLabel(label ?? help)
        .accessibilityHint(label == nil ? "" : help)
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
                    RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous)
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
                    RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous)
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
                RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous)
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
            .background(RoundedRectangle(cornerRadius: CamcordStyle.Radius.control).fill(Color.white.opacity(0.16)))
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
                .contentShape(RoundedRectangle(cornerRadius: CamcordStyle.Radius.control))
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
