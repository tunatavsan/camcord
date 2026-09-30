import AVFoundation
import SwiftUI

/// What one audio channel's controls do right now, and whether its meter has anything to
/// show. Pure: this is the table the tests walk, and the only place the panel asks these
/// questions — a control that looks live but does nothing is the failure being avoided.
struct AudioChannelState: Equatable, Sendable {
    /// The channel switch. The engine binds its sources when a recording starts, so
    /// flipping it mid-recording would promise a track the file will never carry.
    var switchLive: Bool
    /// The gain slider, which stays live during a recording: gain is applied to the
    /// samples as they are processed, not at the source.
    var gainLive: Bool
    /// Whether the meter has a live signal behind it — otherwise it is an inert scale.
    var meterAnimates: Bool

    /// The system channel has no probe of its own: the only level it can ever show is the
    /// one a running recording measures.
    static func system(enabled: Bool, recording: Bool, paused: Bool, starting: Bool) -> AudioChannelState {
        AudioChannelState(
            switchLive: !recording && !starting,
            gainLive: enabled,
            meterAnimates: enabled && recording && !paused
        )
    }

    /// The microphone channel can also be rehearsed with no recording running, which is
    /// what `testing` is. Denied permission takes the whole channel out of service.
    static func microphone(
        enabled: Bool,
        denied: Bool,
        recording: Bool,
        paused: Bool,
        starting: Bool,
        testing: Bool
    ) -> AudioChannelState {
        AudioChannelState(
            switchLive: !denied && !recording && !starting,
            gainLive: enabled && !denied,
            meterAnimates: enabled && !denied && ((recording && !paused) || testing)
        )
    }

    /// The microphone the picker should show, and the one a rehearsal should open: the
    /// saved input while it is still plugged in, the system default once it is not. A
    /// device that went away must not leave the picker blank or point a recording at
    /// nothing.
    static func resolvedInput(saved: String?, available: [String]) -> String? {
        guard let saved, available.contains(saved) else { return nil }
        return saved
    }
}

/// The panel's audio mixer: two channels, each with its own switch, live meter and gain,
/// plus the microphone's input picker and a rehearsal that moves the meter without
/// recording anything. Everything it drives already exists in the model layer — this
/// assembles it, it does not add an audio path.
struct AudioChannelStrip: View {
    let health: RecordingHealth?
    let state: RecordingController.UIState
    let isStarting: Bool
    let microphoneDenied: Bool
    @Binding var systemEnabled: Bool
    @Binding var microphoneEnabled: Bool
    @Binding var systemGainDB: Double
    @Binding var microphoneGainDB: Double
    @Binding var microphoneDeviceID: String?
    @Binding var mixTracks: Bool
    /// Persist the switches; the gains and the device have their own writers.
    let onChannelToggle: () -> Void
    let onGainChange: (Double?, Double?) -> Void
    let onDeviceChange: (String?) -> Void
    let onMixChange: () -> Void

    @Environment(\.camcordDesignPreview) private var designPreview
    @ObservedObject private var monitor = MicrophoneMonitor.shared
    @State private var inputs: [AVCaptureDevice] = []
    @State private var microphoneOwner = UUID()
    @State private var rehearsalVisible = false
    private var ownsRehearsal: Bool { monitor.owns(microphoneOwner) }
    private var rehearsalRunning: Bool { ownsRehearsal && monitor.isRunning }

    private var recording: Bool { state != .idle }

    private var systemState: AudioChannelState {
        .system(enabled: systemEnabled, recording: recording, paused: state == .paused, starting: isStarting)
    }

    private var microphoneState: AudioChannelState {
        .microphone(
            enabled: microphoneEnabled, denied: microphoneDenied, recording: recording,
            paused: state == .paused, starting: isStarting, testing: rehearsalRunning
        )
    }

    /// The mic meter reads the rehearsal while one is running and the recording otherwise,
    /// so the same strip serves both without a second meter.
    private var microphoneLevels: AudioLevels? {
        rehearsalRunning ? monitor.levels : health?.microphone.levels
    }

    var body: some View {
        VStack(spacing: 8) {
            AudioChannelRow(
                title: "Sistem",
                symbol: "speaker.wave.2",
                levels: health?.systemAudio.levels,
                channel: systemState,
                gainDB: $systemGainDB,
                range: -60...12,
                isOn: $systemEnabled,
                onToggle: onChannelToggle,
                onGainChange: { onGainChange($0, nil) }
            )

            AudioChannelRow(
                title: "Mikrofon",
                symbol: microphoneDenied ? "mic.slash" : "mic",
                levels: microphoneLevels,
                channel: microphoneState,
                gainDB: $microphoneGainDB,
                range: -24...24,
                isOn: $microphoneEnabled,
                onToggle: onChannelToggle,
                onGainChange: { gain in
                    onGainChange(nil, gain)
                    monitor.updateGain(gain, owner: microphoneOwner)
                }
            )

            microphoneInputRow

            Toggle("Tek ses kanalında birleştir", isOn: $mixTracks)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 10))
                .disabled(recording || isStarting || !(systemEnabled && microphoneEnabled))
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Sistem sesi ile mikrofonu dosyada tek bir ses kanalında birleştirir")
                .onChange(of: mixTracks) { _, _ in onMixChange() }

            if ownsRehearsal, let message = monitor.message {
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: designPreview) { rehearsalVisible = !designPreview; await loadInputs() }
        // Switching the channel off is the owner saying "not this microphone": an open
        // rehearsal would otherwise keep the input light on with a meter that reads dead.
        .onChange(of: microphoneEnabled) { _, enabled in
            guard !enabled else { return }
            stopRehearsal()
        }
        .onDisappear { rehearsalVisible = false; stopRehearsal() }
    }

    private var microphoneInputRow: some View {
        HStack(spacing: 6) {
            Picker("", selection: inputSelection) {
                Text("Sistem varsayılanı").tag(String?.none)
                ForEach(inputs, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(String?.some(device.uniqueID))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .font(.system(size: 10))
            .disabled(!microphoneState.switchLive || !microphoneEnabled)
            .accessibilityLabel("Mikrofon girişi")

            Button(action: toggleRehearsal) {
                Text(ownsRehearsal ? "Durdur" : "Test")
                    .font(.system(size: 10, weight: .medium))
                    .frame(minWidth: 38)
            }
            .controlSize(.small)
            .disabled(rehearsalDisabled)
            .help(microphoneDenied
                ? "Mikrofon izni yok — İzinler bölümünü açar"
                : "Mikrofonu kayıt almadan dinler, seviyeyi buradan görürsün")
        }
    }

    /// A rehearsal is impossible while the recording owns the device; a denied permission
    /// still leaves the button pressable, because pressing it is how the owner gets to the
    /// place that fixes it. A rehearsal that is ALREADY running can always be stopped —
    /// greying "Durdur" out would leave the microphone open with no way to close it.
    private var rehearsalDisabled: Bool {
        if ownsRehearsal { return monitor.recordingLocked }
        return monitor.recordingLocked || recording || isStarting
            || (!microphoneEnabled && !microphoneDenied)
    }

    private var inputSelection: Binding<String?> {
        Binding(
            get: { AudioChannelState.resolvedInput(saved: microphoneDeviceID, available: inputs.map(\.uniqueID)) },
            set: { onDeviceChange($0) }
        )
    }

    private func toggleRehearsal() {
        guard !designPreview else { return }
        guard !microphoneDenied else {
            NSWorkspace.shared.open(PermissionRecovery.microphonePaneURL)
            return
        }
        let owner = microphoneOwner
        Task {
            guard rehearsalVisible, microphoneOwner == owner else { return }
            if monitor.owns(owner) {
                await monitor.release(owner: owner)
            } else {
                await monitor.start(owner: owner,
                    deviceID: AudioChannelState.resolvedInput(
                        saved: microphoneDeviceID, available: inputs.map(\.uniqueID)
                    ),
                    gainDB: microphoneGainDB
                )
            }
        }
    }

    private func stopRehearsal() {
        guard !designPreview else { return }
        let retiringOwner = microphoneOwner
        microphoneOwner = UUID()
        Task { await monitor.release(owner: retiringOwner) }
    }

    private func loadInputs() async {
        guard !designPreview else { return }
        inputs = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
    }
}

/// One channel: name and switch over a live meter, with its gain underneath.
private struct AudioChannelRow: View {
    let title: String
    let symbol: String
    let levels: AudioLevels?
    let channel: AudioChannelState
    @Binding var gainDB: Double
    let range: ClosedRange<Double>
    @Binding var isOn: Bool
    let onToggle: () -> Void
    let onGainChange: (Double) -> Void

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 74, alignment: .leading)
                AudioLevelMeter(levels: levels, active: channel.meterAnimates)
                Text(isOn ? String(format: "%+.0f dB", gainDB) : "Kapalı")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .frame(width: 43, alignment: .trailing)
                Toggle(title, isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!channel.switchLive)
                    .onChange(of: isOn) { _, _ in onToggle() }
                    .accessibilityLabel("\(title) sesini kaydet")
            }
            Slider(value: $gainDB, in: range, step: 1)
                .controlSize(.mini)
                .disabled(!channel.gainLive)
                .onChange(of: gainDB) { _, value in onGainChange(value) }
                .accessibilityLabel("\(title) ses kazancı")
                .accessibilityValue("\(Int(gainDB)) desibel")
        }
        .opacity(isOn ? 1 : 0.55)
    }
}
