import AVFoundation
import SwiftUI

// The Settings module's pages (K7, SPEC S5): the prototype's page — a display title and cards
// of rows — in place of the old Settings window, with the same keys (settings-parity.md).

/// The Settings module's content: the page of the group the sidebar has selected.
struct SettingsModuleView: View {
    @Environment(\.appServices) private var services
    @Environment(\.mainWindowModel) private var windowModel
    @State private var store: SettingsStore?

    var body: some View {
        Group {
            if let store {
                SettingsPageView(group: windowModel?.settingsGroup ?? .general, store: store)
            } else if services == nil {
                ModulePlaceholder(symbol: "gearshape", title: LocalizedStringResource("Settings", comment: "Main window module"),
                                  message: LocalizedStringResource("Settings are loading.", comment: "Settings placeholder"))
            } else {
                Color.clear
            }
        }
        .onAppear {
            if store == nil, let services {
                store = SettingsStore(defaults: services.defaults, eventTapEngine: services.eventTapEngine)
            } else {
                store?.refresh()
            }
        }
        .onChange(of: services.map(ObjectIdentifier.init)) { _, _ in
            store = services.map { SettingsStore(defaults: $0.defaults, eventTapEngine: $0.eventTapEngine) }
        }
    }
}

struct SettingsPageView: View {
    let group: SettingsGroup
    let store: SettingsStore

    var body: some View {
        let _ = SettingsKeyRecorder.active?.recordStore(store)
        switch group {
        case .general: GeneralSettingsPage(store: store)
        case .screenshot: ScreenshotSettingsPage(store: store)
        case .recording: RecordingSettingsPage(store: store)
        case .camera: CameraSettingsPage(store: store)
        case .input: InputSettingsPage(store: store)
        case .library: LibrarySettingsPage(store: store)
        case .permissions: PermissionsSettingsPage(store: store)
        }
    }
}

// MARK: - General

struct GeneralSettingsPage: View {
    @Bindable var store: SettingsStore

    var body: some View {
        FormPage(title: SettingsGroup.general.title) {
            FormCard(title: LocalizedStringResource("Startup", comment: "Settings card")) {
                FormRow(label: LocalizedStringResource("Open at login", comment: "Setting: launch at login"),
                        note: store.launchAtLoginIssue
                            ? LocalizedStringResource("Couldn't change Open at login. Check Login Items in System Settings.", comment: "Login item recovery") : nil,
                        isFirst: true) {
                    Toggle(isOn: $store.launchAtLogin) { Text("Open at login", comment: "Setting: launch at login") }.inkSwitch()
                }
                .settingsKey("loginItem")
                FormRow(label: LocalizedStringResource("Dock icon", comment: "Setting: when the Dock icon shows")) {
                    Picker(selection: $store.dockIconMode) {
                        ForEach(DockIconMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: { Text("Dock icon", comment: "Setting: when the Dock icon shows") }
                    .labelsHidden()
                    .fixedSize()
                }
                .settingsKey(DockIconMode.defaultsKey)
            }
            FormCard(title: LocalizedStringResource("Feedback", comment: "Settings card")) {
                FormRow(label: LocalizedStringResource("Feedback sounds", comment: "Setting"),
                        note: LocalizedStringResource("A distinct sound for each action: region, window, text, recording, paste.",
                                                      comment: "Setting note"),
                        isFirst: true) {
                    Toggle(isOn: $store.feedbackSounds) { Text("Feedback sounds", comment: "Setting") }.inkSwitch()
                }
                .settingsKey(FeedbackSound.enabledDefaultsKey)
                FormRow(label: LocalizedStringResource("Copied confirmation", comment: "Setting"),
                        note: LocalizedStringResource("A short confirmation when an image or text is copied.", comment: "Setting note")) {
                    Toggle(isOn: $store.copyToast) { Text("Copied confirmation", comment: "Setting") }.inkSwitch()
                }
                .settingsKey(HUDToast.enabledDefaultsKey)
            }
        }
    }
}

// MARK: - Screenshot

struct ScreenshotSettingsPage: View {
    @Bindable var store: SettingsStore

    private var folder: String { store.screenshot.saveDirectoryPath ?? ScreenshotSettings.defaultDirectoryPath() }

    var body: some View {
        FormPage(title: SettingsGroup.screenshot.title) {
            FormCard(footnote: LocalizedStringResource("Screenshots are copied as lossless PNG; Retina is the sharpest.",
                                                       comment: "Setting footnote")) {
                FormRow(label: LocalizedStringResource("Resolution", comment: "Setting: capture resolution"), isFirst: true) {
                    ResolutionPicker(selection: $store.screenshot.resolutionScale)
                }
                .settingsKey("screenshotSettings.resolutionScale")
            }
            FormCard(title: LocalizedStringResource("Saving", comment: "Settings card"),
                     footnote: store.screenshot.saveToDisk
                        ? LocalizedStringResource("Saved here as well as copied, in a folder apart from recordings.", comment: "Setting footnote")
                        : nil) {
                FormRow(label: LocalizedStringResource("Also save to disk", comment: "Setting"), isFirst: true) {
                    Toggle(isOn: $store.screenshot.saveToDisk) { Text("Also save to disk", comment: "Setting") }.inkSwitch()
                }
                .settingsKey("screenshotSettings.saveToDisk")
                // Always shown, saving on or off: a folder row that vanishes reads as a bug.
                FormRow(label: LocalizedStringResource("Folder", comment: "Setting: a save folder")) {
                    FolderControl(path: folder) { store.screenshot.saveDirectoryPath = $0.path }
                }
                .settingsKey("screenshotSettings.saveDirectoryPath")
            }
        }
    }
}

/// Retina (full) / Standard (1×).
struct ResolutionPicker: View {
    @Binding var selection: ResolutionScale

    var body: some View {
        Picker(selection: $selection) {
            Text("Retina (full)", comment: "Resolution option").tag(ResolutionScale.native)
            Text("Standard (1×)", comment: "Resolution option").tag(ResolutionScale.oneX)
        } label: { Text("Resolution", comment: "Setting: capture resolution") }
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - Library (K4)

struct LibrarySettingsPage: View {
    @Bindable var store: SettingsStore
    @State private var confirmingClear = false
    @State private var cacheBytes: Int64?
    @State private var cacheError = false
    @State private var clearing = false

    var body: some View {
        FormPage(title: SettingsGroup.library.title) {
            FormCard(footnote: LocalizedStringResource("Copied captures live in Camcord's own folder; the oldest go first when they pass the limit.",
                                                       comment: "Setting footnote")) {
                FormRow(label: LocalizedStringResource("Keep copied captures in the Library", comment: "Setting"),
                        note: LocalizedStringResource("Screenshots and scroll captures you only copied", comment: "Setting note"),
                        isFirst: true) {
                    Toggle(isOn: $store.library.keepCopied) {
                        Text("Keep copied captures in the Library", comment: "Setting")
                    }.inkSwitch()
                }
                .settingsKey(LibrarySettings.keepCopiedKey)
                FormRow(label: LocalizedStringResource("Keep them for", comment: "Setting: how long copied captures are kept")) {
                    Picker(selection: $store.library.keepDays) {
                        ForEach(LibrarySettings.dayChoices, id: \.self) { days in
                            Text("\(days) days", comment: "A number of days").tag(days)
                        }
                    } label: { Text("Keep them for", comment: "Setting: how long copied captures are kept") }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!store.library.keepCopied)
                }
                .settingsKey(LibrarySettings.keepDaysKey)
                FormRow(label: LocalizedStringResource("Space for copied captures", comment: "Setting: size limit")) {
                    Picker(selection: $store.library.capBytes) {
                        ForEach(LibrarySettings.capChoices, id: \.self) { bytes in
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).tag(bytes)
                        }
                    } label: { Text("Space for copied captures", comment: "Setting: size limit") }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!store.library.keepCopied)
                }
                .settingsKey(LibrarySettings.capBytesKey)
                FormRow(label: LocalizedStringResource("In use", comment: "Setting: space the copied captures take")) {
                    HStack(spacing: Theme.Space.m) {
                        Text(verbatim: cacheBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                            .font(Theme.Font.data)
                            .foregroundStyle(Theme.Palette.ink2.color)
                        Button { confirmingClear = true } label: { Text("Clear…", comment: "Button: remove copied captures") }
                            .disabled(clearing || (cacheBytes ?? 0) == 0)
                    }
                }
            }
        }
        .task { await refreshCacheSize() }
        .alert(Text("Couldn't update copied captures", comment: "Cache error title"), isPresented: $cacheError) {
            Button { Task { await refreshCacheSize() } } label: { Text("Try again", comment: "Button: retry an operation") }
            Button(role: .cancel) { } label: { Text("Cancel", comment: "Button") }
        } message: {
            Text("Some copied captures couldn't be read or moved to the Trash. Check folder access and try again.",
                 comment: "Cache failure recovery")
        }
        .confirmationDialog(Text("Move all copied captures to the Trash?", comment: "Confirm clearing the Library cache"),
                            isPresented: $confirmingClear) {
            Button(role: .destructive) {
                clearing = true
                Task {
                    do { try await LibraryCache.clear() } catch { cacheError = true }
                    await refreshCacheSize()
                    clearing = false
                }
            } label: { Text("Move to Trash", comment: "Button: trash files") }
        } message: {
            Text("Saved files are not touched.", comment: "Confirm clearing the Library cache: what stays")
        }
    }

    private func refreshCacheSize() async {
        do {
            let bytes = try await LibraryCache.usedBytes()
            guard !Task.isCancelled else { return }
            cacheBytes = bytes
        } catch {
            guard !Task.isCancelled else { return }
            cacheBytes = nil
            cacheError = true
        }
    }

}

/// The copied-captures folder (K4): its size and emptying it to the Trash.
enum LibraryCache {
    enum CacheError: Error { case unsafeDirectory, trashFailed(Int) }

    static func usedBytes(directory: URL = LibrarySettings.cacheDirectory()) async throws -> Int64 {
        try await Task.detached(priority: .utility) {
            try ownedFiles(in: directory).reduce(Int64(0)) { total, url in
                total + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
        }.value
    }

    /// Only the app's UUID-named PNG copies can be removed. Recheck immediately before each
    /// Trash operation; unknown children, symlinks and directories are never followed.
    static func clear(directory: URL = LibrarySettings.cacheDirectory(),
                      trash: @escaping @Sendable (URL) throws -> Void = {
                          try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
                      }) async throws {
        try await Task.detached(priority: .utility) {
            var failures = 0
            for url in try ownedFiles(in: directory) {
                try Task.checkCancellation()
                do {
                    try validateDirectory(directory)
                    guard try isOwnedFile(url) else { continue }
                    try trash(url)
                } catch { failures += 1 }
            }
            if failures > 0 { throw CacheError.trashFailed(failures) }
        }.value
    }

    private static func validateDirectory(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw CacheError.unsafeDirectory
        }
    }

    private static func ownedFiles(in directory: URL) throws -> [URL] {
        do {
            try validateDirectory(directory)
            return try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]).filter { try isOwnedFile($0) }
        } catch CocoaError.fileReadNoSuchFile { return [] }
    }

    private static func isOwnedFile(_ url: URL) throws -> Bool {
        guard url.pathExtension.lowercased() == "png",
              UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}

// MARK: - Permissions

struct PermissionsSettingsPage: View {
    let store: SettingsStore
    @State private var screen = CGPreflightScreenCaptureAccess()
    @State private var accessibility = AccessibilityPermission.isTrusted()
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)

    static let cameraPaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!

    var body: some View {
        FormPage(title: SettingsGroup.permissions.title) {
            FormCard(footnote: LocalizedStringResource("macOS keeps these switches in System Settings › Privacy & Security.",
                                                       comment: "Setting footnote")) {
                PermissionStatusRow(title: LocalizedStringResource("Screen Recording", comment: "Permission name"),
                                    missing: LocalizedStringResource("Needed for every screenshot and recording", comment: "Permission missing"),
                                    state: screen ? .granted : .missing, isFirst: true) {
                    NSWorkspace.shared.open(PermissionRecovery.screenRecordingPaneURL)
                }
                PermissionStatusRow(title: LocalizedStringResource("Accessibility", comment: "Permission name"),
                                    missing: LocalizedStringResource("Needed for mouse-button shortcuts and auto-scroll", comment: "Permission missing"),
                                    state: accessibility ? .granted : .missing) {
                    AccessibilityPermission.requestAccess()
                }
                PermissionStatusRow(title: LocalizedStringResource("Microphone", comment: "Permission name"),
                                    missing: LocalizedStringResource("Needed to record your voice", comment: "Permission missing"),
                                    state: .init(microphone)) {
                    NSWorkspace.shared.open(PermissionRecovery.microphonePaneURL)
                }
                PermissionStatusRow(title: LocalizedStringResource("Camera", comment: "Chip: the camera tile on or off"),
                                    missing: LocalizedStringResource("Needed to add the camera to recordings", comment: "Permission missing"),
                                    state: .init(camera)) {
                    NSWorkspace.shared.open(Self.cameraPaneURL)
                }
            }
        }
        .task {
            // The grants change in System Settings, which sends nothing: look again every 2 s
            // while this page is on screen.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                screen = CGPreflightScreenCaptureAccess()
                let trusted = AccessibilityPermission.isTrusted()
                if trusted, !accessibility { store.reapplyTapBindings() }
                accessibility = trusted
                microphone = AVCaptureDevice.authorizationStatus(for: .audio)
                camera = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }
}

enum PermissionState: Equatable {
    case granted, missing, askedLater

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .askedLater
        default: self = .missing
        }
    }
}

struct PermissionStatusRow: View {
    let title: LocalizedStringResource
    let missing: LocalizedStringResource
    let state: PermissionState
    var isFirst = false
    let open: () -> Void

    var body: some View {
        FormRow(label: title, note: state == .missing ? missing : nil, isFirst: isFirst) {
            switch state {
            case .granted:
                Label { Text("Allowed", comment: "A permission that is granted") } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(Theme.Font.bodyStrong)
                .foregroundStyle(Theme.Palette.ok.color)
            case .askedLater:
                Text("When you turn it on", comment: "A permission asked for later, when its feature is first used")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.ink2.color)
            case .missing:
                Button(action: open) { Text("Open System Settings", comment: "Button: open the privacy pane") }
            }
        }
    }
}
