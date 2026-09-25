import AppKit
import Testing

@testable import Camcord

/// The first run (SPEC S6): when it shows, when it counts as seen, and the live permission state.
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
        let controller = FirstRunWindowController(defaults: defaults, permission: ScreenRecordingPermission { grant.value }) {}
        #expect(controller.showIfNeeded(activate: false))
        controller.windowForTesting?.close()
        #expect(defaults.integer(forKey: FirstRunPolicy.seenKey) == 0)
        #expect(FirstRunPolicy.shouldShow(defaults: defaults, screenRecordingGranted: false))

        grant.value = true
        #expect(controller.showIfNeeded(activate: false))
        controller.windowForTesting?.close()
        #expect(defaults.integer(forKey: FirstRunPolicy.seenKey) == FirstRunPolicy.currentGeneration)
        #expect(!controller.showIfNeeded(activate: false))
    }

    @Test("the live check shows the first run as asked")
    func liveCheckCommand() {
        #expect(LiveCheck.Command.parse("firstrun ask") == .firstRun(simulatedGrant: false))
        #expect(LiveCheck.Command.parse("firstrun granted") == .firstRun(simulatedGrant: true))
        #expect(LiveCheck.Command.parse("firstrun") == .firstRun(simulatedGrant: nil))
        #expect(LiveCheck.Command.parse("firstrun maybe") == nil)
    }
}
