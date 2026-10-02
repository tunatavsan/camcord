import AppKit
import SwiftUI
import Testing

@testable import Camcord

@MainActor private struct SettingsCardBoundsProbe: NSViewRepresentable {
    final class ProbeView: NSView {}
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {}
}

@MainActor @Observable private final class SettingsLayoutSelection {
    var group = SettingsGroup.general
}

@MainActor private struct SettingsLayoutShell: View {
    let selection: SettingsLayoutSelection
    let store: SettingsStore
    var body: some View {
        SettingsPageView(group: selection.group, store: store)
            .environment(\.mainWindowModuleActive, false)
            .transaction { $0.disablesAnimations = true }
    }
}

@MainActor
@Suite("Settings layout")
struct SettingsLayoutTests {
    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func settle(_ host: NSView, reason: String = "layout", until predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(predicate(), "The offscreen Settings layout did not settle: \(reason)")
    }

    @Test("the rendered card column stays centered and bounded while its host resizes")
    func centeredColumn() async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: FormPage(title: SettingsGroup.general.title) {
            FormCard {
                FormRow(label: SettingsGroup.general.title, isFirst: true) {
                    Text(verbatim: "Control").fixedSize()
                }
            }
            .background(SettingsCardBoundsProbe())
        })
        var firstTop: CGFloat?
        for width: CGFloat in [720, 1000, 1300, 640, 900] {
            host.frame = NSRect(x: 0, y: 0, width: width, height: 640)
            try await settle(host) {
                guard let probe = descendants(of: SettingsCardBoundsProbe.ProbeView.self, in: host).first else { return false }
                let rect = probe.convert(probe.bounds, to: host)
                return rect.width > 0 && abs(rect.midX - width / 2) < 0.5
            }
            let probe = try #require(descendants(of: SettingsCardBoundsProbe.ProbeView.self, in: host).first)
            let rect = probe.convert(probe.bounds, to: host)
            let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
            #expect(abs(rect.midX - host.bounds.midX) < 0.5)
            #expect(abs(rect.width - min(620, width - 64)) < 0.5)
            #expect(rect.minX >= 32 && rect.maxX <= width - 32)
            if let firstTop { #expect(abs(top - firstTop) < 0.5) }
            else { firstTop = top }
        }
    }

    @Test("changing Settings groups starts the new page at the top without changing stored settings")
    func groupScrollReset() async throws {
        _ = NSApplication.shared
        let suite = "camcord.settings.layout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: FeedbackSound.enabledDefaultsKey)
        let store = SettingsStore(defaults: defaults, eventTapEngine: nil)
        #expect(!store.feedbackSounds)
        let selection = SettingsLayoutSelection()
        let host = NSHostingView(rootView: SettingsLayoutShell(selection: selection, store: store))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 160)
        // AppKit initializes the document geometry only after mounting; this window is never ordered.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        // Compare only this suite's persisted preferences, excluding AppKit's global registrations.
        let before = try #require(defaults.persistentDomain(forName: suite)) as NSDictionary
        try await settle(host, reason: "initial native scroll view") { descendants(of: NSScrollView.self, in: host).count == 1 }
        let first = try #require(descendants(of: NSScrollView.self, in: host).first)
        try await settle(host, reason: "scrollable initial content") { (first.documentView?.bounds.height ?? 0) > first.contentSize.height + 100 }
        first.contentView.scroll(to: NSPoint(x: 0, y: 100))
        first.reflectScrolledClipView(first.contentView)
        #expect(first.contentView.bounds.minY > 50)
        for group in [SettingsGroup.screenshot, .general] {
            selection.group = group
            try await settle(host, reason: "new \(group.rawValue) page at the top") {
                let scrolls = descendants(of: NSScrollView.self, in: host)
                return scrolls.count == 1 && abs(scrolls[0].contentView.bounds.minY) < 0.5
            }
            let scroll = try #require(descendants(of: NSScrollView.self, in: host).first)
            #expect(abs(scroll.contentView.bounds.minY) < 0.5)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 80))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let after = try #require(defaults.persistentDomain(forName: suite)) as NSDictionary
        #expect(before.isEqual(after))
        #expect(!window.isVisible && !window.isKeyWindow && !window.isMainWindow)
    }
}
