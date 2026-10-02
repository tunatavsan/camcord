import AppKit
import Testing

@testable import Camcord

@MainActor
@Suite("Main window initial geometry")
struct MainWindowGeometryTests {
    private let usable = NSRect(x: 0, y: 48, width: 1800, height: 1090)

    private func withDefaults(_ work: (UserDefaults) throws -> Void) throws {
        let suite = "camcord.window-geometry." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try work(defaults)
    }

    private func descriptor(_ frame: NSRect) -> String {
        "\(frame.minX) \(frame.minY) \(frame.width) \(frame.height) 0 0 1800 1169"
    }

    @Test("Defaults use eighty percent of the usable display, excluding menu bar and Dock")
    func usableDisplay() {
        let frame = MainWindowGeometry.defaultFrame(in: usable)
        #expect(frame.size == NSSize(width: 1440, height: 872))
        #expect(frame.origin == NSPoint(x: 180, y: 157))
        #expect(usable.contains(frame))
        let huge = MainWindowGeometry.defaultFrame(in: NSRect(x: 0, y: 60, width: 3000, height: 2000))
        #expect(huge.size == NSSize(width: 1440, height: 900))
    }

    @Test("External displays retain negative origins and their own visible-area center")
    func negativeOrigin() {
        let screen = NSRect(x: -2000, y: -950, width: 1600, height: 1000)
        let frame = MainWindowGeometry.defaultFrame(in: screen)
        #expect(frame == NSRect(x: -1840, y: -850, width: 1280, height: 800))
        #expect(screen.contains(frame))
    }

    @Test("Small displays keep the minimum and leave the title bar reachable")
    func smallDisplays() {
        let fitting = NSRect(x: 25, y: 40, width: 1000, height: 700)
        #expect(MainWindowGeometry.defaultFrame(in: fitting) == NSRect(x: 35, y: 70, width: 980, height: 640))
        let smaller = NSRect(x: -900, y: 20, width: 900, height: 600)
        let frame = MainWindowGeometry.defaultFrame(in: smaller)
        #expect(frame.size == MainWindowGeometry.minimumSize)
        #expect(frame.minX == smaller.minX && frame.maxY == smaller.maxY)
        #expect(MainWindowGeometry.defaultFrame(in: nil) == NSRect(origin: .zero, size: MainWindowGeometry.minimumSize))
        #expect(MainWindowGeometry.defaultFrame(in: .zero).size == MainWindowGeometry.minimumSize)
    }

    @Test("Missing autosave uses the new default; absent autosave names write no migration flag")
    func missingAutosave() throws {
        try withDefaults { defaults in
            let frame = MainWindowGeometry.initialFrame(savedFrameDescriptor: nil, visibleFrame: usable,
                defaults: defaults, autosaveName: nil)
            #expect(frame == MainWindowGeometry.defaultFrame(in: usable))
            #expect(defaults.object(forKey: MainWindowGeometry.migrationKey(for: "test")) == nil)
            #expect(MainWindowGeometry.initialFrame(savedFrameDescriptor: nil, visibleFrame: usable,
                defaults: defaults, autosaveName: "test") == frame)
            #expect(defaults.bool(forKey: MainWindowGeometry.migrationKey(for: "test")))
        }
    }

    @Test("Legacy outer and native content-derived sizes migrate once without deleting the saved frame")
    func legacyMigration() throws {
        _ = NSApplication.shared
        let native = NSWindow(contentRect: NSRect(origin: .zero, size: MainWindowGeometry.legacyContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        native.toolbarStyle = .unified
        native.toolbar = NSToolbar(identifier: "geometry-test")
        let converted = native.frameRect(forContentRect: NSRect(origin: .zero, size: MainWindowGeometry.legacyContentSize)).size
        for size in [MainWindowGeometry.legacyContentSize, converted] {
            try withDefaults { defaults in
                let old = descriptor(NSRect(x: -1820, y: 100, width: size.width, height: size.height))
                defaults.set(old, forKey: "NSWindow Frame test")
                defaults.set("preserved", forKey: "unrelated-setting")
                let migrate = MainWindowGeometry.initialFrame(savedFrameDescriptor: old, visibleFrame: usable,
                    defaults: defaults, autosaveName: "test")
                #expect(migrate == MainWindowGeometry.defaultFrame(in: usable))
                #expect(MainWindowGeometry.initialFrame(savedFrameDescriptor: old, visibleFrame: usable,
                    defaults: defaults, autosaveName: "test") == nil)
                #expect(defaults.string(forKey: "NSWindow Frame test") == old)
                #expect(defaults.string(forKey: "unrelated-setting") == "preserved")
            }
        }
        #expect(!native.isVisible && !native.isKeyWindow)
    }

    @Test("A saved frame smaller in both dimensions grows once and centers on its restored display")
    func smallerSavedFrameMigration() throws {
        let display = NSRect(x: -1800, y: 48, width: 1800, height: 1130)
        try withDefaults { defaults in
            let old = descriptor(NSRect(x: -1700, y: 150, width: 1315, height: 792))
            defaults.set(old, forKey: "NSWindow Frame test")
            defaults.set("preserved", forKey: "unrelated-setting")
            let frame = MainWindowGeometry.initialFrame(savedFrameDescriptor: old, visibleFrame: display,
                defaults: defaults, autosaveName: "test")
            #expect(frame == NSRect(x: -1620, y: 163, width: 1440, height: 900))
            #expect(defaults.bool(forKey: MainWindowGeometry.migrationKey(for: "test")))
            #expect(defaults.object(forKey: "MainWindowDefaultFrameMigration.test") == nil)
            #expect(MainWindowGeometry.initialFrame(savedFrameDescriptor: old, visibleFrame: display,
                defaults: defaults, autosaveName: "test") == nil)
            #expect(defaults.string(forKey: "NSWindow Frame test") == old)
            #expect(defaults.string(forKey: "unrelated-setting") == "preserved")
        }
    }

    @Test("A manual smaller frame saved after migration stays unchanged on the next opening")
    func manualResizeAfterMigration() throws {
        let display = NSRect(x: 0, y: 48, width: 1800, height: 1130)
        try withDefaults { defaults in
            let old = descriptor(NSRect(x: 100, y: 150, width: 1315, height: 792))
            let first = MainWindowGeometry.initialFrame(savedFrameDescriptor: old, visibleFrame: display,
                defaults: defaults, autosaveName: "test")
            #expect(first?.size == NSSize(width: 1440, height: 900))
            let manual = NSRect(x: 240, y: 180, width: 1100, height: 700)
            let saved = descriptor(manual)
            defaults.set(saved, forKey: "NSWindow Frame test")
            #expect(MainWindowGeometry.initialFrame(savedFrameDescriptor: defaults.string(forKey: "NSWindow Frame test"),
                visibleFrame: display, defaults: defaults, autosaveName: "test") == nil)
            #expect(MainWindowGeometry.savedFrame(from: defaults.string(forKey: "NSWindow Frame test")) == manual)
            #expect(defaults.bool(forKey: MainWindowGeometry.migrationKey(for: "test")))
        }
    }

    @Test("The existing migration flag does not block the independent v2 saved-frame assessment")
    func previousMigrationFlag() throws {
        let display = NSRect(x: 0, y: 48, width: 1800, height: 1130)
        try withDefaults { defaults in
            let previousKey = "MainWindowDefaultFrameMigration.test"
            defaults.set(1, forKey: previousKey)
            let old = descriptor(NSRect(x: 100, y: 150, width: 1315, height: 792))
            defaults.set(old, forKey: "NSWindow Frame test")
            let frame = MainWindowGeometry.initialFrame(savedFrameDescriptor: old, visibleFrame: display,
                defaults: defaults, autosaveName: "test")
            #expect(frame == NSRect(x: 180, y: 163, width: 1440, height: 900))
            #expect(defaults.integer(forKey: previousKey) == 1)
            #expect(defaults.bool(forKey: MainWindowGeometry.migrationKey(for: "test")))
            #expect(defaults.string(forKey: "NSWindow Frame test") == old)
        }
    }

    @Test("Saved frames at or above either default dimension keep their origin and bypass future migration")
    func manualFrames() throws {
        let display = NSRect(x: -1800, y: 48, width: 1800, height: 1130)
        for frame in [NSRect(x: -1530, y: 100, width: 1441, height: 792),
                      NSRect(x: -1530, y: 100, width: 1315, height: 901),
                      NSRect(x: -1530, y: 100, width: 1440, height: 792),
                      NSRect(x: -1530, y: 100, width: 1315, height: 900)] {
            try withDefaults { defaults in
                let old = descriptor(frame)
                defaults.set(old, forKey: "NSWindow Frame test")
                #expect(MainWindowGeometry.savedFrame(from: old) == frame)
                #expect(MainWindowGeometry.initialFrame(savedFrameDescriptor: old, visibleFrame: display,
                    defaults: defaults, autosaveName: "test") == nil)
                #expect(defaults.string(forKey: "NSWindow Frame test") == old)
                #expect(defaults.bool(forKey: MainWindowGeometry.migrationKey(for: "test")))
                // A later manual resize to the exact old default remains the owner's choice.
                let later = descriptor(NSRect(origin: frame.origin, size: MainWindowGeometry.legacyContentSize))
                #expect(MainWindowGeometry.initialFrame(savedFrameDescriptor: later, visibleFrame: display,
                    defaults: defaults, autosaveName: "test") == nil)
            }
        }
    }

    @Test("Malformed saved frame descriptors are rejected")
    func malformedDescriptors() {
        for invalid in ["", "not a frame", "0 0 1180", "0 0 nan 760", "0 0 -1180 760"] {
            #expect(MainWindowGeometry.savedFrame(from: invalid) == nil)
        }
    }

    @Test("A smaller saved frame centers on the current display after its original display is unplugged")
    func unpluggedDisplay() throws {
        try withDefaults { defaults in
            let old = descriptor(NSRect(x: -1900, y: -1200, width: 1000, height: 650))
            let remaining = NSRect(x: 0, y: 50, width: 1440, height: 850)
            let frame = MainWindowGeometry.initialFrame(savedFrameDescriptor: old, visibleFrame: remaining,
                defaults: defaults, autosaveName: "test")
            #expect(frame == NSRect(x: 144, y: 135, width: 1152, height: 680))
        }
    }

    @Test("The actual controller applies the outer-frame default and minimum without ordering or activating")
    func nativeController() async throws {
        _ = NSApplication.shared
        let suite = "camcord.window-geometry." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: MainWindowGeometry.minimumSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        let active = NSApp.isActive
        let controller = MainWindowController(visibleFrame: { _ in usable },
            windowFactory: { window }, presentBackground: { _ in },
            defaults: defaults, dock: DockController(defaults: defaults) { _ in },
            frameAutosaveName: nil, present: { _ in Issue.record("Must not activate") })
        controller.show(activate: false)
        defer { controller.close() }
        #expect(window.frame == MainWindowGeometry.defaultFrame(in: usable))
        #expect(window.minSize == MainWindowGeometry.minimumSize)
        #expect(window.frameAutosaveName.isEmpty)
        #expect(!window.isVisible && !window.isKeyWindow && NSApp.isActive == active)
        // Hosting updates run after initial installation; test the eventual constraint
        // as modules/toolbar items change and after a new host is installed on reopen.
        for module in [ModuleID.settings, .studio, .edit, .library] {
            controller.model.select(module)
            for _ in 0..<5 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(window.minSize == MainWindowGeometry.minimumSize)
        }
        let manual = NSRect(x: 160, y: 180, width: 1315, height: 792)
        window.setFrame(manual, display: false)
        controller.close()
        // A closed host has no observation; its old constraint can be changed independently.
        let inactiveMinimum = NSSize(width: 700, height: 400)
        MainWindowGeometry.applyMinimum(inactiveMinimum, to: window)
        #expect(window.minSize == inactiveMinimum)
        controller.show(activate: false)
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(window.frame == manual)
        #expect(window.minSize == MainWindowGeometry.minimumSize)
        #expect(!window.isVisible && !window.isKeyWindow && NSApp.isActive == active)
    }
}
