import AVFoundation
import SwiftUI

/// The page's metadata subscription and explicit microphone rehearsal have one lifetime.
@MainActor @Observable
final class SettingsRecordingResources {
    let inputs: SettingsDeviceInventory
    private let monitor: MicrophoneMonitor
    private(set) var owner = UUID()
    private(set) var isActive = false
    @ObservationIgnored private var request: Task<Void, Never>?

    init(inputs: SettingsDeviceInventory = SettingsDeviceInventory(kind: .microphone),
         monitor: MicrophoneMonitor = .shared) {
        self.inputs = inputs
        self.monitor = monitor
    }

    @discardableResult
    func updateActivity(_ active: Bool) -> Task<Void, Never>? {
        guard active != isActive else { return nil }
        isActive = active
        if active { inputs.start(); return nil }
        inputs.stop()
        return stopTest()
    }

    @discardableResult
    func startTest(deviceID: String?, gainDB: Double) -> Task<Void, Never>? {
        guard isActive else { return nil }
        if request != nil { stopTest() }
        let token = owner
        let task = Task {
            guard isActive, owner == token, !Task.isCancelled else { return }
            await monitor.start(owner: token, deviceID: deviceID, gainDB: gainDB)
            if !isActive || owner != token || Task.isCancelled { await monitor.release(owner: token) }
        }
        request = task
        return task
    }

    @discardableResult
    func stopTest() -> Task<Void, Never> {
        request?.cancel()
        request = nil
        let retiringOwner = owner
        owner = UUID()
        return Task { await monitor.release(owner: retiringOwner) }
    }

    isolated deinit {
        request?.cancel()
        inputs.stop()
        let retiringOwner = owner
        let monitor = monitor
        Task { await monitor.release(owner: retiringOwner) }
    }
}

// MARK: - Recording

struct RecordingSettingsPage: View {
    @Bindable var store: SettingsStore
    @ObservedObject private var microphoneMonitor = MicrophoneMonitor.shared
    private var activity = SettingsActivity()
    @State private var resources = SettingsRecordingResources()
    private var inputs: SettingsDeviceInventory { resources.inputs }
    private var microphoneOwner: UUID { resources.owner }
    private var ownsMicrophoneTest: Bool { microphoneMonitor.owns(microphoneOwner) }
    private var microphoneTestRunning: Bool { ownsMicrophoneTest && microphoneMonitor.isRunning }

    private var settings: RecordingSettings { store.recording }
    private var locked: Bool { microphoneMonitor.recordingLocked }
    private var folder: String { settings.outputDirectoryPath ?? RecordingSettings.defaultDirectoryPath() }

    init(store: SettingsStore) { self.store = store }

    var body: some View {
        FormPage(title: SettingsGroup.recording.title) {
            quality
            audio
            FormCard(title: LocalizedStringResource("Indicator", comment: "Settings card"),
                     footnote: LocalizedStringResource("A thin glow follows the window you record and never appears in the file. The red frame you see after picking a window always shows.",
                                                       comment: "Setting footnote")) {
                FormRow(label: LocalizedStringResource("Highlight the window in window recordings", comment: "Setting"), isFirst: true) {
                    Toggle(isOn: $store.recording.windowGlowEnabled) {
                        Text("Highlight the window in window recordings", comment: "Setting")
                    }.inkSwitch()
                }
                .settingsKey("recordingSettings.windowGlowEnabled")
            }
            safety
            focus
            files
        }
        .onChange(of: activity.isActive, initial: true) { _, active in resources.updateActivity(active) }
        .onDisappear { resources.updateActivity(false) }
        .onChange(of: settings.microphoneDeviceID) { _, _ in stopOwnedTest() }
        .onChange(of: settings.microphone) { _, on in if !on { stopOwnedTest() } }
        .onChange(of: inputs.snapshot) { _, _ in
            if inputs.missing(settings.microphoneDeviceID) { stopOwnedTest() }
        }
        .onChange(of: settings.microphoneGainDB) { _, gain in
            if activity.isActive { microphoneMonitor.updateGain(gain, owner: microphoneOwner) }
        }
    }

    private func stopOwnedTest() {
        resources.stopTest()
    }

    // MARK: Quality

    private var quality: some View {
        FormCard(title: LocalizedStringResource("Quality", comment: "Settings card"),
                 footnote: settings.profile == .custom ? nil : Self.profileNote(settings.profile)) {
            FormRow(label: LocalizedStringResource("Profile", comment: "Setting: recording quality profile"), isFirst: true) {
                Picker(selection: $store.recording.profile) {
                    ForEach(RecordingProfile.allCases, id: \.self) { Text(Self.profileTitle($0)).tag($0) }
                } label: { Text("Profile", comment: "Setting: recording quality profile") }
                .labelsHidden().fixedSize()
            }
            .settingsKey("recordingSettings.profile")
            if settings.profile == .custom {
                FormRow(label: LocalizedStringResource("Codec", comment: "Setting: video codec")) {
                    Picker(selection: $store.recording.codec) {
                        ForEach(VideoCodecChoice.allCases, id: \.self) { Text(verbatim: Self.codecTitle($0)).tag($0) }
                    } label: { Text("Codec", comment: "Setting: video codec") }
                    .labelsHidden().fixedSize()
                }
                .settingsKey("recordingSettings.codec")
                if !settings.codec.isProRes {
                    FormRow(label: LocalizedStringResource("Bit rate", comment: "Setting: video bit rate")) {
                        ValueSlider(value: Binding(get: { Double(store.recording.bitrateMbps) },
                                                   set: { store.recording.bitrateMbps = Int($0) }),
                                    range: 0...200, step: 5, format: Self.bitrate,
                                    label: LocalizedStringResource("Bit rate", comment: "Setting: video bit rate"))
                    }
                    .settingsKey("recordingSettings.bitrateMbps")
                }
            }
            FormRow(label: LocalizedStringResource("Container", comment: "Setting: file container")) {
                Picker(selection: $store.recording.container) {
                    Text("MP4 · most compatible", comment: "Container option").tag(VideoContainer.mp4)
                    Text("MOV · Apple", comment: "Container option").tag(VideoContainer.mov)
                } label: { Text("Container", comment: "Setting: file container") }
                .labelsHidden().fixedSize()
                .disabled(settings.resolvedCodec.isProRes)
            }
            .settingsKey("recordingSettings.container")
            FormRow(label: LocalizedStringResource("Frame rate", comment: "Setting: frames per second")) {
                Picker(selection: $store.recording.fps) {
                    Text("24 fps · cinematic", comment: "Frame rate option").tag(24)
                    ForEach([30, 60, 120], id: \.self) { Text(verbatim: "\($0) fps").tag($0) }
                } label: { Text("Frame rate", comment: "Setting: frames per second") }
                .labelsHidden().fixedSize()
            }
            .settingsKey("recordingSettings.fps")
            FormRow(label: LocalizedStringResource("Resolution", comment: "Setting: capture resolution")) {
                ResolutionPicker(selection: $store.recording.resolutionScale)
            }
            .settingsKey("recordingSettings.resolutionScale")
            FormRow(label: LocalizedStringResource("Record games at 1080p", comment: "Setting"),
                    note: LocalizedStringResource("A full-screen game records at half resolution; frame rate and codec stay the same.",
                                                  comment: "Setting note")) {
                Toggle(isOn: $store.recording.gameModeScale) { Text("Record games at 1080p", comment: "Setting") }.inkSwitch()
            }
            .settingsKey("recordingSettings.gameModeScale")
            FormRow(label: LocalizedStringResource("Canvas", comment: "Setting: the recorded file's shape"),
                    note: LocalizedStringResource("Window recordings: the file keeps this shape; a resized window is centred on a blurred backdrop.",
                                                  comment: "Setting note")) {
                Picker(selection: $store.recording.canvasAspect) {
                    ForEach(CanvasAspect.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: { Text("Canvas", comment: "Setting: the recorded file's shape") }
                .labelsHidden().fixedSize()
            }
            .settingsKey("recordingSettings.canvasAspect")
            FormRow(label: LocalizedStringResource("Dynamic range", comment: "Setting: SDR or HDR"),
                    note: settings.dynamicRange == .hdr && settings.resolvedCodec == .h264
                        ? LocalizedStringResource("HDR needs HEVC or ProRes; H.264 records SDR.", comment: "Setting warning")
                        : nil) {
                Picker(selection: $store.recording.dynamicRange) {
                    Text("SDR · compatible", comment: "Dynamic range option").tag(DynamicRange.sdr)
                    Text("HDR · 10-bit", comment: "Dynamic range option").tag(DynamicRange.hdr)
                } label: { Text("Dynamic range", comment: "Setting: SDR or HDR") }
                .labelsHidden().fixedSize()
                .disabled(settings.resolvedCodec == .h264)
            }
            .settingsKey("recordingSettings.dynamicRange")
            FormRow(label: LocalizedStringResource("Record the pointer", comment: "Setting")) {
                Toggle(isOn: $store.recording.showsCursor) { Text("Record the pointer", comment: "Setting") }.inkSwitch()
            }
            .settingsKey("recordingSettings.showsCursor")
            FormRow(label: LocalizedStringResource("Count down before full-screen recordings", comment: "Setting: 3-2-1")) {
                Toggle(isOn: $store.recording.countdownEnabled) {
                    Text("Count down before full-screen recordings", comment: "Setting: 3-2-1")
                }.inkSwitch()
            }
            .settingsKey("recordingSettings.countdownEnabled")
        }
    }

    // MARK: Audio

    private var audio: some View {
        FormCard(title: LocalizedStringResource("Audio", comment: "Settings card"),
                 footnote: LocalizedStringResource("If your voice is buried under the game, lower the system level or raise the microphone.",
                                                   comment: "Setting footnote")) {
            if locked {
                FormRow(label: LocalizedStringResource("A recording is running. Levels change live.", comment: "Setting status"), isFirst: true) {
                    Image(systemName: "waveform").foregroundStyle(Theme.Palette.record.color)
                }
            }
            FormRow(label: LocalizedStringResource("Record system audio", comment: "Setting"), isFirst: !locked) {
                Toggle(isOn: $store.recording.systemAudio) { Text("Record system audio", comment: "Setting") }
                    .inkSwitch().disabled(locked)
            }
            .settingsKey("recordingSettings.systemAudio")
            if settings.systemAudio {
                FormRow(label: LocalizedStringResource("System level", comment: "Setting: system audio gain")) {
                    ValueSlider(value: $store.recording.systemAudioGainDB, range: -60...12, format: Self.decibels,
                                label: LocalizedStringResource("System level", comment: "Setting: system audio gain"))
                }
                .settingsKey("recordingSettings.systemAudioGainDB")
            }
            FormRow(label: LocalizedStringResource("Record the microphone", comment: "Setting")) {
                Toggle(isOn: $store.recording.microphone) { Text("Record the microphone", comment: "Setting") }
                    .inkSwitch().disabled(locked)
            }
            .settingsKey("recordingSettings.microphone")
            if settings.microphone {
                FormRow(label: LocalizedStringResource("Microphone", comment: "Permission name"),
                        note: inputs.missing(settings.microphoneDeviceID)
                            ? LocalizedStringResource("The selected microphone is disconnected. Recordings use the default input until it returns.",
                                                      comment: "Unavailable microphone warning") : nil) {
                    Picker(selection: $store.recording.microphoneDeviceID) {
                        Text("Default input", comment: "Microphone option: the system default").tag(String?.none)
                        ForEach(inputs.snapshot.devices) { Text(verbatim: $0.name).tag(String?.some($0.id)) }
                        if inputs.missing(settings.microphoneDeviceID), let id = settings.microphoneDeviceID {
                            Text("Disconnected microphone", comment: "Unavailable microphone option").tag(String?.some(id))
                        }
                    } label: { Text("Microphone", comment: "Permission name") }
                    .labelsHidden().fixedSize().disabled(locked)
                }
                .settingsKey("recordingSettings.microphoneDeviceID")
                FormRow(label: LocalizedStringResource("Microphone level", comment: "Setting: microphone gain")) {
                    ValueSlider(value: $store.recording.microphoneGainDB, range: -24...24, format: Self.decibels,
                                label: LocalizedStringResource("Microphone level", comment: "Setting: microphone gain"))
                }
                .settingsKey("recordingSettings.microphoneGainDB")
                FormRow(label: LocalizedStringResource("Test the microphone", comment: "Setting"),
                        note: (ownsMicrophoneTest ? microphoneMonitor.message : nil).map { _ in
                            LocalizedStringResource("The microphone test failed. Check permission and the selected input.", comment: "Microphone test recovery")
                        }
                            ?? (microphoneTestRunning ? LocalizedStringResource("Speak to check the level", comment: "Mic test running") : nil)) {
                    HStack(spacing: Theme.Space.m) {
                        if microphoneTestRunning {
                            AudioLevelMeter(levels: microphoneMonitor.levels).frame(width: 120)
                        }
                        Button {
                            guard activity.isActive else { return }
                            if ownsMicrophoneTest {
                                stopOwnedTest()
                            } else {
                                resources.startTest(deviceID: settings.microphoneDeviceID, gainDB: settings.microphoneGainDB)
                            }
                        } label: {
                            ownsMicrophoneTest
                                ? Text("Stop test", comment: "Button: stop the microphone test")
                                : Text("Test", comment: "Button: start the microphone test")
                        }
                        .disabled(locked)
                    }
                }
            }
            if settings.systemAudio, settings.microphone {
                FormRow(label: LocalizedStringResource("Mix system audio and microphone into one track", comment: "Setting"),
                        note: settings.mixAudioTracks
                            ? LocalizedStringResource("One track: the microphone is heard in every player (default).", comment: "Setting note")
                            : LocalizedStringResource("Two tracks, ideal for editing, but most players play only the first (system audio).",
                                                      comment: "Setting note")) {
                    Toggle(isOn: $store.recording.mixAudioTracks) {
                        Text("Mix system audio and microphone into one track", comment: "Setting")
                    }.inkSwitch().disabled(locked)
                }
                .settingsKey("recordingSettings.mixAudioTracks")
            }
        }
    }

    // MARK: Safety, focus, files

    private var safety: some View {
        FormCard(title: LocalizedStringResource("Safety", comment: "Settings card")) {
            FormRow(label: LocalizedStringResource("Stop automatically", comment: "Setting: a time limit"), isFirst: true) {
                Picker(selection: $store.recording.maxDurationMinutes) {
                    Text("No limit", comment: "Time limit option").tag(0)
                    ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) min", comment: "A number of minutes").tag($0) }
                } label: { Text("Stop automatically", comment: "Setting: a time limit") }
                .labelsHidden().fixedSize()
            }
            .settingsKey("recordingSettings.maxDurationMinutes")
            FormRow(label: LocalizedStringResource("Stop before the disk fills and keep the file", comment: "Setting"),
                    note: LocalizedStringResource("The recording ends safely when free space drops under about 500 MB.", comment: "Setting note")) {
                Toggle(isOn: $store.recording.stopWhenDiskLow) {
                    Text("Stop before the disk fills and keep the file", comment: "Setting")
                }.inkSwitch()
            }
            .settingsKey("recordingSettings.stopWhenDiskLow")
        }
    }

    private var focus: some View {
        FormCard(title: LocalizedStringResource("Focus", comment: "Settings card: Do Not Disturb"),
                 footnote: settings.dndEnabled
                    ? LocalizedStringResource("Make an on and an off shortcut with “Set Focus” in the Shortcuts app and type their names here. Camcord runs them when a recording starts and ends; empty ones are skipped.",
                                              comment: "Setting footnote")
                    : nil) {
            FormRow(label: LocalizedStringResource("Turn on Focus while recording", comment: "Setting"), isFirst: true) {
                Toggle(isOn: $store.recording.dndEnabled) { Text("Turn on Focus while recording", comment: "Setting") }.inkSwitch()
            }
            .settingsKey("recordingSettings.dndEnabled")
            if settings.dndEnabled {
                FormRow(label: LocalizedStringResource("Shortcut that turns it on", comment: "Setting: a Shortcuts app name")) {
                    TextField(text: $store.recording.dndShortcutOn) { Text("Shortcut name", comment: "Placeholder") }
                        .frame(width: 200)
                }
                .settingsKey("recordingSettings.dndShortcutOn")
                FormRow(label: LocalizedStringResource("Shortcut that turns it off", comment: "Setting: a Shortcuts app name")) {
                    TextField(text: $store.recording.dndShortcutOff) { Text("Shortcut name", comment: "Placeholder") }
                        .frame(width: 200)
                }
                .settingsKey("recordingSettings.dndShortcutOff")
            }
        }
    }

    private var files: some View {
        FormCard(title: LocalizedStringResource("Files", comment: "Settings card"),
                 footnote: LocalizedStringResource("Your recordings are in the Library.", comment: "Setting footnote")) {
            FormRow(label: LocalizedStringResource("Folder", comment: "Setting: a save folder"), isFirst: true) {
                FolderControl(path: folder) { store.recording.outputDirectoryPath = $0.path }
            }
            .settingsKey("recordingSettings.outputDirectoryPath")
            FormRow(label: LocalizedStringResource("File name prefix", comment: "Setting")) {
                TextField(text: $store.recording.filenamePrefix) { Text(verbatim: "camcord") }
                    .frame(width: 200)
            }
            .settingsKey("recordingSettings.filenamePrefix")
        }
    }

    // MARK: Words

    static func profileTitle(_ profile: RecordingProfile) -> LocalizedStringResource {
        switch profile {
        case .efficient: LocalizedStringResource("Efficient · small", comment: "Recording profile")
        case .balanced: LocalizedStringResource("Balanced", comment: "Recording profile")
        case .highQuality: LocalizedStringResource("High quality", comment: "Recording profile")
        case .maximum: LocalizedStringResource("Best", comment: "Recording profile")
        case .proRes: LocalizedStringResource("ProRes · master", comment: "Recording profile")
        case .custom: LocalizedStringResource("Custom (advanced)", comment: "Recording profile")
        }
    }

    static func profileNote(_ profile: RecordingProfile) -> LocalizedStringResource {
        switch profile {
        case .efficient: LocalizedStringResource("HEVC · about 8 Mbps: small files, good quality for archives and sharing.", comment: "Profile note")
        case .balanced: LocalizedStringResource("HEVC 10-bit · about 20 Mbps: efficient and high quality (default).", comment: "Profile note")
        case .highQuality: LocalizedStringResource("HEVC 10-bit · about 45 Mbps: upload and YouTube quality.", comment: "Profile note")
        case .maximum: LocalizedStringResource("HEVC 10-bit · about 90 Mbps: the highest bit rate.", comment: "Profile note")
        case .proRes, .custom: LocalizedStringResource("ProRes 422 HQ · almost lossless: an editing master (large).", comment: "Profile note")
        }
    }

    static func codecTitle(_ codec: VideoCodecChoice) -> String {
        switch codec {
        case .h264: "H.264 · 8-bit"
        case .hevc: "HEVC · 10-bit"
        case .proResProxy: "ProRes 422 Proxy"
        case .proResLT: "ProRes 422 LT"
        case .proRes422: "ProRes 422"
        case .proResHQ: "ProRes 422 HQ"
        case .proRes4444: "ProRes 4444"
        }
    }

    static func bitrate(_ value: Double) -> String {
        value < 1 ? String(localized: "Auto", comment: "Camera format setting") : "\(Int(value)) Mbps"
    }

    static func decibels(_ value: Double) -> String {
        let db = Int(value.rounded())
        return db > 0 ? "+\(db) dB" : db < 0 ? "−\(-db) dB" : "0 dB"
    }
}

// MARK: - Camera

struct CameraSettingsPage: View {
    @Bindable var store: SettingsStore
    private var activity = SettingsActivity()
    @ObservedObject private var cameraMonitor = CameraPreviewMonitor.shared
    @State private var inputs = SettingsDeviceInventory(kind: .camera)

    private var formats: [CameraFormatDescriptor] { inputs.formats(for: camera.deviceID) }

    private var camera: CameraOptions { store.recording.camera }
    private var locked: Bool { cameraMonitor.recordingLocked }

    init(store: SettingsStore) { self.store = store }

    var body: some View {
        FormPage(title: SettingsGroup.camera.title) {
            FormCard(footnote: camera.enabled
                        ? LocalizedStringResource("Position and size are proportional on every target: a tile at 35 % in a small window is 35 % of a full-screen recording too. A 16:9 camera looks larger on a 4:3 target.",
                                                  comment: "Setting footnote")
                        : nil) {
                FormRow(label: LocalizedStringResource("Record the camera", comment: "Setting"), isFirst: true) {
                    Toggle(isOn: $store.recording.camera.enabled) { Text("Record the camera", comment: "Setting") }
                        .inkSwitch().disabled(locked)
                }
                .settingsKey("recordingSettings.camera.enabled")
                if camera.enabled {
                    FormRow(label: LocalizedStringResource("Camera", comment: "Chip: the camera tile on or off"),
                            note: inputs.missing(camera.deviceID)
                                ? LocalizedStringResource("The selected camera is disconnected. Reconnect it or choose another camera.",
                                                          comment: "Unavailable camera warning") : nil) {
                        Picker(selection: $store.recording.camera.deviceID) {
                            Text("Default camera", comment: "Camera option: the system default").tag(String?.none)
                            ForEach(inputs.snapshot.devices) { Text(verbatim: $0.name).tag(String?.some($0.id)) }
                            if inputs.missing(camera.deviceID), let id = camera.deviceID {
                                Text("Disconnected camera", comment: "Unavailable camera option").tag(String?.some(id))
                            }
                        } label: { Text("Camera", comment: "Chip: the camera tile on or off") }
                        .labelsHidden().fixedSize().disabled(locked)
                    }
                    .settingsKey("recordingSettings.camera.deviceID")
                    FormRow(label: LocalizedStringResource("Format", comment: "Camera format setting"),
                            note: LocalizedStringResource("Auto picks the smallest 1080p-or-taller format at up to 60 fps.",
                                                          comment: "Camera format setting help")) {
                        Picker(selection: $store.recording.camera.format) {
                            Text(verbatim: autoLabel).tag(CameraFormatChoice.auto)
                            ForEach(CameraFormatSelection.manualOptions(formats), id: \.self) {
                                Text(verbatim: CameraFormatSelection.label($0)).tag($0)
                            }
                            if camera.format != .auto, !CameraFormatSelection.manualOptions(formats).contains(camera.format) {
                                Text("Unavailable: \(CameraFormatSelection.label(camera.format))", comment: "A saved camera format unavailable on this device")
                                    .tag(camera.format)
                            }
                        } label: { Text("Format", comment: "Camera format setting") }
                        .labelsHidden().fixedSize().disabled(locked)
                    }
                    .settingsKey("recordingSettings.camera.formats")
                    FormRow(label: LocalizedStringResource("Position", comment: "Setting: the tile's corner")) {
                        Picker(selection: $store.recording.camera.corner) {
                            Text("Top left", comment: "Corner").tag(CameraCorner.topLeft)
                            Text("Top right", comment: "Corner").tag(CameraCorner.topRight)
                            Text("Bottom left", comment: "Corner").tag(CameraCorner.bottomLeft)
                            Text("Bottom right", comment: "Corner").tag(CameraCorner.bottomRight)
                        } label: { Text("Position", comment: "Setting: the tile's corner") }
                        .labelsHidden().fixedSize().disabled(locked)
                    }
                    .settingsKey("recordingSettings.camera.corner")
                    FormRow(label: LocalizedStringResource("Mirror", comment: "Setting: mirror the camera")) {
                        Toggle(isOn: $store.recording.camera.mirrored) { Text("Mirror", comment: "Setting: mirror the camera") }
                            .inkSwitch().disabled(locked)
                    }
                    .settingsKey("recordingSettings.camera.mirrored")
                    FormRow(label: LocalizedStringResource("Size", comment: "Setting: the tile's width")) {
                        ValueSlider(value: $store.recording.camera.widthFraction, range: CameraOptions.widthRange, step: 0.01,
                                    format: { "\(Int(($0 * 100).rounded())) %" },
                                    label: LocalizedStringResource("Size", comment: "Setting: the tile's width"))
                            .disabled(locked)
                    }
                    .settingsKey("recordingSettings.camera.widthFraction")
                }
            }
            if camera.enabled {
                FormCard(title: LocalizedStringResource("Preview", comment: "Settings card")) {
                    SettingsCameraPreviewView(options: camera)
                        .padding(Theme.Space.l)
                }
            }
        }
        .onChange(of: activity.isActive, initial: true) { _, active in
            if active { inputs.start() } else { inputs.stop() }
        }
        .onDisappear { inputs.stop() }
    }

    /// "Auto (1920 × 1080 @ 30)": what Auto means on this camera.
    private var autoLabel: String {
        let auto = CameraFormatSelection.label(.auto)
        guard let resolved = CameraFormatSelection.auto(formats) else { return auto }
        return "\(auto) (\(resolved.label))"
    }

}
