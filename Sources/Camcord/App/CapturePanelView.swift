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
    var captureText: () -> Void = {}
    /// Start an interactive recording when idle; stop it otherwise.
    var toggleRecording: () -> Void = {}
    var recordFullScreen: () -> Void = {}
    var pauseResume: () -> Void = {}
    var revealRecording: (URL) -> Void = { _ in }
    var openRecording: (URL) -> Void = { _ in }
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
    @State private var isMicrophoneDenied = false

    /// One physical signature for every elastic transition in the panel.
    static let panelSpring: Animation = .spring(response: 0.34, dampingFraction: 0.86)

    /// The panel is a FIXED size: a constant popover never resizes, so it never
    /// slides out from under the status item when the state changes (idle grid →
    /// finishing → done card). Content is laid out inside this frame.
    static let panelWidth: CGFloat = 268
    static let panelHeight: CGFloat = 178

    var body: some View {
        ZStack {
            if let url = model.finishedURL {
                FinishedCard(
                    url: url,
                    reveal: { actions.revealRecording(url) },
                    open: { actions.openRecording(url) },
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
        .frame(width: Self.panelWidth, height: Self.panelHeight)
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
            CaptureTile(symbol: "text.viewfinder", title: "Metin", action: actions.captureText)
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

            Spacer()

            FooterIconButton(symbol: "gearshape.fill", help: "Ayarlar", action: actions.openSettings)
        }
    }

    // MARK: - Persistence

    private func reloadPersistedState() {
        let settings = RecordingSettings.load(from: .standard)
        recordSystemAudio = settings.systemAudio
        recordMicrophone = settings.microphone
        soundEnabled = FeedbackSound.isEnabled()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        isMicrophoneDenied = micStatus == .denied || micStatus == .restricted
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

/// The "recording done" card: an animated check, the file name, and actions to open
/// the file / reveal it in Finder. Stays until dismissed or the panel is reopened —
/// it deliberately does NOT snap back to the capture grid.
private struct FinishedCard: View {
    let url: URL
    let reveal: () -> Void
    let open: () -> Void
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(.green.opacity(0.14))
                    .frame(width: 46, height: 46)
                    .scaleEffect(appeared ? 1 : 0.5)
                    .opacity(appeared ? 1 : 0)
                Image(systemName: "checkmark")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.green)
                    .scaleEffect(appeared ? 1 : 0.2)
                    .opacity(appeared ? 1 : 0)
            }

            Text("Kayıt bitti")
                .font(.system(size: 14.5, weight: .semibold))

            Text(url.lastPathComponent)
                .font(.system(size: 11))
                .foregroundStyle(Color.primary.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 20)

            HStack(spacing: 8) {
                CardButton(title: "Finder'da Göster", symbol: "folder", action: reveal)
                CardButton(title: "Aç", symbol: "play.fill", prominent: true, action: open)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
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
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.58)) { appeared = true }
            }
        }
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
