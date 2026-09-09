import AVFoundation
import AppKit
import KeyboardShortcuts
import SwiftUI

/// The big Settings window: a sidebar-navigated, real-Mac-app surface for everything
/// that doesn't belong in the one-click panel. A manual `NSWindow` + `NSHostingView`
/// (fact 8: `Settings` scene / `MenuBarExtra` are broken on Tahoe for agent apps).
/// One instance is owned by `AppDelegate`; `show()` lazily creates the window and
/// rebuilds its SwiftUI content each time so state is never stale.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let eventTapEngine: EventTapEngine
    private let defaultsSuite: UserDefaults
    private var window: NSWindow?

    init(eventTapEngine: EventTapEngine, defaultsSuite: UserDefaults = .standard) {
        self.eventTapEngine = eventTapEngine
        self.defaultsSuite = defaultsSuite
        super.init()
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.contentView = NSHostingView(
            rootView: SettingsRootView(eventTapEngine: eventTapEngine, defaultsSuite: defaultsSuite)
        )
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Camcord Ayarları"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 800, height: 640))
        window.minSize = NSSize(width: 720, height: 520)
        window.center()
        return window
    }

    /// The window isn't released on close (reused on next show), so its hosted SwiftUI
    /// tree would otherwise stay alive and keep its `.task` permission-poll loops
    /// spinning forever. Tearing the content view down cancels them; `show()` rebuilds it.
    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
    }
}

// MARK: - Root (sidebar + detail)

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case screenshot
    case recording
    case input
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Genel"
        case .screenshot: "Ekran Görüntüsü"
        case .recording: "Kayıt"
        case .input: "Fare & Kısayollar"
        case .permissions: "İzinler"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .screenshot: "camera"
        case .recording: "record.circle"
        case .input: "cursorarrow.rays"
        case .permissions: "lock.shield"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Camcord günlük akışına uyum sağlasın."
        case .screenshot: "Anı yakala. Hemen kopyala, istersen sakla."
        case .recording: "Görüntü, kamera ve sesin aynı yerde."
        case .input: "Fareyle veya klavyeyle, bir hareket uzağında."
        case .permissions: "Çekim için gereken macOS erişimleri."
        }
    }
}

struct SettingsRootView: View {
    let eventTapEngine: EventTapEngine
    let defaultsSuite: UserDefaults

    @State private var selection: SettingsSection = .general
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(eventTapEngine: EventTapEngine, defaultsSuite: UserDefaults, selection: SettingsSection = .general) {
        self.eventTapEngine = eventTapEngine
        self.defaultsSuite = defaultsSuite
        _selection = State(initialValue: selection)
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 9) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(CamcordStyle.accent)
                    Text("Camcord")
                        .font(.system(size: 17, weight: .semibold))
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)

                List(SettingsSection.allCases, selection: $selection) { section in
                    Label {
                        Text(section.title).font(.system(size: 13, weight: .medium))
                    } icon: {
                        Image(systemName: section.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(section == selection ? Color.primary : CamcordStyle.accent)
                            .frame(width: 22)
                    }
                    .padding(.vertical, 5)
                    .tag(section)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .background(CamcordMaterial(material: .sidebar))
            .navigationSplitViewColumnWidth(min: 196, ideal: 210, max: 240)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selection.title)
                        .font(.system(size: 25, weight: .semibold))
                    Text(selection.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)

                detail
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(selection)
                    .transition(.opacity)
            }
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.88))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selection)
        }
        .tint(CamcordStyle.accent)
        .frame(minWidth: 720, minHeight: 520)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            GeneralSettingsView(defaultsSuite: defaultsSuite)
        case .screenshot:
            ScreenshotSettingsView(defaultsSuite: defaultsSuite)
        case .recording:
            RecordingSettingsView(defaultsSuite: defaultsSuite)
        case .input:
            InputSettingsView(eventTapEngine: eventTapEngine, defaultsSuite: defaultsSuite)
        case .permissions:
            PermissionsSettingsView(defaultsSuite: defaultsSuite)
        }
    }
}

/// Native asynchronous sheets keep capture shortcuts and recording controls responsive.
@MainActor
private enum SettingsFolderPicker {
    private static let errorToast = HUDToast()

    static func choose(path: String, completion: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Seç"
        panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        let finished: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finished)
        } else {
            panel.begin(completionHandler: finished)
        }
    }

    static func reveal(path: String) {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        Task {
            guard await CaptureLibrary.prepareDirectory(directory), NSWorkspace.shared.open(directory) else {
                errorToast.show(text: "Klasör açılamadı — Ayarlar’dan konumu kontrol et",
                                systemSymbol: "folder.badge.questionmark", tint: .systemOrange,
                                respectsSetting: false, duration: 3)
                return
            }
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    let defaultsSuite: UserDefaults

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var soundEnabled: Bool
    @State private var toastEnabled: Bool

    init(defaultsSuite: UserDefaults) {
        self.defaultsSuite = defaultsSuite
        _soundEnabled = State(initialValue: FeedbackSound.isEnabled(in: defaultsSuite))
        _toastEnabled = State(initialValue: HUDToast.isEnabled(in: defaultsSuite))
    }

    var body: some View {
        Form {
            Section("Başlangıç") {
                Toggle("Bilgisayar açılışında başlat", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        guard newValue != LoginItem.isEnabled else { return }
                        LoginItem.setEnabled(newValue)
                        launchAtLogin = LoginItem.isEnabled
                    }
            }
            Section("Geri Bildirim") {
                Toggle("Geri bildirim seslerini çal", isOn: $soundEnabled)
                    .onChange(of: soundEnabled) { _, newValue in
                        FeedbackSound.setEnabled(newValue, in: defaultsSuite)
                    }
                Text("Her işlem için ayrı bir ses çalar (bölge, pencere, OCR, kayıt, yapıştır…).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("Kopyalandı bildirimini göster", isOn: $toastEnabled)
                    .onChange(of: toastEnabled) { _, newValue in
                        HUDToast.setEnabled(newValue, in: defaultsSuite)
                    }
                Text("Görüntü veya metin kopyalandığında kısa bir onay gösterir.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Screenshot

struct ScreenshotSettingsView: View {
    let defaultsSuite: UserDefaults

    @State private var settings: ScreenshotSettings

    init(defaultsSuite: UserDefaults) {
        self.defaultsSuite = defaultsSuite
        _settings = State(initialValue: ScreenshotSettings.load(from: defaultsSuite))
    }

    private var savePath: String {
        settings.saveDirectoryPath ?? ScreenshotSettings.defaultDirectoryPath()
    }

    var body: some View {
        Form {
            Section("Çözünürlük") {
                Picker("Çözünürlük", selection: $settings.resolutionScale) {
                    Text("Retina (tam çözünürlük)").tag(ResolutionScale.native)
                    Text("Standart (1x)").tag(ResolutionScale.oneX)
                }
                Text("Ekran görüntüleri PNG olarak kayıpsız kopyalanır; Retina en keskindir.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Diske Kaydetme") {
                Toggle("Ekran görüntülerini diske de kaydet", isOn: $settings.saveToDisk)
                // The folder row (incl. reveal-in-Finder) stays visible regardless of the
                // toggle — hiding it with saveToDisk is the recurring "disappearing button".
                LabeledContent("Klasör") {
                    HStack(spacing: 8) {
                        Text(savePath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Değiştir…") { chooseFolder() }
                        Button {
                            SettingsFolderPicker.reveal(path: savePath)
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .help("Finder'da göster")
                    }
                }
                if settings.saveToDisk {
                    Text("Panodakinin yanı sıra buraya da kaydedilir; videolardan ayrı bir klasör.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings) { oldValue, newValue in
            newValue.merging(from: oldValue, into: ScreenshotSettings.load(from: defaultsSuite)).save(to: defaultsSuite)
        }
    }

    private func chooseFolder() {
        SettingsFolderPicker.choose(path: savePath) { url in
            // Persist directly as well as updating the current view: a sheet may finish
            // after this view is removed, and its result must not depend on @State lifetime.
            var persisted = ScreenshotSettings.load(from: defaultsSuite)
            persisted.saveDirectoryPath = url.path
            persisted.save(to: defaultsSuite)
            settings.saveDirectoryPath = url.path
        }
    }
}

// MARK: - Recording

struct RecordingSettingsView: View {
    let defaultsSuite: UserDefaults

    @State private var settings: RecordingSettings
    @State private var recents: [RecordingItem] = []
    @State private var audioInputs: [AVCaptureDevice] = []
    @State private var cameraInputs: [AVCaptureDevice] = []
    @ObservedObject private var cameraMonitor = CameraPreviewMonitor.shared
    @ObservedObject private var microphoneMonitor = MicrophoneMonitor.shared

    init(defaultsSuite: UserDefaults) {
        self.defaultsSuite = defaultsSuite
        _settings = State(initialValue: RecordingSettings.load(from: defaultsSuite))
    }

    private var outputPath: String {
        settings.outputDirectoryPath ?? RecordingSettings.defaultDirectoryPath()
    }

    /// Bridges the Int `bitrateMbps` to the Slider's Double value.
    private var bitrateBinding: Binding<Double> {
        Binding(
            get: { Double(settings.bitrateMbps) },
            set: { settings.bitrateMbps = Int($0.rounded()) }
        )
    }

    private static func profileDescription(_ profile: RecordingProfile) -> String {
        switch profile {
        case .efficient: "HEVC · ~8 Mbps — küçük dosya, iyi kalite (arşiv/paylaşım)."
        case .balanced: "HEVC 10-bit · ~20 Mbps — verimli ve yüksek kalite (varsayılan)."
        case .highQuality: "HEVC 10-bit · ~45 Mbps — yükleme / YouTube kalitesi."
        case .maximum: "HEVC 10-bit · ~90 Mbps — en yüksek bitrate teslim."
        case .proRes: "ProRes 422 HQ · neredeyse kayıpsız — düzenleme master'ı (büyük)."
        case .custom: ""
        }
    }

    var body: some View {
        Form {
            Section("Kalite") {
                Picker("Profil", selection: $settings.profile) {
                    Text("En Optimize · küçük").tag(RecordingProfile.efficient)
                    Text("Dengeli").tag(RecordingProfile.balanced)
                    Text("Yüksek Kalite").tag(RecordingProfile.highQuality)
                    Text("En Kaliteli").tag(RecordingProfile.maximum)
                    Text("ProRes · Master").tag(RecordingProfile.proRes)
                    Text("Özel (gelişmiş)").tag(RecordingProfile.custom)
                }

                if settings.profile == .custom {
                    Picker("Codec", selection: $settings.codec) {
                        Text("H.264 · uyumlu (8-bit)").tag(VideoCodecChoice.h264)
                        Text("HEVC · verimli (10-bit)").tag(VideoCodecChoice.hevc)
                        Text("ProRes 422 Proxy").tag(VideoCodecChoice.proResProxy)
                        Text("ProRes 422 LT").tag(VideoCodecChoice.proResLT)
                        Text("ProRes 422").tag(VideoCodecChoice.proRes422)
                        Text("ProRes 422 HQ").tag(VideoCodecChoice.proResHQ)
                        Text("ProRes 4444 · maksimum").tag(VideoCodecChoice.proRes4444)
                    }
                    if !settings.codec.isProRes {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Bit hızı")
                                Spacer()
                                Text(settings.bitrateMbps == 0 ? "Otomatik" : "\(settings.bitrateMbps) Mbps")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: bitrateBinding, in: 0...200, step: 5)
                        }
                    }
                } else {
                    Text(Self.profileDescription(settings.profile))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Picker("Kapsayıcı", selection: $settings.container) {
                    Text("MP4 · en uyumlu").tag(VideoContainer.mp4)
                    Text("MOV · Apple").tag(VideoContainer.mov)
                }
                .disabled(settings.resolvedCodec.isProRes)

                Picker("Kare hızı", selection: $settings.fps) {
                    Text("24 fps · sinematik").tag(24)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                    Text("120 fps").tag(120)
                }
                Picker("Çözünürlük", selection: $settings.resolutionScale) {
                    Text("Retina (tam)").tag(ResolutionScale.native)
                    Text("Standart (1x)").tag(ResolutionScale.oneX)
                }
                Picker("Dinamik Aralık", selection: $settings.dynamicRange) {
                    Text("SDR (Standart) · uyumlu").tag(DynamicRange.sdr)
                    Text("HDR (Geniş Renk) · 10-bit").tag(DynamicRange.hdr)
                }
                .disabled(settings.resolvedCodec == .h264)
                if settings.dynamicRange == .hdr && settings.resolvedCodec == .h264 {
                    Text("H.264 codec ile HDR kayıt kullanılamaz. HDR için HEVC veya ProRes seçin.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Toggle("İmleci kaydet", isOn: $settings.showsCursor)
                Toggle("Tam ekran kaydında geri sayım (3-2-1)", isOn: $settings.countdownEnabled)
            }

            Section("Ses") {
                if microphoneMonitor.recordingLocked {
                    Label("Kayıt sürüyor. Ses seviyelerini canlı değiştirebilirsin.", systemImage: "waveform")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Sistem sesini kaydet", isOn: $settings.systemAudio)
                    .disabled(microphoneMonitor.recordingLocked)
                if settings.systemAudio {
                    HStack {
                        Text("Oyun / sistem seviyesi")
                        Slider(value: $settings.systemAudioGainDB, in: -60...12, step: 1)
                            .accessibilityLabel("Sistem sesi kazancı")
                        Text(String(format: "%+.0f dB", settings.systemAudioGainDB))
                            .monospacedDigit().frame(width: 58, alignment: .trailing)
                    }
                }
                Toggle("Mikrofonu kaydet", isOn: $settings.microphone)
                    .disabled(microphoneMonitor.recordingLocked)
                if settings.microphone {
                    Picker("Mikrofon", selection: $settings.microphoneDeviceID) {
                        Text("Varsayılan giriş").tag(String?.none)
                        ForEach(audioInputs, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(String?.some(device.uniqueID))
                        }
                    }
                    .disabled(microphoneMonitor.recordingLocked)
                    HStack {
                        Text("Mikrofon seviyesi")
                        Slider(value: $settings.microphoneGainDB, in: -24...24, step: 1)
                            .accessibilityLabel("Mikrofon kazancı")
                        Text(String(format: "%+.0f dB", settings.microphoneGainDB))
                            .monospacedDigit().frame(width: 58, alignment: .trailing)
                    }
                }
                if settings.microphone {
                    HStack(spacing: 12) {
                        Button(microphoneMonitor.isRunning ? "Testi durdur" : "Mikrofonu test et") {
                            Task {
                                if microphoneMonitor.isRunning || microphoneMonitor.isStarting {
                                    await microphoneMonitor.stop()
                                } else {
                                    await microphoneMonitor.start(deviceID: settings.microphoneDeviceID, gainDB: settings.resolvedMicrophoneGainDB)
                                }
                            }
                        }
                        .disabled(microphoneMonitor.recordingLocked || microphoneMonitor.isStarting)
                        if microphoneMonitor.isRunning {
                            AudioLevelMeter(levels: microphoneMonitor.levels)
                                .frame(minWidth: 80, maxWidth: 170)
                            Text("Konuşarak seviyeyi kontrol et")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if microphoneMonitor.isStarting {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let message = microphoneMonitor.message {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                }
                Text("Sesin oyunun altında kalıyorsa sistem seviyesini azalt veya mikrofonu yükselt.")
                    .font(.footnote).foregroundStyle(.secondary)
                if settings.systemAudio && settings.microphone {
                    Toggle("Sistem sesi + mikrofonu tek parçada birleştir", isOn: $settings.mixAudioTracks)
                        .disabled(microphoneMonitor.recordingLocked)
                    Text(settings.mixAudioTracks
                        ? "Tek ses parçası — mikrofon her oynatıcıda/platformda duyulur (varsayılan)."
                        : "İki ayrı ses parçası yazılır (düzenleme için ideal), ama çoğu oynatıcı yalnızca ilkini (sistem sesi) çalar; mikrofon duyulmayabilir.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Kamera") {
                Toggle("Kamerayı kaydet", isOn: $settings.camera.enabled)
                    .disabled(cameraMonitor.recordingLocked)
                if settings.camera.enabled {
                    Picker("Kamera", selection: $settings.camera.deviceID) {
                        Text("Varsayılan kamera").tag(String?.none)
                        ForEach(cameraInputs, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(String?.some(device.uniqueID))
                        }
                    }
                    .disabled(cameraMonitor.recordingLocked)
                    HStack {
                        Picker("Konum", selection: $settings.camera.corner) {
                            Text("Sol üst").tag(CameraCorner.topLeft)
                            Text("Sağ üst").tag(CameraCorner.topRight)
                            Text("Sol alt").tag(CameraCorner.bottomLeft)
                            Text("Sağ alt").tag(CameraCorner.bottomRight)
                        }
                        Toggle("Aynala", isOn: $settings.camera.mirrored)
                    }
                    .disabled(cameraMonitor.recordingLocked)
                    HStack {
                        Text("Boyut")
                        Slider(value: $settings.camera.widthFraction, in: CameraOptions.widthRange, step: 0.01)
                            .accessibilityLabel("Kamera görüntüsünün genişliği")
                        Text("%\(Int(settings.camera.widthFraction * 100))").monospacedDigit()
                    }
                    .disabled(cameraMonitor.recordingLocked)
                    CameraPreviewView(options: settings.camera)
                    Text("Konum ve boyut tüm hedeflerde aynı oranda kullanılır; küçük pencerede %35 olan kamera ekran kaydında da %35 olur. 16:9 kamera, 4:3 hedefte daha büyük görünür.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Gösterge") {
                Toggle("Pencere kaydında önce yerleştir", isOn: $settings.armBeforeWindowRecording)
                Toggle("Pencere kaydında pencereyi vurgula", isOn: $settings.windowGlowEnabled)
                Text("Kaydedilen pencerenin çevresinde ince bir parıltı gösterilir (pencereyi taşırsan takip eder, kayda girmez).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Güvenlik") {
                Picker("Otomatik durdurma", selection: $settings.maxDurationMinutes) {
                    Text("Sınırsız").tag(0)
                    Text("5 dakika").tag(5)
                    Text("15 dakika").tag(15)
                    Text("30 dakika").tag(30)
                    Text("60 dakika").tag(60)
                }
                Toggle("Disk dolmadan önce durdur ve dosyayı koru", isOn: $settings.stopWhenDiskLow)
                Text("Kayıt, boş alan ~500 MB'ın altına inince güvenle sonlandırılır — yazıcı çöküp kaydı kaybetmez.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Bildirimler (Rahatsız Etme)") {
                Toggle("Kayıt sırasında Focus/Rahatsız Etme'yi çalıştır", isOn: $settings.dndEnabled)
                if settings.dndEnabled {
                    TextField("Açma kısayolu adı", text: $settings.dndShortcutOn)
                    TextField("Kapatma kısayolu adı", text: $settings.dndShortcutOff)
                    Text("Kısayollar uygulamasında 'Odak Ayarla' ile açma ve kapatma kısayolları oluşturup adlarını buraya yaz. Camcord bunları kayıt başlarken ve biterken çalıştırır. Boş bırakılanlar atlanır.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Dosyalar") {
                LabeledContent("Kayıt klasörü") {
                    HStack(spacing: 8) {
                        Text(outputPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Değiştir…") { chooseFolder() }
                        Button {
                            SettingsFolderPicker.reveal(path: outputPath)
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .help("Finder'da göster")
                    }
                }
                TextField("Dosya adı ön eki", text: $settings.filenamePrefix)
            }

            Section("Son kayıtlar") {
                if recents.isEmpty {
                    Text("Henüz kayıt yok.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recents) { item in
                        RecentRecordingRow(item: item)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings) { oldValue, newValue in
            newValue.merging(from: oldValue, into: RecordingSettings.load(from: defaultsSuite)).save(to: defaultsSuite)
            if newValue.camera != oldValue.camera, defaultsSuite === UserDefaults.standard {
                CameraOverlayController.shared.applyPlacement(newValue.camera, source: .settings)
            }
        }
        .task(id: settings.outputDirectoryPath) { await loadRecents() }
        .onDisappear { Task { await microphoneMonitor.stop() } }
        .onChange(of: settings.microphoneDeviceID) { _, _ in Task { await microphoneMonitor.stop() } }
        .onChange(of: settings.microphone) { _, enabled in
            if !enabled { Task { await microphoneMonitor.stop() } }
        }
        .onChange(of: settings.camera.corner) { _, _ in settings.camera.position = nil }
        .onChange(of: settings.microphoneGainDB) { _, gain in microphoneMonitor.updateGain(gain) }
        .onAppear {
            cameraInputs = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                mediaType: .video, position: .unspecified
            ).devices
            audioInputs = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            ).devices
        }
    }

    private func chooseFolder() {
        SettingsFolderPicker.choose(path: outputPath) { url in
            var persisted = RecordingSettings.load(from: defaultsSuite)
            persisted.outputDirectoryPath = url.path
            persisted.save(to: defaultsSuite)
            settings.outputDirectoryPath = url.path
        }
    }

    private func loadRecents() async {
        let path = outputPath
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        let loaded = await RecordingItem.recent(in: dir, limit: 6)
        // The folder may have changed (or the view gone) while thumbnails generated —
        // don't let a stale directory's results clobber the current one.
        guard !Task.isCancelled, path == outputPath else { return }
        recents = loaded
    }
}

/// One recent-recording row: thumbnail, name, date, reveal in Finder.
private struct RecentRecordingRow: View {
    let item: RecordingItem

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text(item.dateText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Finder'da göster")
        }
    }
}

/// A recorded file plus a lazily generated poster frame.
struct RecordingItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let date: Date
    var thumbnail: NSImage?

    var dateText: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// The newest recordings in `dir`, with poster-frame thumbnails. Matches every
    /// container the app produces (mp4 default, mov for ProRes) — not just `.mov`.
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static func recent(in dir: URL, limit: Int) async -> [RecordingItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let movies = urls
            .filter { videoExtensions.contains($0.pathExtension.lowercased()) }
            .map { url -> (URL, Date) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)

        var items: [RecordingItem] = []
        for (url, date) in movies {
            let thumb = await thumbnail(for: url)
            items.append(RecordingItem(url: url, name: url.lastPathComponent, date: date, thumbnail: thumb))
        }
        return items
    }

    private static func thumbnail(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 100)
        let time = CMTime(seconds: 0.2, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return NSImage(cgImage: result.image, size: .zero)
    }
}

// MARK: - Mouse & shortcuts

struct InputSettingsView: View {
    let eventTapEngine: EventTapEngine
    let defaultsSuite: UserDefaults

    @State private var bindings: TapBindings
    @State private var isAccessibilityTrusted: Bool

    init(eventTapEngine: EventTapEngine, defaultsSuite: UserDefaults) {
        self.eventTapEngine = eventTapEngine
        self.defaultsSuite = defaultsSuite
        _bindings = State(initialValue: TapBindings.load(from: defaultsSuite))
        _isAccessibilityTrusted = State(initialValue: AccessibilityPermission.isTrusted())
    }

    var body: some View {
        Form {
            Section("Fare") {
                Picker("Orta tık (tekerlek)", selection: $bindings.mouseButton3) {
                    tapOptions(includeHold: false)
                }
                Picker("Fare düğmesi 4", selection: $bindings.mouseButton4) {
                    tapOptions(includeHold: true)
                }
                Picker("Fare düğmesi 5", selection: $bindings.mouseButton5) {
                    tapOptions(includeHold: true)
                }
                Picker("Çift dokunuş Sağ ⌘", selection: $bindings.doubleTapRightCommand) {
                    tapOptions(includeHold: false)
                }
                Text("\"Yakalama değiştirici\": tuşu basılı tut → SOL fareyle sürükle = screenshot, SAĞ fareyle sürükle = OCR; sadece dokun (sürüklemeden) = bölge seçim modu açılır.\n\"Basılı tut → bölge\": tuşu tutup sürükle, bırakınca çeker; önce bir kez dokunup sonra tutarsan OCR.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if bindings.anyEnabled, !isAccessibilityTrusted {
                    accessibilityRow
                }
            }

            Section("Klavye Kısayolları") {
                Text("İstediğin tuş birleşimini kaydet; mevcut atamalarını buradan değiştirebilirsin.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                KeyboardShortcuts.Recorder("Bölge çek", name: .captureRegion)
                KeyboardShortcuts.Recorder("Aktif pencere çek", name: .captureActiveWindow)
                KeyboardShortcuts.Recorder("Tüm ekranı çek", name: .captureFullScreen)
                KeyboardShortcuts.Recorder("Metni çek (OCR)", name: .captureTextRegion)
                KeyboardShortcuts.Recorder("Kaydırmalı çekim", name: .captureScrolling)
                KeyboardShortcuts.Recorder("Kayıt başlat / bitir", name: .toggleRecording)
                KeyboardShortcuts.Recorder("Kaydı duraklat / sürdür", name: .pauseRecording)
            }
        }
        .formStyle(.grouped)
        .onChange(of: bindings) { _, newValue in
            newValue.save(to: defaultsSuite)
            eventTapEngine.apply(newValue)
        }
        .task {
            // Poll for the Accessibility grant while this view is visible and pending.
            while !isAccessibilityTrusted {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                let trusted = AccessibilityPermission.isTrusted()
                if trusted {
                    isAccessibilityTrusted = true
                    eventTapEngine.apply(TapBindings.load(from: defaultsSuite))
                }
            }
        }
    }

    @ViewBuilder
    private func tapOptions(includeHold: Bool) -> some View {
        Text("Kapalı").tag(TapAction?.none)
        Text("Bölge çek").tag(TapAction?.some(.captureRegion))
        if includeHold {
            Text("Yakalama değiştirici (+sol/sağ)").tag(TapAction?.some(.captureModifier))
            Text("Basılı tut → bölge").tag(TapAction?.some(.holdCaptureRegion))
        }
        Text("Yapıştır").tag(TapAction?.some(.paste))
        Text("Kayıt başlat / durdur").tag(TapAction?.some(.toggleRecording))
    }

    @ViewBuilder
    private var accessibilityRow: some View {
        HStack {
            Label("Erişilebilirlik izni gerekli", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Spacer()
            Button("İzni Aç") { AccessibilityPermission.requestAccess() }
        }
    }
}

// MARK: - Permissions

struct PermissionsSettingsView: View {
    let defaultsSuite: UserDefaults

    @State private var screenGranted = CGPreflightScreenCaptureAccess()
    @State private var accessibilityTrusted = AccessibilityPermission.isTrusted()
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Form {
            Section("Ekran Kaydı") {
                permissionRow(
                    granted: screenGranted,
                    grantedText: "İzin verildi",
                    pendingText: "İzin gerekli — ekran görüntüsü ve kayıt için şart",
                    open: { NSWorkspace.shared.open(PermissionRecovery.screenRecordingPaneURL) }
                )
            }
            Section("Erişilebilirlik") {
                permissionRow(
                    granted: accessibilityTrusted,
                    grantedText: "İzin verildi",
                    pendingText: "İzin gerekli — fare düğmesi kısayolları için",
                    open: { AccessibilityPermission.requestAccess() }
                )
            }
            Section("Mikrofon") {
                permissionRow(
                    granted: micStatus == .authorized,
                    grantedText: "İzin verildi",
                    pendingText: micStatus == .notDetermined ? "Mikrofonu ilk açtığında sorulacak" : "İzin gerekli — mikrofonu kaydetmek için",
                    open: {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                        )
                    }
                )
            }
            Section("Kamera") {
                permissionRow(
                    granted: cameraStatus == .authorized,
                    grantedText: "İzin verildi",
                    pendingText: cameraStatus == .notDetermined ? "Kamerayı ilk açtığında sorulacak" : "İzin gerekli — kamerayı kayda eklemek için",
                    open: {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
                        )
                    }
                )
            }
        }
        .formStyle(.grouped)
        .task {
            while true {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                screenGranted = CGPreflightScreenCaptureAccess()
                accessibilityTrusted = AccessibilityPermission.isTrusted()
                micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    @ViewBuilder
    private func permissionRow(granted: Bool, grantedText: String, pendingText: String, open: @escaping () -> Void) -> some View {
        if granted {
            Label(grantedText, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            HStack {
                Label(pendingText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Aç") { open() }
            }
        }
    }
}
