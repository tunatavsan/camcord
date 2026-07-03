import SwiftUI

/// Shared recording state for SwiftUI surfaces (the panel). Pushed by
/// `RecordingController.onUIChange` via AppDelegate — single source of truth,
/// same feed that drives the status-item glyph.
@MainActor
final class RecordingStateModel: ObservableObject {
    @Published var state: RecordingController.UIState = .idle
    @Published var elapsed: String?
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
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
}

/// The menu-bar panel: a 248pt-wide, quiet control surface. One bold element —
/// the record row, which morphs from a single idle line into a live session bar
/// (pulsing dot + monospaced elapsed + pause/stop) while recording.
struct CapturePanelView: View {
    @ObservedObject var model: RecordingStateModel
    let actions: PanelActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recordSystemAudio = true
    @State private var recordMicrophone = true
    @State private var captureSound = true

    var body: some View {
        VStack(spacing: 10) {
            captureGrid

            divider

            recordRow
                .animation(reduceMotion ? nil : .spring(duration: 0.3), value: model.state)

            divider

            footer
        }
        .padding(12)
        .frame(width: 248)
        .onAppear(perform: reloadToggles)
    }

    // MARK: - Capture grid

    private var captureGrid: some View {
        HStack(spacing: 6) {
            CaptureButton(symbol: "rectangle.dashed", title: "Bölge", shortcut: "⌘⇧2", action: actions.captureRegion)
            CaptureButton(symbol: "macwindow", title: "Pencere", shortcut: "⌘⇧1", action: actions.captureWindow)
            CaptureButton(symbol: "rectangle.inset.filled", title: "Ekran", shortcut: "⌘⇧6", action: actions.captureScreen)
            CaptureButton(symbol: "arrow.counterclockwise", title: "Tekrar", shortcut: "⌘⇧R", action: actions.repeatLast)
        }
    }

    // MARK: - Record row (the signature element)

    @ViewBuilder
    private var recordRow: some View {
        switch model.state {
        case .idle:
            Button(action: actions.toggleRecording) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Kayıt başlat")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("⌘⇧9")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(QuietRowButtonStyle())

        case .recording, .paused:
            HStack(spacing: 8) {
                PulsingDot(paused: model.state == .paused, reduceMotion: reduceMotion)
                Text(model.elapsed ?? "0:00")
                    .font(.body.monospacedDigit().weight(.medium))
                if model.state == .paused {
                    Text("duraklatıldı")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: actions.pauseResume) {
                    Image(systemName: model.state == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(QuietIconButtonStyle())
                .help(model.state == .paused ? "Sürdür (⌘⇧0)" : "Duraklat (⌘⇧0)")
                Button(action: actions.toggleRecording) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(QuietIconButtonStyle())
                .help("Kaydı bitir (⌘⇧9)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.red.opacity(model.state == .paused ? 0.06 : 0.09))
            )
        }
    }

    // MARK: - Footer: quick toggles + settings/quit

    private var footer: some View {
        HStack(spacing: 4) {
            QuickToggle(symbol: "speaker.wave.2.fill", help: "Sistem sesini kaydet", isOn: $recordSystemAudio) {
                saveRecordingSettings()
            }
            QuickToggle(symbol: "mic.fill", help: "Mikrofonu kaydet", isOn: $recordMicrophone) {
                saveRecordingSettings()
            }
            QuickToggle(symbol: "bell.fill", help: "Çekim sesi", isOn: $captureSound) {
                CaptureFeedback.setEnabled(captureSound)
            }

            Spacer()

            Button("Ayarlar…", action: actions.openSettings)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("·")
                .font(.caption)
                .foregroundStyle(.quaternary)
            Button("Çıkış", action: actions.quit)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.quaternary.opacity(0.5))
            .frame(height: 1)
    }

    // MARK: - Toggle persistence

    private func reloadToggles() {
        let settings = RecordingSettings.load(from: .standard)
        recordSystemAudio = settings.systemAudio
        recordMicrophone = settings.microphone
        captureSound = CaptureFeedback.isEnabled()
    }

    private func saveRecordingSettings() {
        RecordingSettings(systemAudio: recordSystemAudio, microphone: recordMicrophone).save(to: .standard)
    }
}

// MARK: - Pieces

private struct CaptureButton: View {
    let symbol: String
    let title: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 18)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(QuietRowButtonStyle())
        .help("\(title) (\(shortcut))")
    }
}

private struct QuickToggle: View {
    let symbol: String
    let help: String
    @Binding var isOn: Bool
    let onChange: () -> Void

    var body: some View {
        Button {
            isOn.toggle()
            onChange()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isOn ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
                )
        }
        .buttonStyle(.plain)
        .help(help)
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
            .frame(width: 8, height: 8)
            .opacity(dimmed && !paused && !reduceMotion ? 0.35 : 1)
            .animation(
                paused || reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: dimmed
            )
            .onAppear { dimmed = true }
    }
}

private struct QuietRowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed
                        ? AnyShapeStyle(.quaternary)
                        : hovering ? AnyShapeStyle(.quaternary.opacity(0.55)) : AnyShapeStyle(.clear))
            )
            .onHover { hovering = $0 }
    }
}

private struct QuietIconButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed
                        ? AnyShapeStyle(.quaternary)
                        : hovering ? AnyShapeStyle(.quaternary.opacity(0.55)) : AnyShapeStyle(.clear))
            )
            .onHover { hovering = $0 }
    }
}
