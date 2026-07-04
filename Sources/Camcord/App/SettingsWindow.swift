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
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Camcord Ayarları"
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 740, height: 560))
        window.minSize = NSSize(width: 680, height: 480)
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
}

struct SettingsRootView: View {
    let eventTapEngine: EventTapEngine
    let defaultsSuite: UserDefaults

    @State private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(196)
        } detail: {
            ScrollView {
                detail
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .navigationTitle(selection.title)
        }
        .frame(minWidth: 680, minHeight: 480)
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

// MARK: - General

struct GeneralSettingsView: View {
    let defaultsSuite: UserDefaults

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var soundEnabled: Bool

    init(defaultsSuite: UserDefaults) {
        self.defaultsSuite = defaultsSuite
        _soundEnabled = State(initialValue: FeedbackSound.isEnabled(in: defaultsSuite))
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
        }
        .formStyle(.grouped)
        .onChange(of: settings) { _, newValue in newValue.save(to: defaultsSuite) }
    }
}

// MARK: - Recording

struct RecordingSettingsView: View {
    let defaultsSuite: UserDefaults

    @State private var settings: RecordingSettings
    @State private var recents: [RecordingItem] = []
    @State private var audioInputs: [AVCaptureDevice] = []

    private static let bitrateOptions = [0, 10, 20, 40, 80]

    init(defaultsSuite: UserDefaults) {
        self.defaultsSuite = defaultsSuite
        _settings = State(initialValue: RecordingSettings.load(from: defaultsSuite))
    }

    private var outputPath: String {
        settings.outputDirectoryPath ?? RecordingSettings.defaultDirectoryPath()
    }

    var body: some View {
        Form {
            Section("Kalite") {
                Picker("Codec", selection: $settings.codec) {
                    Text("HEVC (küçük, yüksek kalite)").tag(VideoCodecChoice.hevc)
                    Text("H.264 (uyumlu)").tag(VideoCodecChoice.h264)
                    Text("ProRes 422 (en yüksek kalite, büyük)").tag(VideoCodecChoice.proRes422)
                }
                Picker("Kapsayıcı", selection: $settings.container) {
                    Text("MOV").tag(VideoContainer.mov)
                    Text("MP4 (en uyumlu)").tag(VideoContainer.mp4)
                }
                .disabled(settings.codec == .proRes422)
                Picker("Bit hızı", selection: $settings.bitrateMbps) {
                    ForEach(Self.bitrateOptions, id: \.self) { mbps in
                        Text(mbps == 0 ? "Otomatik" : "\(mbps) Mbps").tag(mbps)
                    }
                }
                .disabled(settings.codec == .proRes422)
                Picker("Kare hızı", selection: $settings.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                    Text("120 fps").tag(120)
                }
                Picker("Çözünürlük", selection: $settings.resolutionScale) {
                    Text("Retina (tam)").tag(ResolutionScale.native)
                    Text("Standart (1x)").tag(ResolutionScale.oneX)
                }
                Toggle("İmleci kaydet", isOn: $settings.showsCursor)
            }

            Section("Ses") {
                Toggle("Sistem sesini kaydet", isOn: $settings.systemAudio)
                Toggle("Mikrofonu kaydet", isOn: $settings.microphone)
                if settings.microphone {
                    Picker("Mikrofon", selection: $settings.microphoneDeviceID) {
                        Text("Varsayılan giriş").tag(String?.none)
                        ForEach(audioInputs, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(String?.some(device.uniqueID))
                        }
                    }
                }
            }

            Section("Gösterge") {
                Toggle("Pencere kaydında pencereyi vurgula", isOn: $settings.windowGlowEnabled)
                Text("Kaydedilen pencerenin çevresinde ince bir parıltı gösterilir (kayda girmez).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                            NSWorkspace.shared.open(URL(fileURLWithPath: outputPath, isDirectory: true))
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
        .onChange(of: settings) { _, newValue in newValue.save(to: defaultsSuite) }
        .task(id: settings.outputDirectoryPath) { await loadRecents() }
        .onAppear {
            audioInputs = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            ).devices
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Seç"
        panel.directoryURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
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

    /// The newest `.mov` files in `dir`, with poster-frame thumbnails.
    static func recent(in dir: URL, limit: Int) async -> [RecordingItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let movies = urls
            .filter { $0.pathExtension.lowercased() == "mov" }
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
                Text("\"Basılı tut → bölge\": tuşu basılı tutup sürükle, bırakınca çeker. Önce bir kez dokunup sonra basılı tutarsan aynı bölgeyi OCR ile metne çevirir.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if bindings.anyEnabled, !isAccessibilityTrusted {
                    accessibilityRow
                }
            }

            Section("Klavye Kısayolları") {
                Text("Hiçbiri varsayılan olarak atanmamıştır — istediğini buradan ata.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                KeyboardShortcuts.Recorder("Bölge çek", name: .captureRegion)
                KeyboardShortcuts.Recorder("Aktif pencere çek", name: .captureActiveWindow)
                KeyboardShortcuts.Recorder("Tüm ekranı çek", name: .captureFullScreen)
                KeyboardShortcuts.Recorder("Metni çek (OCR)", name: .captureTextRegion)
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
                    grantedText: micStatus == .notDetermined ? "İlk kayıtta sorulacak" : "İzin verildi",
                    pendingText: "İzin gerekli — mikrofonu kaydetmek için",
                    open: {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
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
