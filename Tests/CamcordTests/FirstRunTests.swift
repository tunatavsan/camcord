import AppKit
import Testing

@testable import Camcord

/// The first run: when it shows, when it counts as seen, and the live permission state.
@MainActor
@Suite("First run", .serialized)
struct FirstRunTests {
    private static let suiteName = "camcord.firstrun.test"

    private func freshDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        return defaults
    }

    @Test("it shows while Screen Recording is missing, and once on a version-1 install")
    func policy() {
        #expect(FirstRunPolicy.shouldShow(screenRecordingGranted: false, seenGeneration: 0))
        #expect(FirstRunPolicy.shouldShow(screenRecordingGranted: false, seenGeneration: 1))
        #expect(FirstRunPolicy.shouldShow(screenRecordingGranted: true, seenGeneration: 0))
        #expect(!FirstRunPolicy.shouldShow(screenRecordingGranted: true, seenGeneration: 1))
        #expect(!FirstRunPolicy.shouldShow(screenRecordingGranted: true, seenGeneration: 2))
    }

    /// A grant the test can flip after handing it to the permission.
    @MainActor final class Grant { var value = false }

    @Test("the permission follows its check, and a simulated grant wins until cleared")
    func permission() {
        let grant = Grant()
        let permission = ScreenRecordingPermission { grant.value }
        #expect(!permission.granted)
        grant.value = true
        #expect(!permission.granted)
        permission.refresh()
        #expect(permission.granted)
        permission.simulated = false
        #expect(!permission.granted)
        permission.simulated = nil
        #expect(permission.granted)
    }

    @Test("closing with the grant counts as seen; closing without it brings the window back next launch")
    func seenOnClose() throws {
        _ = NSApplication.shared
        let defaults = try freshDefaults()
        let grant = Grant()
        let controller = FirstRunWindowController(presenter: { _, _ in }, defaults: defaults, permission: ScreenRecordingPermission { grant.value }) {}
        #expect(controller.showIfNeeded(activate: false))
        controller.close()
        #expect(defaults.integer(forKey: FirstRunPolicy.seenKey) == 0)
        #expect(FirstRunPolicy.shouldShow(defaults: defaults, screenRecordingGranted: false))

        grant.value = true
        #expect(controller.showIfNeeded(activate: false))
        controller.close()
        #expect(defaults.integer(forKey: FirstRunPolicy.seenKey) == FirstRunPolicy.currentGeneration)
        #expect(!controller.showIfNeeded(activate: false))
    }

    @Test("policy refreshes a previously granted permission before deciding")
    func revokedPermission() throws {
        let defaults = try freshDefaults()
        FirstRunPolicy.markSeen(in: defaults)
        let grant = Grant()
        grant.value = true
        let permission = ScreenRecordingPermission { grant.value }
        let controller = FirstRunWindowController(presenter: { _, _ in }, defaults: defaults, permission: permission) {}
        grant.value = false
        #expect(controller.showIfNeeded(activate: false))
        #expect(!permission.granted)
        controller.close()
    }

    @Test("visible lifecycle restarts polling after close and reopening")
    func reopenedPolling() async throws {
        let defaults = try freshDefaults()
        let grant = Grant()
        let permission = ScreenRecordingPermission(pollInterval: .milliseconds(5)) { grant.value }
        let controller = FirstRunWindowController(presenter: { _, _ in }, defaults: defaults, permission: permission) {}
        controller.show(activate: false)
        #expect(permission.isPolling)
        controller.close()
        #expect(!permission.isPolling)
        controller.show(activate: false)
        #expect(permission.isPolling)
        grant.value = true
        for _ in 0..<30 where !permission.granted { try await Task.sleep(for: .milliseconds(5)) }
        #expect(permission.granted)
        controller.close()
        grant.value = false
        try await Task.sleep(for: .milliseconds(20))
        #expect(permission.granted, "closed windows must not keep polling")
        #expect(!permission.isPolling)
    }

    @Test("the permission transition resolves Reduce Motion")
    func reduceMotion() {
        #expect(FirstRunView.permissionAnimation(reduceMotion: true) == Theme.Motion.reduced)
        #expect(FirstRunView.permissionAnimation(reduceMotion: false) == Theme.Motion.panel)
    }

    @Test("closing before any show does not consume onboarding; future seen versions stay intact")
    func closeBeforeShow() throws {
        let defaults = try freshDefaults()
        let controller = FirstRunWindowController(presenter: { _, _ in }, defaults: defaults,
            permission: ScreenRecordingPermission { true }) {}
        controller.close()
        #expect(defaults.integer(forKey: FirstRunPolicy.seenKey) == 0)
        #expect(controller.windowForTesting == nil)
        defaults.set(2, forKey: FirstRunPolicy.seenKey)
        controller.show(activate: false)
        controller.close()
        #expect(defaults.integer(forKey: FirstRunPolicy.seenKey) == 2)
    }

    @Test("the live check shows the first run as asked")
    func liveCheckCommand() {
        #expect(LiveCheck.Command.parse("firstrun ask") == .firstRun(simulatedGrant: false))
        #expect(LiveCheck.Command.parse("firstrun granted") == .firstRun(simulatedGrant: true))
        #expect(LiveCheck.Command.parse("firstrun") == .firstRun(simulatedGrant: nil))
        #expect(LiveCheck.Command.parse("firstrun maybe") == nil)
    }
}
