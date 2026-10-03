import AppKit
import Darwin
import QuartzCore
import Testing
@testable import Camcord

@Suite("Screenshot card interaction", .serialized)
@MainActor struct ScreenshotCardInteractionTests {
    @Test("every card host keeps one fixed size and stands on the window tray's frost", arguments: [
        CGSize(width: 60, height: 30), CGSize(width: 30, height: 60), CGSize(width: 30, height: 600)
    ])
    func nativeFixedHost(size: CGSize) throws {
        let clock = CardClock(), animations = CardAnimations()
        let card = controller(clock: clock, animations: animations)
        defer { card.hide(); clock.finish() }
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: Int(size.width) * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        card.show(capture: CapturedScreenshot(id: UUID(), image: image,
            pointSize: CGSize(width: size.width / 2, height: size.height / 2), kind: .screenshot, saveToDiskRequested: false))
        let entry = try #require(card.entries.first)
        #expect(entry.window.frame.size == ScreenshotCardGeometry.window)
        #expect(entry.window.frame.maxX == 0)
        func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) }
        }
        // The card stands on the window tray's frost itself, without a glass pane over it.
        #expect(views(NSGlassEffectView.self, in: entry.host).isEmpty)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            #expect(views(TrayBlurView.self, in: entry.host).count == 1)
        }
    }

    @Test("Save chooser's pause is independent of hover and preserves the remaining dwell")
    func savePauseBudget() {
        var dwell = ScreenshotCardDwell()
        dwell.enter(at: 0)
        let beganSaving = dwell.setPaused(.saving, active: true, at: 2)
        #expect(beganSaving)
        #expect(dwell.remaining == 3 && dwell.deadline == nil)
        let beganHover = dwell.setPaused(.hover, active: true, at: 10)
        #expect(beganHover)
        let endedSaving = dwell.setPaused(.saving, active: false, at: 20)
        #expect(endedSaving)
        #expect(dwell.deadline == nil)
        let endedHover = dwell.setPaused(.hover, active: false, at: 21)
        #expect(endedHover)
        #expect(dwell.deadline == 24)
    }

    private func capture(id: UUID = UUID(), originDisplayID: CGDirectDisplayID? = nil) throws -> CapturedScreenshot {
        let context = try #require(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 1600,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        return CapturedScreenshot(id: id, image: try #require(context.makeImage()), pointSize: CGSize(width: 200, height: 100), kind: .screenshot, saveToDiskRequested: false, originDisplayID: originDisplayID)
    }
    private func controller(clock: CardClock, animations: CardAnimations, visible: CGRect = CGRect(x: -1440, y: -200, width: 1440, height: 900),
                            operations suppliedOperations: ScreenshotCardModel.Operations? = nil) -> ScreenshotPreviewCard {
        _ = NSApplication.shared
        var operations = suppliedOperations ?? ScreenshotCardModel.Operations()
        operations.encode = { _ in throw CancellationError() }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        operations.exports = ScreenshotTemporaryExports(directory: root.appendingPathComponent("camcord-card-tests-" + UUID().uuidString))
        return ScreenshotPreviewCard(presenter: { _ in }, screenFrame: { visible }, operations: operations, hostFactory: { frame in
            NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        }, animator: { host, entering, reduced, completion in animations.pending.append(.init(host: host, entering: entering, completion: completion)) },
        timing: .init(now: { clock.now }, sleep: { try await clock.sleep($0) }), enabled: { true })
    }
    @Test("five active seconds begin after entrance, and hover preserves the remaining three")
    func timedHover() async throws {
        let clock = CardClock(), animations = CardAnimations()
        let card = controller(clock: clock, animations: animations)
        defer { card.hide(); clock.finish() }
        card.show(capture: try capture())
        let entry = try #require(card.entries.first)
        clock.advance(to: 10)
        #expect(entry.dwell.deadline == nil)
        animations.completeEntrance()
        #expect(entry.dwell.deadline == 15)
        await settle()
        clock.advance(to: 12)
        entry.host.onPause?(.hover, true)
        #expect(entry.dwell.remaining == 3)
        clock.advance(to: 40)
        entry.host.onPause?(.hover, true)
        #expect(entry.dwell.remaining == 3)
        entry.host.onPause?(.hover, false)
        #expect(entry.dwell.deadline == 43)
        await settle()
        clock.advance(to: 42.99); await settle()
        #expect(card.entries.count == 1)
        clock.advance(to: 43); await settle()
        #expect(card.entries.isEmpty)
        #expect(entry.dismissReason == "timeout")
        animations.completeExit()
        #expect(entry.orderedOutAt == 43)
    }
    @Test("clipboard-only show, hover and dismissal never request an export or create an export file")
    func passiveCardNeverExports() async throws {
        _ = NSApplication.shared
        let clock = CardClock(), animations = CardAnimations(), counter = CardPassiveExportCounter()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-passive-card-" + UUID().uuidString)
        var operations = ScreenshotCardModel.Operations()
        operations.exports = ScreenshotTemporaryExports(directory: directory)
        operations.encode = { _ in await counter.record(); throw CancellationError() }
        let card = ScreenshotPreviewCard(presenter: { _ in }, screenFrame: { CGRect(x: 0, y: 0, width: 700, height: 600) }, operations: operations,
            hostFactory: { NSWindow(contentRect: $0, styleMask: [.borderless], backing: .buffered, defer: true) },
            animator: { host, entering, _, completion in animations.pending.append(.init(host: host, entering: entering, completion: completion)) },
            timing: .init(now: { clock.now }, sleep: { try await clock.sleep($0) }), enabled: { true })
        defer { card.hide(); clock.finish() }
        let shot = try capture()
        #expect(!shot.saveToDiskRequested)
        card.show(capture: shot); animations.completeEntrance()
        let entry = try #require(card.entries.first)
        entry.host.onPause?(.hover, true)
        await settle()
        entry.host.onPause?(.hover, false)
        card.hide(); await settle()
        #expect(await counter.count == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(entry.model.preparedExportURL == nil)
        #expect(entry.model.preparedExportPNG == nil)
    }
    @Test("duplicate and nested busy, share, drag, gesture pauses cannot extend or resume another reason")
    func nestedPauses() {
        var dwell = ScreenshotCardDwell()
        dwell.setPaused(.busy, active: true, at: 0)
        dwell.enter(at: 10)
        #expect(dwell.deadline == nil)
        dwell.setPaused(.busy, active: false, at: 20)
        #expect(dwell.deadline == 25)
        dwell.setPaused(.hover, active: true, at: 22)
        dwell.setPaused(.sharing, active: true, at: 30)
        dwell.setPaused(.dragging, active: true, at: 40)
        dwell.setPaused(.gesture, active: true, at: 50)
        let duplicate = dwell.setPaused(.gesture, active: true, at: 90)
        #expect(!duplicate)
        for reason in [ScreenshotCardDwell.Pause.hover, .sharing, .dragging] { dwell.setPaused(reason, active: false, at: 100) }
        #expect(dwell.deadline == nil)
        #expect(dwell.remaining == 3)
        dwell.setPaused(.gesture, active: false, at: 200)
        #expect(dwell.deadline == 203)
        dwell.leave(at: 201)
        let afterLeave = dwell.setPaused(.hover, active: true, at: 202)
        #expect(!afterLeave)
        #expect(dwell.remaining == 2)
    }
    @Test("three captures keep independent clocks and UUID routing; the fourth evicts only the oldest")
    func stackAndRouting() async throws {
        let clock = CardClock(), animations = CardAnimations()
        let card = controller(clock: clock, animations: animations)
        defer { card.hide(); clock.finish() }
        let first = try capture(), second = try capture(), third = try capture(), fourth = try capture()
        card.show(capture: first); animations.completeEntrance()
        let original = try #require(card.entries.first)
        original.host.onPause?(.hover, true)
        clock.advance(to: 2)
        card.show(capture: second); animations.completeEntrance()
        card.show(capture: third); animations.completeEntrance()
        #expect(original.dwell.remaining == 5)
        #expect(card.model?.capture.id == third.id)
        let secondEntry = try #require(card.entries.first { $0.model.capture.id == second.id })
        let url = URL(fileURLWithPath: "/private/second.png")
        card.saved(id: second.id, to: url); card.saveFailed(id: first.id)
        #expect(secondEntry.model.savedURL == url)
        #expect(original.model.error != nil)
        #expect(card.model?.error == nil)
        let secondDeadline = secondEntry.dwell.deadline
        card.show(capture: fourth); animations.completeEntrance()
        #expect(card.entries.map(\.model.capture.id) == [second.id, third.id, fourth.id])
        #expect(!original.model.isAlive)
        #expect(secondEntry.model.isAlive)
        #expect(secondEntry.dwell.deadline == secondDeadline)
        #expect(original.orderedOutAt == 2)
        card.saved(id: first.id, to: url)
        #expect(original.model.savedURL == nil)
        let frames = card.entries.map { $0.window.frame }
        #expect(frames.allSatisfy { $0.minX >= -1440 && $0.maxX == 0 && $0.minY >= -200 && $0.maxY <= 700 })
        // Shadow margins may overlap; the visible cards never do.
        let cards = frames.map { $0.insetBy(dx: 0, dy: ScreenshotCardGeometry.shadowInset) }
        #expect(zip(cards, cards.dropFirst()).allSatisfy { $0.maxY + ScreenshotPreviewCard.stackGap <= $1.minY + 0.001 })
        await settle()
    }
    @Test("stale hover, entrance and exit completions cannot mutate a newer presentation with the same UUID")
    func staleGeneration() throws {
        let clock = CardClock(), animations = CardAnimations()
        let card = controller(clock: clock, animations: animations)
        defer { card.hide(); clock.finish() }
        let shot = try capture()
        card.show(capture: shot)
        let old = try #require(card.entries.first)
        let hover = old.host.onPause, edit = old.host.onEdit
        old.host.onDismiss?("close")
        #expect(!old.model.isAlive)
        card.show(capture: shot)
        let newest = try #require(card.entries.first)
        #expect(newest.generation != old.generation)
        hover?(.hover, true); edit?()
        animations.completeEntrance() // The stale original entrance is rejected.
        #expect(newest.dwell.phase == .entering)
        animations.completeExit()
        #expect(card.model === newest.model)
        #expect(old.orderedOutAt != nil)
        #expect(newest.orderedOutAt == nil)
        animations.completeEntrance()
        #expect(newest.dwell.phase == .visible)
        #expect(newest.dwell.pauses.isEmpty)
        card.show(capture: shot)
        #expect(card.entries.count == 1)
    }
    @Test("capture display ID selects its current visible frame despite cursor movement, with nil and hotplug fallback")
    func displayOriginAndHotplug() throws {
        _ = NSApplication.shared
        let clock = CardClock(), animations = CardAnimations()
        let captured = CGRect(x: -1440, y: -200, width: 1440, height: 800)
        var cursor = CGRect(x: 100, y: 100, width: 1200, height: 800)
        var frames: [(id: CGDirectDisplayID, visibleFrame: CGRect)] = [(7, captured), (9, cursor)]
        let card = ScreenshotPreviewCard(presenter: { _ in }, screenFrame: { cursor }, hostFactory: {
            NSWindow(contentRect: $0, styleMask: [.borderless], backing: .buffered, defer: true)
        }, animator: { host, entering, _, completion in animations.pending.append(.init(host: host, entering: entering, completion: completion)) },
        timing: .init(now: { clock.now }, sleep: { try await clock.sleep($0) }), displayFrames: { frames }, enabled: { true })
        defer { card.hide(); clock.finish() }
        let delayed = try capture(originDisplayID: 7)
        cursor = CGRect(x: 2000, y: 0, width: 1200, height: 800)
        card.show(capture: delayed)
        #expect(card.entries.last?.visibleFrame == captured)
        #expect(card.entries.last?.window.frame.maxX == captured.maxX)
        let current = captured.insetBy(dx: 0, dy: 25)
        frames[0] = (7, current)
        card.show(capture: try capture(originDisplayID: 7))
        #expect(card.entries.last?.visibleFrame == current)
        frames.removeAll { $0.id == 7 }
        card.show(capture: try capture(originDisplayID: 7))
        #expect(card.entries.last?.visibleFrame == cursor)
        card.show(capture: try capture())
        #expect(card.entries.last?.visibleFrame == cursor)
    }
    @Test("native drag endpoint reconciles a missed hover exit, while invalidated old hosts cannot pause replacements")
    func dragEndHoverAndStaleHost() throws {
        let clock = CardClock(), animations = CardAnimations()
        let card = controller(clock: clock, animations: animations)
        defer { card.hide(); clock.finish() }
        let shot = try capture()
        card.show(capture: shot); animations.completeEntrance()
        let old = try #require(card.entries.first)
        old.host.onPause?(.hover, true); old.host.onPause?(.dragging, true)
        let outside = CGPoint(x: old.window.frame.minX - 30, y: old.window.frame.minY - 30)
        old.host.reconcileHover(at: outside)
        #expect(!old.dwell.pauses.contains(.hover))
        #expect(old.dwell.pauses.contains(.dragging))
        #expect(old.dwell.deadline == nil)
        old.host.onPause?(.dragging, false)
        #expect(old.dwell.deadline == 5)
        let inside = CGPoint(x: old.window.frame.midX, y: old.window.frame.midY)
        old.host.reconcileHover(at: inside)
        #expect(old.dwell.pauses.contains(.hover))
        card.hide()
        card.show(capture: shot); animations.completeEntrance()
        let replacement = try #require(card.entries.first)
        old.host.reconcileHover(at: inside)
        #expect(replacement.dwell.pauses.isEmpty)
        #expect(!old.model.isAlive)
    }
    @Test("short displays keep only the fixed cards that fit, including error and busy states")
    func shortDisplayBusyAndError() async throws {
        let clock = CardClock(), animations = CardAnimations()
        var continuation: CheckedContinuation<Void, Never>?
        var busyStarted = false
        var operations = ScreenshotCardModel.Operations()
        operations.copy = { _, _, _ in
            busyStarted = true
            await withCheckedContinuation { continuation = $0 }
            return true
        }
        let board = NSPasteboard(name: .init("camcord.card-layout." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let card = controller(clock: clock, animations: animations, visible: CGRect(x: -600, y: 0, width: 600, height: 500), operations: operations)
        defer { card.hide(); clock.finish() }
        for _ in 0..<3 { card.show(capture: try capture()); animations.completeEntrance() }
        let oldest = try #require(card.entries.first)
        oldest.model.error = "A temporary fixture failure wraps to two lines in the actual card."
        let copy = Task { await oldest.model.copy(to: board) }
        while !busyStarted { await Task.yield() }
        await settle()
        #expect(oldest.model.isBusy)
        #expect(card.entries.count == 2)
        #expect(ScreenshotPreviewCard.capacity(for: CGRect(x: -600, y: 0, width: 600, height: 500)) == 2)
        for entry in card.entries {
            #expect(entry.host.measuredHeight <= entry.window.frame.height - 24 + 0.5)
            #expect(entry.window.frame.maxY <= 500)
        }
        #expect(oldest.model.isAlive)
        continuation?.resume()
        #expect(await copy.value)
        #expect(!oldest.model.isBusy)
    }
    @Test("a swipe dismisses on real rightward distance or velocity, with horizontal dominance")
    func flingCriteria() {
        #expect(ScreenshotCardSwipe.commits(translation: CGPoint(x: 60, y: 0), velocity: .zero))
        #expect(ScreenshotCardSwipe.commits(translation: CGPoint(x: 12, y: 2), velocity: CGPoint(x: 600, y: 0)))
        #expect(!ScreenshotCardSwipe.commits(translation: CGPoint(x: 11, y: 0), velocity: CGPoint(x: 900, y: 0)))
        #expect(!ScreenshotCardSwipe.commits(translation: CGPoint(x: 90, y: 70), velocity: CGPoint(x: 900, y: 0)))
        #expect(!ScreenshotCardSwipe.commits(translation: CGPoint(x: -100, y: 0), velocity: CGPoint(x: -900, y: 0)))
    }
    @Test("native image short-click opens the preview without starting a file drag")
    func nativeImageClick() throws {
        let view = ScreenshotCardImageView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var opens = 0, pauses = 0
        view.open = { opens += 1 }; view.pause = { _ in pauses += 1 }
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0.1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        view.mouseDown(with: down); view.mouseUp(with: up)
        #expect(opens == 1)
        #expect(pauses == 0)
        #expect(view.accessibilityPerformPress())
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0.2,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        view.keyDown(with: key)
        #expect(opens == 3)
        view.canInteract = { false }
        view.mouseDown(with: down); view.mouseUp(with: up); view.keyDown(with: key)
        #expect(!view.accessibilityPerformPress())
        #expect(opens == 3)
        #expect(pauses == 0)
    }
    @Test("a rightward drag on the capture swipes the card; other directions never swipe")
    func captureSwipe() throws {
        let view = ScreenshotCardImageView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        var swipes: [(translation: CGPoint, ended: Bool)] = [], opens = 0
        view.open = { opens += 1 }
        view.swipe = { translation, _, ended, _ in swipes.append((translation, ended)) }
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, _ time: TimeInterval) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: time,
                                            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, 50, 50, 0))
        view.mouseDragged(with: try event(.leftMouseDragged, 70, 52, 0.02))
        view.mouseDragged(with: try event(.leftMouseDragged, 120, 54, 0.04))
        view.mouseUp(with: try event(.leftMouseUp, 120, 54, 0.05))
        #expect(swipes.count == 3 && swipes.last?.ended == true && swipes.last?.translation.x == 70)
        #expect(opens == 0)
        swipes.removeAll()
        // Leftward is the file drag (no export here, so no session starts) and never a swipe.
        view.mouseDown(with: try event(.leftMouseDown, 120, 50, 1))
        view.mouseDragged(with: try event(.leftMouseDragged, 90, 50, 1.02))
        view.mouseUp(with: try event(.leftMouseUp, 90, 50, 1.03))
        #expect(swipes.isEmpty && opens == 0)
    }
    @Test("the card offers Copy and Add to Library only for what the capture did not do", arguments: [true, false], [true, false])
    func destinationActions(copied: Bool, kept: Bool) throws {
        let host = ScreenshotCardPresentation(model: ScreenshotCardModel(capture: try capture()), copied: copied, kept: kept, canEdit: true)
        defer { host.invalidate() }
        let titles = host.well.band.actions.map(\.title)
        #expect(titles.contains(String(localized: "Copy")) == !copied)
        #expect(titles.contains(String(localized: "Add to Library")) == !kept)
        #expect(Array(titles.suffix(3)) == [String(localized: "Edit"), String(localized: "Preview"), String(localized: "Share")])
    }
    @Test("real picker cancellation and service success/failure release only their own sharing pause")
    func sharingLifecycle() throws {
        let model = ScreenshotCardModel(capture: try capture())
        var transitions: [(ScreenshotCardDwell.Pause, Bool)] = [], shown = 0
        let coordinator = ScreenshotCardShare(model: model, pause: { transitions.append(($0, $1)) }, present: { _, _ in shown += 1 })
        let button = NSButton()
        coordinator.share(button)
        let picker = try #require(coordinator.picker)
        #expect(shown == 1)
        #expect(transitions.map { $0.1 } == [true])
        coordinator.share(button)
        #expect(shown == 1)
        coordinator.sharingServicePicker(picker, didChoose: nil)
        #expect(transitions.map { $0.1 } == [true, false])
        coordinator.sharingServicePicker(picker, didChoose: nil)
        #expect(transitions.count == 2)
        coordinator.share(button)
        let second = try #require(coordinator.picker)
        let service = NSSharingService(title: "Test service", image: NSImage(size: CGSize(width: 16, height: 16)), alternateImage: nil, handler: {})
        coordinator.sharingServicePicker(second, didChoose: service)
        #expect(transitions.last?.1 == true)
        coordinator.sharingService(service, didShareItems: [])
        #expect(transitions.last?.1 == false)
        coordinator.share(button)
        let third = try #require(coordinator.picker)
        coordinator.sharingServicePicker(third, didChoose: service)
        model.invalidate()
        coordinator.sharingService(service, didFailToShareItems: [], error: CocoaError(.fileReadUnknown))
        #expect(model.error == nil)
        #expect(transitions.map { $0.1 } == [true, false, true, false, true, false])
        coordinator.close()
        #expect(transitions.count == 6)
    }
    @Test("Reduce Motion uses an actual opacity animation and its completion tears down the owned window")
    func reducedMotionTeardown() async throws {
        _ = NSApplication.shared
        let clock = CardClock()
        let card = ScreenshotPreviewCard(presenter: { _ in }, screenFrame: { CGRect(x: 0, y: 0, width: 600, height: 600) }, hostFactory: { frame in
            NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        }, timing: .init(now: { clock.now }, sleep: { try await clock.sleep($0) }), enabled: { true }, reduceMotion: { true })
        defer { card.hide(); clock.finish() }
        card.show(capture: try capture())
        let entry = try #require(card.entries.first)
        #expect(entry.host.animationDuration == Theme.Motion.Duration.reduced)
        try await Task.sleep(for: .milliseconds(230))
        card.hide()
        #expect(entry.orderedOutAt != nil)
        #expect(!entry.window.isVisible)
        #expect(card.entries.isEmpty)
    }
    private func settle() async { for _ in 0..<20 { await Task.yield() } }
}

@MainActor private final class CardClock {
    var now: TimeInterval = 0
    private var sleepers: [(TimeInterval, CheckedContinuation<Void, Never>)] = []
    func sleep(_ interval: TimeInterval) async throws {
        await withCheckedContinuation { sleepers.append((now + interval, $0)) }
        try Task.checkCancellation()
    }
    func advance(to value: TimeInterval) {
        now = value
        let ready = sleepers.filter { $0.0 <= value }
        sleepers.removeAll { $0.0 <= value }
        for item in ready { item.1.resume() }
    }
    func finish() { let old = sleepers; sleepers.removeAll(); for item in old { item.1.resume() } }
}
@MainActor private final class CardAnimations {
    struct Pending { let host: ScreenshotCardPresentation; let entering: Bool; let completion: @MainActor () -> Void }
    var pending: [Pending] = []
    func completeEntrance() { if let index = pending.firstIndex(where: \.entering) { pending.remove(at: index).completion() } }
    func completeExit() { if let index = pending.firstIndex(where: { !$0.entering }) { pending.remove(at: index).completion() } }
}

/// Root-owned evidence only. This fixture never creates a panel, captures a display,
/// changes activation, or publishes to the owner's pasteboard.
@Suite("Screenshot card owned window", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CAMCORD_CARD_INTERACTION"] == "1"))
@MainActor struct ScreenshotCardInteractionWindowTests {
    @Test("Actual card lifecycle in a normal owned window")
    func windowFixture() async throws {
        let env = ProcessInfo.processInfo.environment
        let sentinel = URL(fileURLWithPath: try #require(env["CAMCORD_CARD_GUI_SENTINEL"]))
        let output = URL(fileURLWithPath: try #require(env["CAMCORD_CARD_OUTPUT"]), isDirectory: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: sentinel.path), output.path == LibraryFiles.physicalPath(output),
              output.path != repo.path, !output.path.hasPrefix(repo.path + "/"),
              (try output.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
              try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty else { throw LibraryFiles.Failure.unsafePath }
        _ = NSApplication.shared
        #expect(!NSApp.isActive)
        let initialEnvironment = environment()
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        // An owned central testing region; production keeps selecting the actual capture display.
        let fixtureFrame = CGRect(x: visible.midX - 390, y: visible.midY - 260, width: 528, height: min(600, visible.height - 80))
        let board = NSPasteboard(name: .init("camcord.card-fixture." + UUID().uuidString))
        defer { board.releaseGlobally() }
        var operations = ScreenshotCardModel.Operations()
        operations.exports = ScreenshotTemporaryExports(directory: output.appendingPathComponent("exports"))
        operations.copy = { capture, _, mayPublish in
            await EditorClipboardPublisher.copyPNG(capture.image, pointSize: capture.pointSize, to: board, shouldPublish: mayPublish)
        }
        var windows: [NSWindow] = []
        var nativeEnvironmentEvents: [[String: Any]] = []
        let makeWindow: @MainActor (CGRect) -> NSWindow = { frame in
            let before = environment()
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.level = .normal; window.hidesOnDeactivate = false
            window.title = "Camcord owned screenshot card \(windows.count + 1)"
            window.appearance = NSAppearance(named: env["CAMCORD_CARD_APPEARANCE"] == "light" ? .aqua : .darkAqua)
            windows.append(window)
            nativeEnvironmentEvents.append(["action": "create", "windowID": window.windowNumber, "before": before, "after": environment()])
            return window
        }
        let staging = makeWindow(CGRect(x: fixtureFrame.maxX - 264, y: fixtureFrame.minY + 12, width: 264, height: 260))
        staging.backgroundColor = NSColor.windowBackgroundColor
        let beforePresent = environment(); staging.orderFrontRegardless()
        nativeEnvironmentEvents.append(["action": "present-staging", "windowID": staging.windowNumber, "before": beforePresent, "after": environment()])
        var reusedStaging = false
        let controller = ScreenshotPreviewCard(presenter: { window in
            let before = environment(); window.orderFrontRegardless()
            nativeEnvironmentEvents.append(["action": "present", "windowID": window.windowNumber, "before": before, "after": environment()])
        }, screenFrame: { fixtureFrame }, operations: operations, hostFactory: { frame in
            if !reusedStaging { reusedStaging = true; return staging }
            return makeWindow(frame)
        }, enabled: { true })
        var history: [ScreenshotPreviewCard.Entry] = [], edits: [String] = [], pins: [String] = []
        controller.onEdit = { edits.append($0.id.uuidString) }
        controller.onPin = { pins.append($0.id.uuidString) }
        defer {
            let before = environment(); controller.hide()
            for window in windows { window.orderOut(nil); window.close() }
            nativeEnvironmentEvents.append(["action": "close-all", "before": before, "after": environment()])
            let closed: [String: Any] = ["initialEnvironment": initialEnvironment, "finalEnvironment": environment(), "nativeEnvironmentEvents": nativeEnvironmentEvents]
            try? JSONSerialization.data(withJSONObject: closed, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("closed.json"), options: .atomic)
        }
        let image = try neutralCardImage()
        try EditorRendered(image: image, pointSize: CGSize(width: 400, height: 240)).png.write(to: output.appendingPathComponent("source.png"))
        let end = CACurrentMediaTime() + 180
        while CACurrentMediaTime() < end, FileManager.default.fileExists(atPath: sentinel.path),
              !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish").path), !Task.isCancelled {
            let show = output.appendingPathComponent("show")
            if FileManager.default.fileExists(atPath: show.path) {
                let requested = (try? String(contentsOf: show, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
                try FileManager.default.removeItem(at: show)
                for _ in 0..<min(4, max(1, requested)) {
                    controller.show(capture: CapturedScreenshot(id: UUID(), image: image, pointSize: CGSize(width: 400, height: 240), kind: .screenshot, saveToDiskRequested: false))
                    for entry in controller.entries where !history.contains(where: { $0 === entry }) { history.append(entry) }
                }
            }
            let now = CACurrentMediaTime()
            let entries: [[String: Any]] = history.map { entry in
                ["uuid": entry.model.capture.id.uuidString, "generation": entry.generation,
                 "phase": entry.dwell.phase.rawValue, "pauseReasons": entry.dwell.pauses.map(\.rawValue).sorted(),
                 "remaining": entry.dwell.remaining(at: now), "deadline": entry.dwell.deadline as Any? ?? NSNull(),
                 "shownAt": entry.shownAt, "enteredAt": entry.enteredAt as Any? ?? NSNull(), "exitAt": entry.exitAt as Any? ?? NSNull(),
                 "orderedOutAt": entry.orderedOutAt as Any? ?? NSNull(), "dismissReason": entry.dismissReason as Any? ?? NSNull(),
                 "windowID": entry.window.windowNumber, "windowFrame": values(entry.window.frame), "bodyHeight": entry.host.measuredHeight,
                 "visible": entry.window.isVisible, "modelAlive": entry.model.isAlive, "busy": entry.model.isBusy,
                 "error": entry.model.error as Any? ?? NSNull(), "animationDuration": entry.host.animationDuration]
            }
            let metadata: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier), "executablePath": Bundle.main.executableURL?.path ?? "",
                "windowID": staging.windowNumber, "initialEnvironment": initialEnvironment, "currentEnvironment": environment(),
                "nativeEnvironmentEvents": nativeEnvironmentEvents, "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                "monotonicNow": now, "entries": entries, "editCaptureIDs": edits, "pinCaptureIDs": pins,
                "copyPasteboard": board.name.rawValue, "fixtureKind": "ordinary-window; actual production card body/CA/dwell",
                "interactionEvidence": "show is a neutral fixture delivery; use actual CUA/native events for hover, chrome fling, image click, external drag and share cancellation"]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("ready.json"), options: .atomic)
            let inventory: [[String: Any]] = windows.map { ["windowID": $0.windowNumber, "pid": Int(ProcessInfo.processInfo.processIdentifier), "executablePath": Bundle.main.executableURL?.path ?? "", "title": $0.title, "frame": values($0.frame), "visible": $0.isVisible, "key": $0.isKeyWindow, "role": "card"] }
            try JSONSerialization.data(withJSONObject: inventory, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("windows.json"), options: .atomic)
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!NSApp.isActive)
    }
    private func environment() -> [String: Any] {
        let point = NSEvent.mouseLocation
        return ["frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                "frontmostBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                "mouseLocation": [point.x, point.y], "appActive": NSApp.isActive]
    }
    private func values(_ rect: CGRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }
    private func neutralCardImage() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 800, height: 480, bitsPerComponent: 8, bytesPerRow: 3200,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.92, green: 0.94, blue: 0.96, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 800, height: 480))
        context.setFillColor(CGColor(srgbRed: 0.12, green: 0.18, blue: 0.3, alpha: 1)); context.fill(CGRect(x: 32, y: 340, width: 736, height: 108))
        for x in stride(from: 32, to: 736, by: 64) {
            context.setFillColor(x % 128 == 32 ? NSColor.systemBlue.cgColor : NSColor.systemOrange.cgColor)
            context.fill(CGRect(x: x, y: 32, width: 48, height: 276))
        }
        return try #require(context.makeImage())
    }
}

private actor CardPassiveExportCounter {
    private(set) var count = 0
    func record() { count += 1 }
}
