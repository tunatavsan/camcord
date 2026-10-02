import AppKit
import KeyboardShortcuts
import SwiftUI
import Testing

@testable import Camcord

/// K7 of docs/RUN-UI-2.md: every setting the old Settings window wrote has a control in the
/// Settings module, under the same key. The required keys are enumerated from the settings
/// structs themselves (so a new field without a control fails here), and the controls are the
/// rows the module's pages actually draw (each reports its key while it renders).
@MainActor
@Suite("Settings parity", .serialized)
struct SettingsParityTests {
    private static let suiteName = "camcord.settings.parity.test"

    @Test("value sliders retain native callbacks, lower-origin steps and untouched stored values")
    func nativeValueSlider() throws {
        let cases: [(range: ClosedRange<Double>, step: Double, stored: Double, input: Double, expected: Double)] = [
            (0...200, 5, 12.6, 12.6, 15),
            (-60...12, 1, -7.6, -7.6, -8),
            (0.08...0.60, 0.01, 0.197, 0.197, 0.20),
            (0.13...0.43, 0.05, 0.204, 0.204, 0.18),
            (0.13...0.43, 0.05, 0.2, -10, 0.13),
            (0.13...0.43, 0.05, 0.2, 10, 0.43)
        ]
        for test in cases {
            var value = test.stored
            let binding = Binding(get: { value }, set: { value = $0 })
            let host = NSHostingView(rootView: ValueSlider(value: binding, range: test.range, step: test.step,
                format: { "Value \($0)" }, label: "Bit rate"))
            host.frame = CGRect(x: 0, y: 0, width: 280, height: 44)
            host.layoutSubtreeIfNeeded()
            let slider = try #require(Self.nativeSliders(in: host).first)
            #expect(value == test.stored, "rendering must not rewrite an existing non-lattice value")
            #expect(slider.isEnabled && slider.isContinuous)
            #expect(slider.numberOfTickMarks == 0 && !slider.allowsTickMarkValuesOnly)
            #expect(slider.accessibilityRole() == .slider)
            #expect(slider.accessibilityLabel() == "Bit rate")
            #expect(slider.accessibilityValueDescription() == "Value \(test.stored)")
            let target = try #require(slider.target as? NSObject)
            let action = try #require(slider.action)
            slider.doubleValue = test.input
            _ = target.perform(action, with: slider)
            #expect(abs(value - test.expected) < 0.000_001)
        }
        var disabledValue = 0.197
        let disabled = NSHostingView(rootView: ValueSlider(
            value: Binding(get: { disabledValue }, set: { disabledValue = $0 }), range: 0.08...0.60, step: 0.01,
            format: { "\(Int(($0 * 100).rounded())) %" }, label: "Size").disabled(true))
        disabled.frame = CGRect(x: 0, y: 0, width: 280, height: 44)
        disabled.layoutSubtreeIfNeeded()
        let slider = try #require(Self.nativeSliders(in: disabled).first)
        #expect(!slider.isEnabled)
        #expect(slider.accessibilityLabel() == "Size")
        #expect(slider.accessibilityValueDescription() == "20 %")
        #expect(disabledValue == 0.197)
    }

    @Test("slider labels resolve once until their resource or effective locale changes")
    func sliderLabelLocalizationReuse() {
        _ = NSApplication.shared
        var resolved: [LocalizedStringResource] = []
        let english = Locale(identifier: "en")
        let turkish = Locale(identifier: "tr")
        let host = SettingsSliderHost(content: SettingsSliderContent(value: .constant(12), range: 0...200, enabled: true),
            label: "Bit rate", locale: english, valueDescription: "12 Mbps", localize: { resource in
                resolved.append(resource)
                return "\(resource.key) [\(resource.locale.identifier)]"
            })
        #expect(resolved.count == 1 && host.label == "Bit rate [en]")
        for _ in 0..<25 {
            host.updateLabel(LocalizedStringResource("Bit rate"), locale: english)
        }
        #expect(resolved.count == 1)
        host.updateLabel("Size", locale: english)
        #expect(resolved.count == 2 && host.label == "Size [en]")
        host.updateLabel("Size", locale: turkish)
        #expect(resolved.count == 3 && host.label == "Size [tr]")
        host.updateLabel("Size", locale: turkish)
        #expect(resolved.count == 3)
        host.updateLabel(LocalizedStringResource("Size", table: "Another table"), locale: turkish)
        #expect(resolved.count == 4 && resolved.last?.table == "Another table")
    }

    @Test("native slider identity, labels, values and enablement survive resource and locale updates")
    func nativeSliderLocalizationUpdates() async throws {
        _ = NSApplication.shared
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent("slider-localization-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        for (language, strings) in [
            ("en", "\"Bit rate\" = \"Bit rate\";\n\"Size\" = \"Size\";\n"),
            ("tr", "\"Bit rate\" = \"Bit hızı\";\n\"Size\" = \"Boyut\";\n")
        ] {
            let directory = bundleURL.appendingPathComponent("\(language).lproj")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try strings.write(to: directory.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        let info = ["CFBundleIdentifier": "dev.camcord.tests.slider.\(UUID().uuidString)", "CFBundleDevelopmentRegion": "en"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: bundleURL))
        let bitRate = LocalizedStringResource("Bit rate", bundle: bundle)
        let size = LocalizedStringResource("Size", bundle: bundle)
        var value = 12.6
        let binding = Binding(get: { value }, set: { value = $0 })
        func presentation(label: LocalizedStringResource, language: String, range: ClosedRange<Double>, enabled: Bool,
                          format: @escaping (Double) -> String) -> some View {
            SettingsNativeValueSlider(value: binding, range: range, label: label, format: format)
                .environment(\.locale, Locale(identifier: language))
                .disabled(!enabled)
        }
        let host = NSHostingView(rootView: presentation(label: bitRate, language: "en", range: 0...200, enabled: true,
                                                       format: { "Value \($0)" }))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 44)
        host.layoutSubtreeIfNeeded()
        let first = try #require(Self.nativeSliders(in: host).first)
        #expect(first.accessibilityLabel() == "Bit rate" && first.accessibilityValueDescription() == "Value 12.6")
        value = 0.197
        host.rootView = presentation(label: size, language: "tr", range: 0.08...0.60, enabled: false,
                                    format: { "\(Int(($0 * 100).rounded())) %" })
        try await Self.settleNativeSlider(in: host) { slider in
            slider.accessibilityLabel() == "Boyut" && slider.accessibilityValueDescription() == "20 %" && !slider.isEnabled
                && abs(slider.doubleValue - 0.197) < 0.000_001 && slider.minValue == 0.08 && slider.maxValue == 0.60
        }
        #expect(Self.nativeSliders(in: host).first === first)
        host.rootView = presentation(label: size, language: "en", range: 0.08...0.60, enabled: true,
                                    format: { "\(Int(($0 * 100).rounded())) %" })
        try await Self.settleNativeSlider(in: host) { $0.accessibilityLabel() == "Size" && $0.isEnabled }
        #expect(Self.nativeSliders(in: host).first === first)
        let target = try #require(first.target as? NSObject)
        let action = try #require(first.action)
        first.doubleValue = 0.25
        _ = target.perform(action, with: first)
        #expect(value == 0.25)
    }

    private static func settleNativeSlider(in host: NSView, until predicate: (NSSlider) -> Bool) async throws {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if let slider = nativeSliders(in: host).first, predicate(slider) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let slider = try #require(nativeSliders(in: host).first)
        try #require(predicate(slider), "The native slider did not receive its updated presentation")
    }

    private static func nativeSliders(in view: NSView) -> [NSSlider] {
        (view as? NSSlider).map { [$0] } ?? view.subviews.flatMap(nativeSliders)
    }

    /// Fields that are persisted but set by dragging on screen, never by a Settings control.
    static let draggedNotSet: Set<String> = ["recordingSettings.hubDock", "recordingSettings.camera.position"]

    static func fields(of value: Any, prefix: String) -> [String] {
        Mirror(reflecting: value).children.compactMap { $0.label.map { "\(prefix).\($0)" } }
    }

    /// Every key the old window could write (docs/_scratch/run-ui-2/settings-parity.md §2).
    static var requiredKeys: Set<String> {
        var keys = Set(fields(of: RecordingSettings(), prefix: "recordingSettings"))
        keys.remove("recordingSettings.camera")
        keys.formUnion(fields(of: CameraOptions(), prefix: "recordingSettings.camera"))
        keys.formUnion(fields(of: ScreenshotSettings(), prefix: "screenshotSettings"))
        keys.formUnion(fields(of: TapBindings(), prefix: "tapBindings"))
        keys.formUnion([FeedbackSound.enabledDefaultsKey, HUDToast.enabledDefaultsKey, DockIconMode.defaultsKey, "loginItem"])
        keys.formUnion(ShortcutCatalogue.all.map { "KeyboardShortcuts_\($0.name.rawValue)" })
        keys.formUnion([LibrarySettings.keepCopiedKey, LibrarySettings.keepDaysKey, LibrarySettings.capBytesKey])
        return keys.subtracting(draggedNotSet)
    }

    /// Renders every Settings page with every conditional row switched on, and collects the keys
    /// the rows report.
    static func renderedKeys(defaults: UserDefaults) throws -> Set<String> {
        var recording = RecordingSettings()
        recording.profile = .custom
        recording.codec = .hevc
        recording.systemAudio = true
        recording.microphone = true
        recording.camera.enabled = true
        recording.dndEnabled = true
        recording.save(to: defaults)
        var screenshot = ScreenshotSettings()
        screenshot.saveToDisk = true
        screenshot.save(to: defaults)
        let store = SettingsStore(defaults: defaults, eventTapEngine: nil)
        let recorder = SettingsKeyRecorder()
        SettingsKeyRecorder.active = recorder
        defer { SettingsKeyRecorder.active = nil }
        for group in SettingsGroup.allCases {
            let host = NSHostingView(rootView: SettingsPageView(group: group, store: store))
            host.frame = CGRect(x: 0, y: 0, width: 900, height: 2400)
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        return recorder.keys
    }

    @Test("every setting the old window wrote has a control in the Settings module")
    func everyKeyHasAControl() throws {
        _ = NSApplication.shared
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let required = Self.requiredKeys
        // The inventory counted 27 recording fields (24 top level + camera's 6, less the two
        // dragged ones), 3 screenshot, 4 mouse, 9 shortcuts, 4 general: a floor, not an exact count.
        #expect(required.count >= 45)
        let rendered = try Self.renderedKeys(defaults: defaults)
        let missing = required.subtracting(rendered)
        #expect(missing.isEmpty, "no control for: \(missing.sorted())")
    }

    @Test("the groups follow K7, and the Settings sidebar remembers its group")
    func groups() throws {
        #expect(SettingsGroup.allCases.map(\.rawValue) == ["general", "screenshot", "recording", "camera", "input", "library", "permissions"])
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        let model = MainWindowModel(defaults: defaults)
        #expect(model.settingsGroup == .general)
        model.settingsGroup = .camera
        #expect(MainWindowModel(defaults: defaults).settingsGroup == .camera)
        // Opening Settings from Studio and leaving goes back to Studio.
        model.select(.studio)
        model.select(.settings)
        model.leaveSettings()
        #expect(model.selection == .studio)
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    @Test("external camera placement is reloaded without a second write or resetting its dragged position")
    func externalPlacementIsReadOnly() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let store = SettingsStore(defaults: defaults, eventTapEngine: nil)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: RecordingSettings.didChangeNotification,
                                                             object: defaults, queue: .main) { _ in
            MainActor.assumeIsolated { notifications += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var elsewhere = store.recording
        elsewhere.camera.corner = .topLeft
        elsewhere.camera.position = CameraPosition(x: 0.4, y: 0.7)
        elsewhere.save(to: defaults)
        #expect(store.recording == elsewhere)
        #expect(RecordingSettings.load(from: defaults) == elsewhere)
        #expect(notifications == 1)
    }

    @Test("an edit preserves stale camera subfields and updates every local snapshot to the merged result")
    func staleSnapshotsMergeFieldByField() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let store = SettingsStore(defaults: defaults, eventTapEngine: nil)
        var elsewhere = store.recording
        elsewhere.camera.widthFraction = 0.45
        elsewhere.camera.formats["other-camera"] = .manual(width: 1920, height: 1080, fps: 30)
        // A separate defaults instance / external process can update the blob without this observer.
        defaults.set(try JSONEncoder().encode(elsewhere), forKey: RecordingSettings.defaultsKey)
        store.recording.camera.mirrored.toggle()
        #expect(store.recording.camera.widthFraction == 0.45)
        #expect(store.recording.camera.formats["other-camera"] == elsewhere.camera.formats["other-camera"])
        #expect(RecordingSettings.load(from: defaults).camera.widthFraction == 0.45)
        var screenshot = store.screenshot
        screenshot.saveDirectoryPath = "/tmp/elsewhere"
        screenshot.save(to: defaults)
        store.screenshot.saveToDisk = true
        #expect(store.screenshot.saveDirectoryPath == "/tmp/elsewhere")
        #expect(ScreenshotSettings.load(from: defaults) == store.screenshot)
        var bindings = store.tapBindings
        bindings.mouseButton3 = .captureRegion
        bindings.save(to: defaults)
        store.tapBindings.mouseButton4 = .toggleRecording
        #expect(store.tapBindings.mouseButton3 == .captureRegion)
        #expect(TapBindings.load(from: defaults) == store.tapBindings)
        var library = store.library
        library.capBytes = 5 << 30
        library.save(to: defaults)
        store.library.keepDays = 90
        #expect(store.library.capBytes == 5 << 30)
        #expect(LibrarySettings.load(from: defaults) == store.library)
    }

    @Test("re-entering Settings reloads other surfaces without saving the snapshot")
    func refreshIsReadOnly() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let store = SettingsStore(defaults: defaults, eventTapEngine: nil)
        var screenshot = store.screenshot
        screenshot.saveDirectoryPath = "/tmp/changed-while-away"
        screenshot.save(to: defaults)
        defaults.set(false, forKey: FeedbackSound.enabledDefaultsKey)
        defaults.set(false, forKey: HUDToast.enabledDefaultsKey)
        DockIconMode.never.save(to: defaults)
        var library = store.library
        library.keepDays = 365
        library.save(to: defaults)
        let before = defaults.dictionaryRepresentation() as NSDictionary
        store.refresh()
        #expect(store.screenshot == screenshot)
        #expect(!store.feedbackSounds && !store.copyToast)
        #expect(store.dockIconMode == .never)
        #expect(store.library.keepDays == 365)
        let after = defaults.dictionaryRepresentation() as NSDictionary
        #expect(before.isEqual(after))
        // A test suite cannot change the machine's actual ServiceManagement setting.
        store.launchAtLogin = true
        store.refresh()
        #expect(!store.launchAtLogin)
    }

    @Test("a rejected login item change restores the actual switch and shows recovery")
    func rejectedLoginItemChange() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        var actual = false
        var attempts: [Bool] = []
        let store = SettingsStore(defaults: defaults, eventTapEngine: nil,
                                  loginItem: .init(read: { actual }, write: { attempts.append($0) }))
        store.launchAtLogin = true
        #expect(attempts == [true])
        #expect(!store.launchAtLogin)
        #expect(store.launchAtLoginIssue)
        actual = true // The owner approved it in System Settings.
        store.refresh()
        #expect(store.launchAtLogin)
        #expect(!store.launchAtLoginIssue)
        #expect(attempts == [true])
    }

    @Test("a page change is merged into what is on disk, never over it")
    func mergesIntoDisk() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let store = SettingsStore(defaults: defaults, eventTapEngine: nil)
        // Another surface (the menu-bar panel) changes a field the page does not touch…
        var elsewhere = RecordingSettings.load(from: defaults)
        elsewhere.fps = 30
        elsewhere.save(to: defaults)
        // …the store follows it, and its own change keeps it.
        #expect(store.recording.fps == 30)
        store.recording.showsCursor.toggle()
        let onDisk = RecordingSettings.load(from: defaults)
        #expect(onDisk.fps == 30)
        #expect(onDisk.showsCursor == store.recording.showsCursor)
        // A new corner drops a dragged position.
        store.recording.camera.position = CameraPosition(x: 0.3, y: 0.4)
        store.recording.camera.corner = .topLeft
        #expect(RecordingSettings.load(from: defaults).camera.position == nil)
        store.library.keepDays = 90
        #expect(LibrarySettings.load(from: defaults).keepDays == 90)
    }
}
