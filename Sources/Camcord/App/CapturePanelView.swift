import AVFoundation
import AppKit
import KeyboardShortcuts
import SwiftUI

/// Shared recording state for SwiftUI surfaces (the panel). Pushed by
/// `RecordingController.onUIChange` via AppDelegate — single source of truth,
/// same feed that drives the status-item glyph.
@MainActor
final class RecordingStateModel: ObservableObject {
    @Published var state: RecordingController.UIState = .idle
    @Published var elapsed: String?
    /// Bumped by PanelController on every show. The popover's hosting controller is
    /// retained across shows, so `@State` persists and `onAppear` fires only once —
    /// this token is what resets the page and reloads persisted toggles per open.
    @Published var panelOpenToken = 0
}

/// The panel's actions, injected by AppDelegate. Each closure owns its own
/// popover-closing/delay choreography.
@MainActor
struct PanelActions {
    var captureRegion: () -> Void = {}
    var captureWindow: () -> Void = {}
    var captureScreen: () -> Void = {}
    var repeatLast: () -> Void = {}
    var toggleRecording: () -> Void = {}
    var pauseResume: () -> Void = {}
    var applyTapBindings: (TapBindings) -> Void = { _ in }
    /// Shortcut recorders need the app active to receive keystrokes; called when
    /// the shortcuts page opens.
    var activateApp: () -> Void = {}
    var openSettings: () -> Void = {}
}

enum PanelPage {
    case main
    case shortcuts
}

/// True inside the headless preview harness (`--render-panel`): AppKit-backed
/// controls (KeyboardShortcuts.Recorder, menu Pickers) can't be rendered by
/// ImageRenderer, so rows substitute static stand-ins with the same geometry.
private struct PanelPreviewModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isPanelPreview: Bool {
        get { self[PanelPreviewModeKey.self] }
        set { self[PanelPreviewModeKey.self] = newValue }
    }
}

/// The menu-bar panel, 264pt wide, two pages with a horizontal slide between them.
///
/// Main page — a quiet control surface with one bold element: the record row, which
/// morphs from a single idle line into a live session bar (pulsing dot, monospaced
/// elapsed, pause/stop) while recording. Shortcuts page — inline recorders for the
/// daily-use keyboard shortcuts plus the mouse/gesture bindings (the full list,
/// including the rarer ones, lives in Settings).
struct CapturePanelView: View {
    @ObservedObject var model: RecordingStateModel
    let actions: PanelActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: PanelPage
    @State private var recordSystemAudio = true
    @State private var recordMicrophone = true
    @State private var captureSound = true
    @State private var isMicrophoneDenied = false
    @State private var tapBindings = TapBindings()

    /// One physical signature for every elastic transition in the panel.
    static let panelSpring: Animation = .spring(response: 0.34, dampingFraction: 0.86)

    /// Explicit page heights so the popover's resize is animated BY SwiftUI (the
    /// hosting controller's preferred size then moves through the same spring as the
    /// page slide) instead of NSPopover snapping to the new size on its own clock.
    /// Derived from the fixed row/spacing constants below — update together.
    private static let mainPageHeight: CGFloat = 175
    private static let shortcutsPageHeight: CGFloat = 437

    init(model: RecordingStateModel, actions: PanelActions, initialPage: PanelPage = .main) {
        self.model = model
        self.actions = actions
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if page == .main {
                mainPage
                    .transition(pageTransition(edge: .leading))
            } else {
                shortcutsPage
                    .transition(pageTransition(edge: .trailing))
            }
        }
        .frame(width: 264)
        .frame(height: page == .main ? Self.mainPageHeight : Self.shortcutsPageHeight, alignment: .top)
        .animation(reduceMotion ? nil : Self.panelSpring, value: page)
        .onAppear(perform: reloadPersistedState)
        .onChange(of: model.panelOpenToken) { _, _ in
            // Fresh open: back to the main page, re-read persisted toggles (they may
            // have changed via the Settings window while the panel was closed).
            page = .main
            reloadPersistedState()
        }
        .onChange(of: page) { _, newPage in
            if newPage == .shortcuts {
                actions.activateApp()
            }
        }
    }

    private func pageTransition(edge: Edge) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: edge).combined(with: .opacity),
                removal: .move(edge: edge).combined(with: .opacity)
            )
    }

    // MARK: - Main page

    private var mainPage: some View {
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

    /// Live labels: the hardcoded defaults would go stale the moment the user
    /// rebinds a shortcut on the Kısayollar page or in Settings. The body re-renders
    /// on every panel open (panelOpenToken), so these always read current.
    private func shortcutHint(for name: KeyboardShortcuts.Name) -> String {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return "—" }
        return "\(shortcut)"
    }

    private var captureGrid: some View {
        HStack(spacing: 6) {
            CaptureTile(
                symbol: "rectangle.dashed", title: "Bölge",
                shortcut: shortcutHint(for: .captureRegion), action: actions.captureRegion
            )
            CaptureTile(
                symbol: "macwindow", title: "Pencere",
                shortcut: shortcutHint(for: .captureActiveWindow), action: actions.captureWindow
            )
            CaptureTile(
                symbol: "display", title: "Ekran",
                shortcut: shortcutHint(for: .captureFullScreen), action: actions.captureScreen
            )
            CaptureTile(
                symbol: "arrow.counterclockwise", title: "Son bölge",
                shortcut: shortcutHint(for: .repeatLastRegion), action: actions.repeatLast
            )
        }
    }

    @ViewBuilder
    private var recordRow: some View {
        switch model.state {
        case .idle:
            HoverScaleButton(action: actions.toggleRecording) { hovering in
                HStack(spacing: 9) {
                    ZStack {
                        Circle()
                            .fill(.red.opacity(hovering ? 0.22 : 0))
                            .frame(width: 18, height: 18)
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                    }
                    Text("Kayıt başlat")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    KeyCap(shortcutHint(for: .toggleRecording))
                }
                .padding(.horizontal, 11)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(hovering ? 0.07 : 0.045))
                )
            }

        case .recording, .paused:
            HStack(spacing: 9) {
                PulsingDot(paused: model.state == .paused, reduceMotion: reduceMotion)
                Text(model.elapsed ?? "0:00")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    // numericText only animates inside a transaction; elapsed is
                    // assigned plainly every second, so drive it explicitly.
                    .animation(reduceMotion ? nil : .default, value: model.elapsed)
                if model.state == .paused {
                    Text("duraklatıldı")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.62))
                }
                Spacer()
                RoundIconButton(
                    symbol: model.state == .paused ? "play.fill" : "pause.fill",
                    help: model.state == .paused
                        ? "Sürdür (\(shortcutHint(for: .pauseRecording)))"
                        : "Duraklat (\(shortcutHint(for: .pauseRecording)))",
                    action: actions.pauseResume
                )
                RoundIconButton(
                    symbol: "stop.fill", tint: .red,
                    help: "Kaydı bitir (\(shortcutHint(for: .toggleRecording)))",
                    action: actions.toggleRecording
                )
            }
            .padding(.horizontal, 11)
            .frame(height: 40)
            .background(
                // Three-color state language: red = live, orange = paused, neutral =
                // idle. The paused container follows the dot to orange instead of
                // staying a dimmed red alert.
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
            ToggleChip(onSymbol: "bell.fill", offSymbol: "bell.slash.fill", help: "Çekim sesi çal", isOn: $captureSound) {
                CaptureFeedback.setEnabled(captureSound)
            }

            Spacer()

            FooterTextButton(title: "Kısayollar", trailingSymbol: "chevron.right") {
                page = .shortcuts
            }
            FooterIconButton(symbol: "gearshape.fill", help: "Ayarlar", action: actions.openSettings)
        }
    }

    // MARK: - Shortcuts page

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Text("Kısayollar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                HStack {
                    FooterTextButton(title: "Geri", leadingSymbol: "chevron.left") {
                        page = .main
                    }
                    Spacer()
                }
            }
            .padding(.bottom, 2)

            ShortcutRow(title: "Bölge çek", name: .captureRegion)
            ShortcutRow(title: "Aktif pencere", name: .captureActiveWindow)
            ShortcutRow(title: "Tüm ekran", name: .captureFullScreen)
            ShortcutRow(title: "Son bölgeyi tekrarla", name: .repeatLastRegion)
            ShortcutRow(title: "Metni çek (OCR)", name: .captureTextRegion)
            ShortcutRow(title: "Renk seç", name: .sampleColor)
            ShortcutRow(title: "Kayıt başlat/durdur", name: .toggleRecording)
            ShortcutRow(title: "Kayıt duraklat", name: .pauseRecording)

            PanelDivider()
                .padding(.vertical, 2)

            BindingRow(title: "Fare düğmesi 4", selection: $tapBindings.mouseButton4, onChange: saveTapBindings)
            BindingRow(title: "Fare düğmesi 5", selection: $tapBindings.mouseButton5, onChange: saveTapBindings)
            BindingRow(title: "Çift dokunuş Sağ ⌘", selection: $tapBindings.doubleTapRightCommand, onChange: saveTapBindings)
        }
        .padding(12)
    }

    // MARK: - Persistence

    private func reloadPersistedState() {
        let settings = RecordingSettings.load(from: .standard)
        recordSystemAudio = settings.systemAudio
        recordMicrophone = settings.microphone
        captureSound = CaptureFeedback.isEnabled()
        tapBindings = TapBindings.load(from: .standard)
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        isMicrophoneDenied = micStatus == .denied || micStatus == .restricted
    }

    private func saveRecordingSettings() {
        RecordingSettings(systemAudio: recordSystemAudio, microphone: recordMicrophone).save(to: .standard)
    }

    private func saveTapBindings() {
        tapBindings.save(to: .standard)
        actions.applyTapBindings(tapBindings)
    }
}

// MARK: - Components

/// One capture action: icon over a tiny label, generous hit target, soft hover fill,
/// gentle press scale.
private struct CaptureTile: View {
    let symbol: String
    let title: String
    let shortcut: String
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
                // Hover delta matched to the panel's other controls (Δ~0.065) — the
                // most-hovered tiles shouldn't give the weakest feedback.
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(hovering ? 0.11 : 0.045))
            )
        }
        .help("\(title) (\(shortcut))")
    }
}

/// Keyboard-shortcut chip, e.g. ⌘⇧9.
private struct KeyCap: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.06))
            )
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
                    // A tinted action (the destructive stop) gets a matching tinted
                    // container so it reads at a glance, not just by glyph color.
                    Circle()
                        .fill((tint ?? Color.primary).opacity(
                            tint == nil ? (hovering ? 0.13 : 0.07) : (hovering ? 0.16 : 0.09)
                        ))
                )
        }
        .help(help)
    }
}

/// Footer toggle: filled symbol when on, slashed + faint when off. `warning` tints
/// the symbol orange (e.g. mic wanted but the OS permission is denied).
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
                    // Hover must register in BOTH states — the defaults are all-on,
                    // so an ON-only fill would make these read as inert.
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

private struct FooterTextButton: View {
    var title: String
    var leadingSymbol: String? = nil
    var trailingSymbol: String? = nil
    let action: () -> Void

    var body: some View {
        HoverScaleButton(action: action) { hovering in
            HStack(spacing: 3) {
                if let leadingSymbol {
                    Image(systemName: leadingSymbol)
                        .font(.system(size: 8, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                if let trailingSymbol {
                    Image(systemName: trailingSymbol)
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            )
        }
    }
}

/// One shortcut-editing row: label left, live recorder right.
private struct ShortcutRow: View {
    let title: String
    let name: KeyboardShortcuts.Name
    @Environment(\.isPanelPreview) private var isPanelPreview

    @MainActor private var currentShortcutLabel: String {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return "kaydet" }
        return "\(shortcut)"
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
            Spacer()
            if isPanelPreview {
                KeyCap(currentShortcutLabel)
            } else {
                KeyboardShortcuts.Recorder(for: name)
                    .controlSize(.small)
            }
        }
        .frame(height: 26)
    }
}

/// One tap-binding row: label left, compact menu picker right.
private struct BindingRow: View {
    let title: String
    @Binding var selection: TapAction?
    let onChange: () -> Void
    @Environment(\.isPanelPreview) private var isPanelPreview

    private var selectionLabel: String {
        switch selection {
        case .none: "Kapalı"
        case .captureRegion: "Bölge çek"
        case .toggleRecording: "Kayıt"
        }
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
            Spacer()
            if isPanelPreview {
                KeyCap(selectionLabel)
            } else {
                Picker("", selection: $selection) {
                    Text("Kapalı").tag(TapAction?.none)
                    Text("Bölge çek").tag(TapAction?.some(.captureRegion))
                    Text("Kayıt").tag(TapAction?.some(.toggleRecording))
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 110)
                .onChange(of: selection) { _, _ in onChange() }
            }
        }
        .frame(height: 26)
    }
}

private struct PanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
    }
}

/// Shared hover + press treatment: content closure receives the hover flag; the
/// button applies a gentle press scale. One motion language for every control.
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

