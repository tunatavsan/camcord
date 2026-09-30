import AVFoundation
import SwiftUI

struct StudioInspector: View {
    let session: StudioSession
    @ObservedObject var state: RecordingStateModel
    @ObservedObject private var cameraMonitor: CameraPreviewMonitor
    @ObservedObject private var microphoneMonitor: MicrophoneMonitor
    let allowsPreview: Bool
    @State private var cameras: [AVCaptureDevice] = []
    @State private var microphones: [AVCaptureDevice] = []
    @State private var tab = StudioInspectorTab.audio
    init(session: StudioSession, state: RecordingStateModel, allowsPreview: Bool) {
        self.session = session
        self.state = state
        self.allowsPreview = allowsPreview
        self.cameraMonitor = session.cameraMonitor
        self.microphoneMonitor = session.microphoneMonitor
    }
    private var policy: StudioEditingPolicy {
        StudioEditingPolicy(state: state.state, isStarting: state.isStarting, isFinishing: state.isFinishing,
                            isArmed: state.isArmed, controllerBusy: session.isBusy, allowsPreview: allowsPreview)
    }
    private var locked: Bool { policy.bindingsLocked }
    private var liveLocked: Bool { policy.liveEditsLocked }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                Text("Audio").tag(StudioInspectorTab.audio)
                Text("Camera").tag(StudioInspectorTab.camera)
                Text("Layers").tag(StudioInspectorTab.layers)
            }
            .pickerStyle(.segmented).labelsHidden().padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch tab {
                    case .audio: audio
                    case .camera: camera
                    case .layers: StudioLayersInspector(document: session.layers, locked: liveLocked)
                    }
                    Divider()
                    format
                }.padding(.horizontal, 16).padding(.bottom, 20)
            }
        }
        .background(Theme.Palette.surface.color)
        .task(id: allowsPreview) {
            guard allowsPreview else { return }
            refreshDevices()
        }
        .onReceive(StudioDeviceNotifications.publisher()) { _ in if allowsPreview { refreshDevices() } }
    }
    private func refreshDevices() {
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    private var audio: some View {
        VStack(alignment: .leading, spacing: 18) {
            channel(title: "System audio", symbol: "speaker.wave.2", enabled: setting(\.systemAudio), gain: setting(\.systemAudioGainDB), range: -60...12,
                    levels: state.state == .idle ? session.systemAudioLevels : state.health?.systemAudio.levels,
                    testing: session.systemAudioTestRequested,
                    test: { await session.setSystemAudioTestRequested(!session.systemAudioTestRequested) },
                    testDisabled: session.selectedSource == nil)
            Divider()
            channel(title: "Microphone", symbol: "mic", enabled: setting(\.microphone), gain: setting(\.microphoneGainDB), range: -24...24,
                    levels: session.microphoneLevels, testing: session.ownsMicrophoneTest,
                    test: { await session.setMicrophoneTestRequested(!session.ownsMicrophoneTest) }, testDisabled: false)
            if let message = microphoneMonitor.message {
                Text(verbatim: message).font(Theme.Font.caption).foregroundStyle(Theme.Palette.warn.color)
            }
            Picker("Input", selection: setting(\.microphoneDeviceID)) {
                Text("System default").tag(String?.none)
                ForEach(microphones, id: \.uniqueID) { Text(verbatim: $0.localizedName).tag(String?.some($0.uniqueID)) }
                if let id = session.settings.microphoneDeviceID, !microphones.contains(where: { $0.uniqueID == id }) {
                    Text("Selected device unavailable").tag(String?.some(id))
                }
            }.disabled(locked)
            Toggle("Mix into one audio track", isOn: setting(\.mixAudioTracks)).disabled(locked)
            Text("Testing listens only while Studio is visible. Returning here does not restart a test.")
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink3.color)
        }
    }
    private func channel(title: LocalizedStringResource, symbol: String, enabled: Binding<Bool>, gain: Binding<Double>,
                         range: ClosedRange<Double>, levels: AudioLevels?, testing: Bool,
                         test: @escaping @MainActor () async -> Void, testDisabled: Bool) -> some View {
        let status = StudioAudioStatus.resolve(enabled: enabled.wrappedValue, recording: state.state != .idle,
                                               paused: state.state == .paused, ownsTest: testing, levels: levels)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label { Text(title).font(Theme.Font.bodyStrong) } icon: { Image(systemName: symbol) }
                Spacer(minLength: 4)
                Toggle(isOn: enabled) { Text(title) }.labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(locked)
            }
            AudioLevelMeter(levels: levels, active: allowsPreview && status.measures && state.state != .paused, height: 8)
            HStack {
                Text(status.title).font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink2.color)
                Spacer()
                Text(verbatim: levels.map { String(format: "%.0f dBFS", $0.rmsDBFS) } ?? "—")
                    .font(Theme.Font.dataSmall).foregroundStyle(Theme.Palette.ink2.color)
                Button { Task { await test() } } label: { Text(testing ? LocalizedStringResource("Stop test") : LocalizedStringResource("Test")) }
                    .controlSize(.small).disabled(!allowsPreview || locked || testDisabled)
            }
            HStack {
                Text("Gain").font(Theme.Font.caption)
                Slider(value: gain, in: range, step: 1).accessibilityLabel(Text(title)).accessibilityValue(Text("\(Int(gain.wrappedValue)) dB"))
                Text(verbatim: String(format: "%+.0f dB", gain.wrappedValue)).font(Theme.Font.dataSmall).frame(width: 46, alignment: .trailing)
            }.disabled(liveLocked || (!enabled.wrappedValue && !testing))

        }
    }
    private var camera: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Include camera", isOn: cameraSetting(\.enabled)).disabled(locked)
            Picker("Camera", selection: cameraSetting(\.deviceID)) {
                Text("System default").tag(String?.none)
                ForEach(cameras, id: \.uniqueID) { Text(verbatim: $0.localizedName).tag(String?.some($0.uniqueID)) }
                if let id = session.settings.camera.deviceID, !cameras.contains(where: { $0.uniqueID == id }) {
                    Text("Selected device unavailable").tag(String?.some(id))
                }
            }.disabled(locked)
            HStack {
                Text("Check your camera").font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink2.color)
                Spacer()
                Button { Task { await session.setCameraPreviewRequested(!session.cameraPreviewRequested) } } label: {
                    Text(session.cameraPreviewRequested ? LocalizedStringResource("Stop preview") : LocalizedStringResource("Preview"))
                }.disabled(!allowsPreview || locked)
            }
            if let message = cameraMonitor.message {
                Text(verbatim: message).font(Theme.Font.caption).foregroundStyle(Theme.Palette.warn.color)
            }
            if session.cameraPreviewRequested, let image = cameraMonitor.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .scaleEffect(x: session.settings.camera.mirrored ? -1 : 1, y: 1)
                    .frame(maxHeight: 150).clipShape(.rect(cornerRadius: Theme.Radius.control))
                    .accessibilityLabel(Text("Camera preview"))
            }
            Toggle("Mirror camera", isOn: cameraSetting(\.mirrored)).disabled(liveLocked)
            Picker("Placement", selection: Binding(get: { session.settings.camera.corner }, set: { value in
                session.updateSettings { $0.camera.corner = value; $0.camera.position = nil }
            })) {
                Text("Top left").tag(CameraCorner.topLeft)
                Text("Top right").tag(CameraCorner.topRight)
                Text("Bottom left").tag(CameraCorner.bottomLeft)
                Text("Bottom right").tag(CameraCorner.bottomRight)
            }.disabled(liveLocked)
            labeledSlider("Size", value: cameraSetting(\.widthFraction), range: CameraOptions.widthRange, disabled: liveLocked)
            labeledSlider("Horizontal position", value: cameraPosition(\.x), range: 0...1, disabled: liveLocked)
            labeledSlider("Vertical position", value: cameraPosition(\.y), range: 0...1, disabled: liveLocked)
            Text("Drag the camera on the stage to place it. Position and size are shared with the recording.")
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink3.color)
        }
    }
    private var format: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recording setup").font(Theme.Font.bodyStrong)
            Picker("Countdown", selection: Binding(get: { session.countdownSeconds }, set: { session.countdownSeconds = $0 })) {
                Text("None").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5); Text("10 seconds").tag(10)
            }
            Picker("Quality", selection: setting(\.profile)) {
                Text("Efficient").tag(RecordingProfile.efficient); Text("Balanced").tag(RecordingProfile.balanced)
                Text("High quality").tag(RecordingProfile.highQuality); Text("Maximum").tag(RecordingProfile.maximum)
                Text("ProRes master").tag(RecordingProfile.proRes); Text("Custom").tag(RecordingProfile.custom)
            }
            Picker("Frame rate", selection: setting(\.fps)) {
                ForEach([24, 30, 60, 120], id: \.self) { Text(verbatim: "\($0) fps").tag($0) }
            }
            Picker("Resolution", selection: setting(\.resolutionScale)) {
                Text("Native pixels").tag(ResolutionScale.native); Text("Logical pixels (1×)").tag(ResolutionScale.oneX)
            }
            Picker("Window canvas", selection: setting(\.canvasAspect)) {
                ForEach(CanvasAspect.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            Picker("Container", selection: Binding(get: { session.settings.effectiveContainer }, set: { value in session.updateSettings { $0.container = value } })) {
                Text(verbatim: "MP4").tag(VideoContainer.mp4); Text(verbatim: "MOV").tag(VideoContainer.mov)
            }.disabled(session.settings.resolvedCodec.isProRes)
            if session.settings.profile == .custom {
                Picker("Codec", selection: setting(\.codec)) {
                    ForEach(VideoCodecChoice.allCases, id: \.self) { Text(verbatim: RecordingSettingsPage.codecTitle($0)).tag($0) }
                }
                if !session.settings.resolvedCodec.isProRes {
                    Stepper(value: setting(\.bitrateMbps), in: 0...200) { Text("Bitrate: \(session.settings.bitrateMbps) Mbps") }
                }
            }
            Picker("Dynamic range", selection: setting(\.dynamicRange)) {
                Text(verbatim: "SDR").tag(DynamicRange.sdr); Text(verbatim: "HDR").tag(DynamicRange.hdr)
            }
            if session.settings.dynamicRange == .hdr, session.settings.resolvedCodec == .h264 {
                Text("HDR needs HEVC or ProRes; H.264 records SDR.").font(Theme.Font.caption).foregroundStyle(Theme.Palette.warn.color)
            }
            Toggle("Show pointer", isOn: setting(\.showsCursor))
            Stepper(value: setting(\.maxDurationMinutes), in: 0...240) {
                if session.settings.maxDurationMinutes == 0 { Text("No time limit") }
                else { Text("Stop after \(session.settings.maxDurationMinutes) minutes") }
            }
        }.disabled(locked).font(Theme.Font.body)
    }
    private func setting<Value>(_ key: WritableKeyPath<RecordingSettings, Value>) -> Binding<Value> {
        Binding(get: { session.settings[keyPath: key] }, set: { value in session.updateSettings { $0[keyPath: key] = value } })
    }
    private func cameraSetting<Value>(_ key: WritableKeyPath<CameraOptions, Value>) -> Binding<Value> {
        Binding(get: { session.settings.camera[keyPath: key] }, set: { value in session.updateSettings { $0.camera[keyPath: key] = value } })
    }
    private func cameraPosition(_ key: WritableKeyPath<CameraPosition, Double>) -> Binding<Double> {
        Binding(get: { (session.settings.camera.position ?? CameraPosition(corner: session.settings.camera.corner))[keyPath: key] }, set: { value in
            session.updateSettings { settings in
                var position = settings.camera.position ?? CameraPosition(corner: settings.camera.corner)
                position[keyPath: key] = value
                settings.camera.position = position.resolved()
            }
        })
    }
    private func labeledSlider(_ title: LocalizedStringResource, value: Binding<Double>, range: ClosedRange<Double>, disabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(title); Spacer(); Text(verbatim: "\(Int(value.wrappedValue * 100))%").font(Theme.Font.dataSmall) }
            Slider(value: value, in: range, step: 0.01).accessibilityLabel(Text(title))
        }.font(Theme.Font.caption).disabled(disabled)
    }
}
private enum StudioInspectorTab: Hashable { case audio, camera, layers }
