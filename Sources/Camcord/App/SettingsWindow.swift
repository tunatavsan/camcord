import AppKit
import KeyboardShortcuts
import SwiftUI

/// Fact 8: `Settings` scene / `MenuBarExtra` are broken on Tahoe for agent apps, so the
/// settings window is a manual `NSWindow` + `NSHostingView`. SwiftUI is confined to the
/// window's content (`SettingsView`) -- everything around it is plain AppKit.
///
/// One instance is owned by `AppDelegate` for the app's lifetime; `show()` lazily
/// creates its single `NSWindow` and reuses it on every subsequent call.
@MainActor
final class SettingsWindowController {
    private let eventTapEngine: EventTapEngine
    private let defaultsSuite: UserDefaults
    private var window: NSWindow?

    init(eventTapEngine: EventTapEngine, defaultsSuite: UserDefaults = .standard) {
        self.eventTapEngine = eventTapEngine
        self.defaultsSuite = defaultsSuite
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // Rebuild the SwiftUI content on every show: @State initializes once per
        // view identity, so a reused window would otherwise present stale state
        // (e.g. a green "Erişilebilirlik izni verildi" row after the permission was
        // revoked while the window was closed).
        window.contentView = NSHostingView(
            rootView: SettingsView(eventTapEngine: eventTapEngine, defaultsSuite: defaultsSuite)
        )
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let contentView = SettingsView(eventTapEngine: eventTapEngine, defaultsSuite: defaultsSuite)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Camcord Ayarları"
        window.contentView = NSHostingView(rootView: contentView)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

/// SwiftUI settings content (fact 8: SwiftUI is only used here). Two sections wire
/// Tier 1 (`KeyboardShortcuts.Recorder`) and Tier 2 (`TapBindings`) configuration, plus
/// an Accessibility status row for Tier 2 (fact 7).
struct SettingsView: View {
    let eventTapEngine: EventTapEngine
    let defaultsSuite: UserDefaults

    @State private var bindings: TapBindings
    @State private var recordingSettings: RecordingSettings
    @State private var captureSoundEnabled: Bool
    @State private var isAccessibilityTrusted: Bool
    @State private var trustPollTimer: Timer?

    init(eventTapEngine: EventTapEngine, defaultsSuite: UserDefaults) {
        self.eventTapEngine = eventTapEngine
        self.defaultsSuite = defaultsSuite
        _bindings = State(initialValue: TapBindings.load(from: defaultsSuite))
        _recordingSettings = State(initialValue: RecordingSettings.load(from: defaultsSuite))
        _captureSoundEnabled = State(initialValue: CaptureFeedback.isEnabled(in: defaultsSuite))
        _isAccessibilityTrusted = State(initialValue: AccessibilityPermission.isTrusted())
    }

    var body: some View {
        Form {
            Section("Klavye Kısayolları") {
                KeyboardShortcuts.Recorder("Bölge çek:", name: .captureRegion)
                KeyboardShortcuts.Recorder("Aktif pencere:", name: .captureActiveWindow)
                KeyboardShortcuts.Recorder("Tüm ekran:", name: .captureFullScreen)
                KeyboardShortcuts.Recorder("Son bölgeyi tekrarla:", name: .repeatLastRegion)
                KeyboardShortcuts.Recorder("Kayıt başlat/durdur:", name: .toggleRecording)
                KeyboardShortcuts.Recorder("Kayıt duraklat:", name: .pauseRecording)
            }

            Section("Fare ve Hareketler") {
                Picker("Fare Düğmesi 4:", selection: $bindings.mouseButton4) {
                    tapActionOptions
                }
                Picker("Fare Düğmesi 5:", selection: $bindings.mouseButton5) {
                    tapActionOptions
                }
                Picker("Çift dokunuş Sağ ⌘:", selection: $bindings.doubleTapRightCommand) {
                    tapActionOptions
                }

                accessibilityStatusRow
            }

            Section("Kayıt") {
                Toggle("Sistem sesini kaydet", isOn: $recordingSettings.systemAudio)
                Toggle("Mikrofonu kaydet", isOn: $recordingSettings.microphone)
            }

            Section("Genel") {
                Toggle("Çekim sesi çal", isOn: $captureSoundEnabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
        .onChange(of: bindings) { _, newValue in
            newValue.save(to: defaultsSuite)
            eventTapEngine.apply(newValue)
        }
        .onChange(of: recordingSettings) { _, newValue in
            // Read back at the start of each recording -- no engine restart needed.
            newValue.save(to: defaultsSuite)
        }
        .onChange(of: captureSoundEnabled) { _, newValue in
            CaptureFeedback.setEnabled(newValue, in: defaultsSuite)
        }
        .onAppear {
            startTrustPollingIfNeeded()
        }
        .onDisappear {
            trustPollTimer?.invalidate()
            trustPollTimer = nil
        }
    }

    @ViewBuilder
    private var tapActionOptions: some View {
        Text("Kapalı").tag(TapAction?.none)
        Text("Bölge çek").tag(TapAction?.some(.captureRegion))
        Text("Kayıt başlat-durdur").tag(TapAction?.some(.toggleRecording))
    }

    @ViewBuilder
    private var accessibilityStatusRow: some View {
        if isAccessibilityTrusted {
            Label("Erişilebilirlik izni verildi", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            HStack {
                Label("Erişilebilirlik izni gerekli", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("İzni Aç") {
                    AccessibilityPermission.requestAccess()
                    startTrustPollingIfNeeded()
                }
            }
        }
    }

    /// Fact 7: poll trust every 3s, ONLY while Settings is open and permission is
    /// pending; stop as soon as it's granted (or the window closes, via onDisappear).
    /// The tick cap bounds the timer's lifetime even if onDisappear never fires for
    /// a swapped-out NSHostingView (historically flaky) — no unbounded leaked polls.
    private func startTrustPollingIfNeeded() {
        guard !isAccessibilityTrusted, trustPollTimer == nil else { return }
        let deadline = Date().addingTimeInterval(180)
        let timer = Timer(timeInterval: 3.0, repeats: true) { timer in
            if Date() > deadline {
                timer.invalidate()
                return
            }
            Task { @MainActor in
                let trusted = AccessibilityPermission.isTrusted()
                isAccessibilityTrusted = trusted
                if trusted {
                    eventTapEngine.apply(bindings)
                    trustPollTimer?.invalidate()
                    trustPollTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustPollTimer = timer
    }
}
