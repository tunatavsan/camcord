import AVFoundation
import KeyboardShortcuts
import SwiftUI

struct StudioInspector: View {
    let session: StudioSession
    @ObservedObject var state: RecordingStateModel
    let allowsPreview: Bool
    let completed: Bool
    let record: () -> Void
    @State private var cameras: [AVCaptureDevice] = []
    @State private var microphones: [AVCaptureDevice] = []
    @State private var showsLayers = false
    private var policy: StudioEditingPolicy {
        StudioEditingPolicy(state: state.state, isStarting: state.isStarting, isFinishing: state.isFinishing,
                            isArmed: state.isArmed, controllerBusy: session.isBusy, allowsPreview: allowsPreview)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Studio.sectionSpacing) {
                    StudioAudioSection(session: session, state: state, microphones: microphones,
                                       locked: policy.bindingsLocked, liveLocked: policy.liveEditsLocked,
                                       allowsPreview: allowsPreview)
                    StudioCameraSection(session: session, cameras: cameras, locked: policy.bindingsLocked,
                                        liveLocked: policy.liveEditsLocked)
                    StudioFormatSection(session: session, locked: policy.bindingsLocked)
                    DisclosureGroup(isExpanded: $showsLayers) {
                        StudioLayersInspector(document: session.layers, locked: policy.liveEditsLocked)
                            .padding(.top, Theme.Space.s)
                    } label: { StudioSectionHeading(title: "Layers") }
                }
                .padding(.horizontal, Theme.Studio.sideInset)
                .padding(.vertical, Theme.Studio.sideInset)
            }
            if state.state == .idle {
                StudioPrimaryRecord(state: state, canStart: session.canStart && allowsPreview,
                                    completed: completed, record: record)
                    .padding(Theme.Studio.sideInset)
            }
        }
        .background(Theme.Palette.surface.color)
        .tint(Theme.Palette.ink.color)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.Palette.hairline.color).frame(width: 0.5) }
        .task(id: allowsPreview) { if allowsPreview { refreshDevices() } }
        .onReceive(StudioDeviceNotifications.publisher()) { _ in if allowsPreview { refreshDevices() } }
    }
    private func refreshDevices() {
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                   mediaType: .video, position: .unspecified).devices
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                       mediaType: .audio, position: .unspecified).devices
    }
}

struct StudioSectionHeading: View {
    let title: LocalizedStringResource
    var body: some View {
        Text(title).font(Theme.Font.captionStrong).foregroundStyle(Theme.Palette.ink3.color)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct StudioPrimaryRecord: View {
    @ObservedObject var state: RecordingStateModel
    let canStart: Bool
    let completed: Bool
    let record: () -> Void
    private var shortcut: String? { KeyboardShortcuts.getShortcut(for: .toggleRecording)?.description }
    var body: some View {
        Button(action: record) {
            HStack(spacing: Theme.Studio.sourceGap) {
                if state.isStarting || state.isFinishing { ProgressView().controlSize(.small) }
                else { Circle().fill(Theme.Palette.onRecord.color).frame(width: Theme.Studio.gainKnob, height: Theme.Studio.gainKnob) }
                Text(completed ? LocalizedStringResource("Record again") : LocalizedStringResource("Record"))
                    .font(Theme.Font.rowStrong)
                if let shortcut { Text(verbatim: shortcut).font(Theme.Font.dataSmall) }
            }
            .frame(maxWidth: .infinity).frame(height: Theme.Studio.primaryHeight)
            .foregroundStyle(Theme.Palette.onRecord.color)
            .background(Theme.Palette.record.color, in: .rect(cornerRadius: Theme.Radius.box))
        }
        .buttonStyle(.plain)
        .disabled(!canStart || state.isStarting || state.isFinishing || state.isArmed)
        .help(Text(canStart ? LocalizedStringResource("Start recording") : LocalizedStringResource("Choose an available source and allow Screen Recording to record.")))
    }
}

private struct StudioAudioSection: View {
    let session: StudioSession
    @ObservedObject var state: RecordingStateModel
    @ObservedObject private var microphone: MicrophoneMonitor
    let microphones: [AVCaptureDevice]
    let locked: Bool
    let liveLocked: Bool
    let allowsPreview: Bool
    init(session: StudioSession, state: RecordingStateModel, microphones: [AVCaptureDevice],
         locked: Bool, liveLocked: Bool, allowsPreview: Bool) {
        self.session = session; self.state = state; self.microphones = microphones
        self.locked = locked; self.liveLocked = liveLocked; self.allowsPreview = allowsPreview
        self.microphone = session.microphoneMonitor
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            StudioSectionHeading(title: "Audio")
            StudioAudioChannel(title: "System audio", symbol: "speaker.wave.2", enabled: setting(\.systemAudio),
                               gain: setting(\.systemAudioGainDB), range: -60...12,
                               levels: state.state == .idle ? session.systemAudioLevels : state.health?.systemAudio.levels,
                               measures: allowsPreview && state.state != .paused, locked: locked, liveLocked: liveLocked,
                               unavailable: session.selectedSource == nil ? "Choose a source to monitor system audio." : "Waiting for audio…")
            StudioAudioChannel(title: "Microphone", symbol: "mic", enabled: setting(\.microphone),
                               gain: setting(\.microphoneGainDB), range: -24...24, levels: session.microphoneLevels,
                               measures: allowsPreview && state.state != .paused, locked: locked, liveLocked: liveLocked,
                               unavailable: session.ownsMicrophoneTest ? "Waiting for audio…" : "Microphone permission or input is unavailable.")
            StudioPopupRow(title: "Input", selection: setting(\.microphoneDeviceID),
                           options: deviceOptions(microphones, selected: session.settings.microphoneDeviceID, mediaType: .audio))
                .disabled(locked)
            if let message = microphone.message {
                Text(verbatim: message).font(Theme.Font.caption).foregroundStyle(Theme.Palette.warn.color)
            }
            Toggle("Mix into one audio track", isOn: setting(\.mixAudioTracks))
                .toggleStyle(.checkbox).font(Theme.Font.caption).disabled(locked)
        }
    }
    private func setting<Value>(_ key: WritableKeyPath<RecordingSettings, Value>) -> Binding<Value> {
        Binding(get: { session.settings[keyPath: key] }, set: { value in session.updateSettings { $0[keyPath: key] = value } })
    }
}

private struct StudioAudioChannel: View {
    let title: LocalizedStringResource
    let symbol: String
    @Binding var enabled: Bool
    @Binding var gain: Double
    let range: ClosedRange<Double>
    let levels: AudioLevels?
    let measures: Bool
    let locked: Bool
    let liveLocked: Bool
    let unavailable: LocalizedStringResource
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Studio.sourceGap) {
            Image(systemName: enabled ? symbol : symbol == "mic" ? "mic.slash" : "speaker.slash")
                .foregroundStyle(enabled ? Theme.Palette.ink2.color : Theme.Palette.ink3.color)
                .frame(width: Theme.Studio.channelIcon, height: Theme.Studio.channelIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.xs) {
                    Text(title).font(Theme.Font.body).foregroundStyle(enabled ? Theme.Palette.ink.color : Theme.Palette.ink3.color)
                    Spacer(minLength: 0)
                    Text(verbatim: enabled ? levels.map { String(format: "%.0f dB", $0.rmsDBFS) } ?? "—" : String(localized: "Off"))
                        .font(Theme.Font.data).foregroundStyle(Theme.Palette.ink2.color)
                        .frame(minWidth: Theme.Studio.decibelWidth, alignment: .trailing)
                    Toggle(isOn: $enabled) { Text(title) }.labelsHidden()
                        .toggleStyle(.switch).controlSize(.mini).tint(Theme.Palette.ink.color).disabled(locked)
                        .help(Text(enabled ? LocalizedStringResource("Mute") : LocalizedStringResource("Unmute")))
                }
                AudioLevelMeter(levels: levels, active: enabled && measures, height: Theme.Studio.meterHeight)
                    .overlay { StudioMeterDivisions().allowsHitTesting(false).accessibilityHidden(true) }
                CamcordSlider(value: roundedGain, range: range)
                    .frame(height: Theme.Studio.gainHeight)
                    .disabled(liveLocked || !enabled)
                    .accessibilityLabel(Text(title)).accessibilityValue(Text(verbatim: String(format: "%+.0f dB", gain)))
                    .help(Text(verbatim: String(format: "%+.0f dB", gain)))
                if enabled && levels == nil {
                    Text(unavailable).font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink3.color).lineLimit(2)
                }
            }
        }
    }
    private var roundedGain: Binding<Double> {
        Binding(get: { gain }, set: { gain = min(range.upperBound, max(range.lowerBound, $0.rounded())) })
    }
}

private struct StudioCameraSection: View {
    let session: StudioSession
    @ObservedObject private var monitor: CameraPreviewMonitor
    let cameras: [AVCaptureDevice]
    let locked: Bool
    let liveLocked: Bool
    @State private var showsPlacement = false
    init(session: StudioSession, cameras: [AVCaptureDevice], locked: Bool, liveLocked: Bool) {
        self.session = session; self.cameras = cameras; self.locked = locked; self.liveLocked = liveLocked
        self.monitor = session.cameraMonitor
    }
    private var formats: [CameraFormatDescriptor] {
        let device: AVCaptureDevice?
        if let id = session.settings.camera.deviceID { device = cameras.first { $0.uniqueID == id } }
        else { device = cameras.first { $0.uniqueID == AVCaptureDevice.default(for: .video)?.uniqueID } }
        return device?.formats.map(CameraFormatDescriptor.init) ?? []
    }
    private var formatOptions: [StudioOption<CameraFormatChoice>] {
        let auto = CameraFormatSelection.auto(formats).map { "Auto (\($0.label))" } ?? CameraFormatSelection.label(.auto)
        var options = [StudioOption(value: CameraFormatChoice.auto, title: auto)]
        options += CameraFormatSelection.manualOptions(formats).map { StudioOption(value: $0, title: CameraFormatSelection.label($0)) }
        let selected = session.settings.camera.format
        if !options.contains(where: { $0.value == selected }) {
            options.append(.init(value: selected, title: String(localized: "Selected device unavailable")))
        }
        return options
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Studio.sourceGap) {
            StudioSectionHeading(title: "Camera")
            HStack {
                Text("Show camera tile").font(Theme.Font.body).foregroundStyle(Theme.Palette.ink2.color)
                Spacer(minLength: 0)
                Toggle("Show camera tile", isOn: cameraSetting(\.enabled)).labelsHidden()
                    .toggleStyle(.switch).controlSize(.mini).tint(Theme.Palette.ink.color).disabled(locked)
            }
            StudioPopupRow(title: "Camera", selection: cameraSetting(\.deviceID),
                           options: deviceOptions(cameras, selected: session.settings.camera.deviceID, mediaType: .video)).disabled(locked)
            StudioPopupRow(title: "Format", selection: cameraSetting(\.format), options: formatOptions).disabled(locked)
            if session.settings.camera.enabled, let message = monitor.message {
                Text(verbatim: message).font(Theme.Font.caption).foregroundStyle(Theme.Palette.warn.color)
            } else if session.settings.camera.enabled && !session.cameraPreviewRequested {
                Text("Camera permission or input is unavailable.").font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink3.color)
            }
            DisclosureGroup("Placement", isExpanded: $showsPlacement) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Toggle("Mirror camera", isOn: cameraSetting(\.mirrored)).toggleStyle(.checkbox)
                    StudioPopupRow(title: "Position", selection: cameraCorner, options: [
                        .init(value: .topLeft, title: String(localized: "Top left")), .init(value: .topRight, title: String(localized: "Top right")),
                        .init(value: .bottomLeft, title: String(localized: "Bottom left")), .init(value: .bottomRight, title: String(localized: "Bottom right"))])
                    StudioPercentageSlider(title: "Size", value: cameraSetting(\.widthFraction), range: CameraOptions.widthRange)
                    StudioPercentageSlider(title: "Horizontal position", value: cameraPosition(\.x), range: 0...1)
                    StudioPercentageSlider(title: "Vertical position", value: cameraPosition(\.y), range: 0...1)
                    Text("Drag the camera on the stage to place it. Position and size are shared with the recording.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink3.color)
                }.padding(.top, Theme.Space.s).disabled(liveLocked)
            }.font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink2.color)
        }
    }
    private var cameraCorner: Binding<CameraCorner> {
        Binding(get: { session.settings.camera.corner }, set: { value in session.updateSettings { $0.camera.corner = value; $0.camera.position = nil } })
    }
    private func cameraSetting<Value>(_ key: WritableKeyPath<CameraOptions, Value>) -> Binding<Value> {
        Binding(get: { session.settings.camera[keyPath: key] }, set: { value in session.updateSettings { $0.camera[keyPath: key] = value } })
    }
    private func cameraPosition(_ key: WritableKeyPath<CameraPosition, Double>) -> Binding<Double> {
        Binding(get: { (session.settings.camera.position ?? CameraPosition(corner: session.settings.camera.corner))[keyPath: key] }, set: { value in
            session.updateSettings { settings in
                var position = settings.camera.position ?? CameraPosition(corner: settings.camera.corner)
                position[keyPath: key] = value; settings.camera.position = position.resolved()
            }
        })
    }
}

private struct StudioPercentageSlider: View {
    let title: LocalizedStringResource
    @Binding var value: Double
    let range: ClosedRange<Double>
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack { Text(title); Spacer(); Text(verbatim: "\(Int(value * 100))%").font(Theme.Font.dataSmall) }
            CamcordSlider(value: Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, ($0 * 100).rounded() / 100)) }), range: range)
                .frame(height: Theme.Studio.gainHeight).accessibilityLabel(Text(title))
        }
    }
}

private struct StudioFormatSection: View {
    let session: StudioSession
    let locked: Bool
    @State private var advanced = false
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Studio.sourceGap) {
            StudioSectionHeading(title: "Format")
            StudioPopupRow(title: "Canvas", selection: setting(\.canvasAspect),
                           options: CanvasAspect.allCases.map { .init(value: $0, title: $0.title) })
            StudioSegmentRow(title: "Frame rate", selection: setting(\.fps), options: frameRates,
                             primary: [30, 60])
            StudioSegmentRow(title: "Resolution", selection: setting(\.resolutionScale), options: [
                .init(value: .oneX, title: "1×"), .init(value: .native, title: String(localized: "Native"))],
                             primary: [.oneX, .native])
            StudioSegmentRow(title: "Codec", selection: codec, options: codecOptions,
                             primary: [.h264, .hevc])
            StudioPopupRow(title: "Countdown", selection: countdown, options: StudioSession.countdownChoices.map {
                .init(value: $0, title: $0 == 0 ? String(localized: "None") : "\($0) s") })
            StudioPopupRow(title: "Time limit", selection: setting(\.maxDurationMinutes), options: timeLimits)
            DisclosureGroup("Advanced", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: Theme.Studio.sourceGap) {
                    StudioPopupRow(title: "Frame rate", selection: setting(\.fps), options: frameRates)
                    StudioPopupRow(title: "Codec", selection: codec, options: codecOptions)
                    StudioPopupRow(title: "Quality", selection: setting(\.profile), options: [
                        .init(value: .efficient, title: String(localized: "Efficient")), .init(value: .balanced, title: String(localized: "Balanced")),
                        .init(value: .highQuality, title: String(localized: "High quality")), .init(value: .maximum, title: String(localized: "Maximum")),
                        .init(value: .proRes, title: String(localized: "ProRes master")), .init(value: .custom, title: String(localized: "Custom"))])
                    StudioPopupRow(title: "Container", selection: setting(\.container), options: [
                        .init(value: .mp4, title: "MP4"), .init(value: .mov, title: "MOV")]).disabled(session.settings.resolvedCodec.isProRes)
                    StudioPopupRow(title: "Dynamic range", selection: setting(\.dynamicRange), options: [
                        .init(value: .sdr, title: "SDR"), .init(value: .hdr, title: "HDR")])
                    if session.settings.profile == .custom && !session.settings.resolvedCodec.isProRes {
                        Stepper(value: setting(\.bitrateMbps), in: 0...200) { Text(verbatim: "\(session.settings.bitrateMbps) Mbps") }
                    }
                    Stepper(value: setting(\.maxDurationMinutes), in: 0...240) { Text(verbatim: "\(session.settings.maxDurationMinutes) min") }
                    Toggle("Show pointer", isOn: setting(\.showsCursor)).toggleStyle(.checkbox)
                    if session.settings.dynamicRange == .hdr && session.settings.resolvedCodec == .h264 {
                        Text("HDR needs HEVC or ProRes; H.264 records SDR.").font(Theme.Font.caption).foregroundStyle(Theme.Palette.warn.color)
                    }
                }.padding(.top, Theme.Space.s)
            }.font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink2.color)
        }.disabled(locked)
    }
    private var frameRates: [StudioOption<Int>] {
        Array(Set([24, 30, 60, 120, session.settings.fps])).sorted().map { .init(value: $0, title: "\($0) fps") }
    }
    private var codecOptions: [StudioOption<VideoCodecChoice>] {
        VideoCodecChoice.allCases.map {
            .init(value: $0, title: $0 == .h264 ? "H.264" : $0 == .hevc ? "HEVC" : RecordingSettingsPage.codecTitle($0))
        }
    }
    private var codec: Binding<VideoCodecChoice> {
        Binding(get: { session.settings.resolvedCodec }, set: { value in session.updateSettings { $0.codec = value; $0.profile = .custom } })
    }
    private var countdown: Binding<Int> { Binding(get: { session.countdownSeconds }, set: { session.countdownSeconds = $0 }) }
    private var timeLimits: [StudioOption<Int>] {
        Array(Set([0, 5, 10, 30, 60, session.settings.maxDurationMinutes])).sorted().map {
            .init(value: $0, title: $0 == 0 ? String(localized: "None") : "\($0) min") }
    }
    private func setting<Value>(_ key: WritableKeyPath<RecordingSettings, Value>) -> Binding<Value> {
        Binding(get: { session.settings[keyPath: key] }, set: { value in session.updateSettings { $0[keyPath: key] = value } })
    }
}

private struct StudioOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

private struct StudioPopupRow<Value: Hashable>: View {
    let title: LocalizedStringResource
    @Binding var selection: Value
    let options: [StudioOption<Value>]
    var body: some View {
        HStack(spacing: Theme.Studio.sourceGap) {
            Text(title).font(Theme.Font.body).foregroundStyle(Theme.Palette.ink2.color)
            Spacer(minLength: 0)
            Menu {
                ForEach(options) { option in
                    Button { selection = option.value } label: {
                        if selection == option.value { Label { Text(verbatim: option.title) } icon: { Image(systemName: "checkmark") } }
                        else { Text(verbatim: option.title) }
                    }
                }
            } label: {
                Text(verbatim: selectedTitle).lineLimit(1)
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible)
            .font(Theme.Font.data).foregroundStyle(Theme.Palette.ink.color)
            .padding(.horizontal, Theme.Space.s).frame(height: Theme.Studio.popupHeight)
            .background(Theme.Palette.raised.color, in: .rect(cornerRadius: Theme.Radius.key))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(Text(title)).accessibilityValue(Text(verbatim: selectedTitle))
            .help(Text(verbatim: selectedTitle))
        }
    }
    private var selectedTitle: String { options.first(where: { $0.value == selection })?.title ?? "—" }
}

private struct StudioSegmentRow<Value: Hashable>: View {
    let title: LocalizedStringResource
    @Binding var selection: Value
    let options: [StudioOption<Value>]
    let primary: [Value]
    private var visibleOptions: [StudioOption<Value>] {
        options.filter { primary.contains($0.value) || $0.value == selection }
    }
    var body: some View {
        HStack(spacing: Theme.Studio.sourceGap) {
            Text(title).font(Theme.Font.body).foregroundStyle(Theme.Palette.ink2.color)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ForEach(visibleOptions) { option in
                    Button { selection = option.value } label: {
                        Text(verbatim: option.title).font(Theme.Font.body).lineLimit(1)
                            .foregroundStyle(selection == option.value ? Theme.Palette.ink.color : Theme.Palette.ink2.color)
                            .padding(.horizontal, Theme.Space.s)
                            .frame(height: Theme.Studio.popupHeight - Theme.Space.xs)
                            .background {
                                if selection == option.value {
                                    RoundedRectangle(cornerRadius: Theme.Radius.key).fill(Theme.Palette.raised.color)
                                }
                            }
                    }
                    .buttonStyle(.plain).help(Text(verbatim: option.title))
                    .accessibilityAddTraits(selection == option.value ? [.isSelected] : [])
                }
            }
            .padding(Theme.Space.xs / 2)
            .overlay { RoundedRectangle(cornerRadius: Theme.Radius.key).strokeBorder(Theme.Palette.hairlineStrong.color, lineWidth: 0.5) }
            .accessibilityElement(children: .contain).accessibilityLabel(Text(title))
        }
    }
}

/// Visual divisions over the existing native meter; measurements and animation remain its own.
private struct StudioMeterDivisions: View {
    var body: some View {
        Canvas { context, size in
            let pitch = Theme.Studio.meterSegmentWidth + Theme.Studio.meterSegmentGap
            for x in stride(from: Theme.Studio.meterSegmentWidth, to: size.width, by: pitch) {
                context.fill(Path(CGRect(x: x, y: 0, width: Theme.Studio.meterSegmentGap, height: size.height)),
                             with: .color(Theme.Palette.surface.color))
            }
        }
    }
}

@MainActor private func deviceOptions(_ devices: [AVCaptureDevice], selected: String?, mediaType: AVMediaType) -> [StudioOption<String?>] {
    let defaultName = AVCaptureDevice.default(for: mediaType).flatMap { device in devices.first { $0.uniqueID == device.uniqueID } }?.localizedName
    var options = [StudioOption<String?>(value: nil, title: defaultName ?? String(localized: "System default"))]
    options += devices.map { .init(value: $0.uniqueID, title: $0.localizedName) }
    if let selected, !devices.contains(where: { $0.uniqueID == selected }) {
        options.append(.init(value: selected, title: String(localized: "Selected device unavailable")))
    }
    return options
}
