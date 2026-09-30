import AppKit
import KeyboardShortcuts
import SwiftUI

/// The Settings module's model: the persisted settings structs, loaded from and saved to one
/// defaults suite with the same keys the old Settings window used (K7). A save merges only the
/// fields this page changed into what is on disk, so a change made meanwhile from the menu-bar
/// panel is never overwritten; the store reloads when another surface saves recording settings.
@MainActor @Observable
final class SettingsStore {
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let eventTapEngine: EventTapEngine?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var updatingSnapshot = false
    @ObservationIgnored private let loginItem: LoginItemAccess

    struct LoginItemAccess {
        let read: () -> Bool
        let write: (Bool) -> Void
    }
    private(set) var launchAtLoginIssue = false

    var recording: RecordingSettings {
        didSet {
            guard !updatingSnapshot, recording != oldValue else { return }
            var edited = recording
            // Only a local corner edit resets a drag; external placements are read as-is.
            if edited.camera.corner != oldValue.camera.corner { edited.camera.position = nil }
            let disk = RecordingSettings.load(from: defaults)
            var merged = edited.merging(from: oldValue, into: disk)
            merged.camera = Self.mergeCamera(edited.camera, from: oldValue.camera, into: disk.camera)
            updatingSnapshot = true
            recording = merged
            updatingSnapshot = false
            merged.save(to: defaults)
            if edited.camera != oldValue.camera, defaults === UserDefaults.standard {
                CameraOverlayController.shared.applyPlacement(merged.camera, source: .settings)
            }
        }
    }

    var screenshot: ScreenshotSettings {
        didSet {
            guard !updatingSnapshot, screenshot != oldValue else { return }
            let merged = screenshot.merging(from: oldValue, into: ScreenshotSettings.load(from: defaults))
            updatingSnapshot = true
            screenshot = merged
            updatingSnapshot = false
            merged.save(to: defaults)
        }
    }

    var tapBindings: TapBindings {
        didSet {
            guard !updatingSnapshot, tapBindings != oldValue else { return }
            var merged = TapBindings.load(from: defaults)
            for field in [\TapBindings.mouseButton3, \.mouseButton4, \.mouseButton5, \.doubleTapRightCommand] {
                if tapBindings[keyPath: field] != oldValue[keyPath: field] {
                    merged[keyPath: field] = tapBindings[keyPath: field]
                }
            }
            updatingSnapshot = true
            tapBindings = merged
            updatingSnapshot = false
            merged.save(to: defaults)
            eventTapEngine?.apply(merged)
        }
    }

    var library: LibrarySettings {
        didSet {
            guard !updatingSnapshot, library != oldValue else { return }
            var merged = LibrarySettings.load(from: defaults)
            if library.keepCopied != oldValue.keepCopied { merged.keepCopied = library.keepCopied }
            if library.keepDays != oldValue.keepDays { merged.keepDays = library.keepDays }
            if library.capBytes != oldValue.capBytes { merged.capBytes = library.capBytes }
            updatingSnapshot = true
            library = merged
            updatingSnapshot = false
            merged.save(to: defaults)
        }
    }

    private static func mergeCamera(_ edited: CameraOptions, from old: CameraOptions, into disk: CameraOptions) -> CameraOptions {
        var merged = disk
        if edited.enabled != old.enabled { merged.enabled = edited.enabled }
        if edited.deviceID != old.deviceID { merged.deviceID = edited.deviceID }
        if edited.corner != old.corner { merged.corner = edited.corner; merged.position = nil }
        if edited.widthFraction != old.widthFraction { merged.widthFraction = edited.widthFraction }
        if edited.mirrored != old.mirrored { merged.mirrored = edited.mirrored }
        if edited.position != old.position { merged.position = edited.position }
        for key in Set(edited.formats.keys).union(old.formats.keys) where edited.formats[key] != old.formats[key] {
            merged.formats[key] = edited.formats[key]
        }
        return merged
    }

    var feedbackSounds: Bool {
        didSet { if !updatingSnapshot { FeedbackSound.setEnabled(feedbackSounds, in: defaults) } }
    }

    var copyToast: Bool {
        didSet { if !updatingSnapshot { HUDToast.setEnabled(copyToast, in: defaults) } }
    }

    var dockIconMode: DockIconMode {
        didSet { if !updatingSnapshot { dockIconMode.save(to: defaults) } }
    }

    /// The login item lives in ServiceManagement, not in defaults.
    var launchAtLogin: Bool {
        didSet {
            guard !updatingSnapshot, launchAtLogin != oldValue else { return }
            let requested = launchAtLogin
            loginItem.write(requested)
            let actual = loginItem.read()
            updatingSnapshot = true
            launchAtLogin = actual
            updatingSnapshot = false
            launchAtLoginIssue = actual != requested
        }
    }

    init(defaults: UserDefaults, eventTapEngine: EventTapEngine?, loginItem: LoginItemAccess? = nil) {
        self.defaults = defaults
        self.loginItem = loginItem ?? (defaults === UserDefaults.standard
            ? LoginItemAccess(read: { LoginItem.isEnabled }, write: { LoginItem.setEnabled($0) })
            : LoginItemAccess(read: { false }, write: { _ in }))
        self.eventTapEngine = eventTapEngine
        recording = RecordingSettings.load(from: defaults)
        screenshot = ScreenshotSettings.load(from: defaults)
        tapBindings = TapBindings.load(from: defaults)
        library = LibrarySettings.load(from: defaults)
        feedbackSounds = FeedbackSound.isEnabled(in: defaults)
        copyToast = HUDToast.isEnabled(in: defaults)
        dockIconMode = DockIconMode.load(from: defaults)
        launchAtLogin = self.loginItem.read()
        observer = NotificationCenter.default.addObserver(
            forName: RecordingSettings.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadRecordingIfChanged() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Another surface saved recording settings: take them, unless they are what we already hold.
    private func reloadRecordingIfChanged() {
        let onDisk = RecordingSettings.load(from: defaults)
        if onDisk != recording {
            updatingSnapshot = true
            recording = onDisk
            updatingSnapshot = false
        }
    }

    /// Re-entering Settings follows changes made while another module was on screen, without
    /// turning a read into persistence or a hardware action.
    func refresh() {
        updatingSnapshot = true
        recording = RecordingSettings.load(from: defaults)
        screenshot = ScreenshotSettings.load(from: defaults)
        tapBindings = TapBindings.load(from: defaults)
        library = LibrarySettings.load(from: defaults)
        feedbackSounds = FeedbackSound.isEnabled(in: defaults)
        copyToast = HUDToast.isEnabled(in: defaults)
        dockIconMode = DockIconMode.load(from: defaults)
        launchAtLogin = loginItem.read()
        launchAtLoginIssue = false
        updatingSnapshot = false
    }

    /// Re-applies the mouse bindings (after Accessibility is granted, the tap can be created).
    func reapplyTapBindings() { eventTapEngine?.apply(tapBindings) }
}

// MARK: - Folder rows

/// Choosing and revealing a folder: an open panel sheeted to the key window, and a reveal that
/// creates the folder first. A failure to reveal always tells the owner, whatever the toast setting.
@MainActor
enum FolderPicker {
    private static let errorToast = HUDToast()

    static func choose(path: String, completion: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose", comment: "Folder panel: confirm the folder")
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
                errorToast.show(text: String(localized: "Couldn't open the folder. Check its location in Settings.",
                                             comment: "Toast when a folder cannot be revealed"),
                                systemSymbol: "folder.badge.questionmark", tint: Theme.Palette.warn.ns,
                                respectsSetting: false, duration: 3)
                return
            }
        }
    }

    /// "~/Movies/Camcord" rather than the full path.
    static func display(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// A folder: its path in SF Mono, Change… and a reveal button.
struct FolderControl: View {
    let path: String
    let choose: @MainActor (URL) -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(verbatim: FolderPicker.display(path))
                .font(Theme.Font.data)
                .foregroundStyle(Theme.Palette.ink2.color)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Text(verbatim: path))
            Button { FolderPicker.choose(path: path, completion: choose) } label: {
                Text("Change…", comment: "Button: choose another folder")
            }
            Button { FolderPicker.reveal(path: path) } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help(Text("Show in Finder", comment: "Button: reveal a folder in Finder"))
            .accessibilityLabel(Text("Show in Finder", comment: "Button: reveal a folder in Finder"))
        }
    }
}

/// A slider row's trailing part: the slider and its value in SF Mono.
struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let format: (Double) -> String
    let label: LocalizedStringResource

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Slider(value: $value, in: range, step: step)
                .frame(width: 180)
                .accessibilityLabel(Text(label))
                .accessibilityValue(Text(verbatim: format(value)))
            Text(verbatim: format(value))
                .font(Theme.Font.data)
                .foregroundStyle(Theme.Palette.ink2.color)
                .frame(minWidth: 64, alignment: .trailing)
        }
    }
}

// MARK: - Parity instrumentation

/// Which persisted settings the pages build a control for. `settingsKey(_:)` runs while a page's
/// body builds its rows, so a row that is not built (a hidden branch) is not counted; the parity
/// test turns every branch on, renders every page and compares (K7).
@MainActor
final class SettingsKeyRecorder {
    /// Set only by the parity test while it renders.
    static var active: SettingsKeyRecorder?
    private(set) var keys = Set<String>()
    private(set) var stores: [SettingsStore] = []
    func recordStore(_ store: SettingsStore) { stores.append(store) }
    func reset() { keys.removeAll(); stores.removeAll() }
    func record(_ key: String) { keys.insert(key) }
}

extension View {
    /// Marks the view as the control for a persisted setting (`"recordingSettings.fps"`,
    /// `"dockIconMode"`, `"KeyboardShortcuts_captureRegion"` …); live checks find it by this id.
    @MainActor func settingsKey(_ key: String) -> some View {
        SettingsKeyRecorder.active?.record(key)
        return accessibilityIdentifier("setting.\(key)")
    }
}
