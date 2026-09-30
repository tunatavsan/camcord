import Foundation
import Testing
@testable import Camcord

@Suite("Studio source-picker ownership")
struct StudioSourcePickerTests {
    @Test("a real region chooses its containing current display and clamps cross-display bounds")
    func regionMapping() throws {
        let displays: [StudioPickerDisplay] = [
            .init(id: 22, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), scale: 2),
            .init(id: 11, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 1)
        ]
        let region = try #require(StudioPickerGeometry.resolve(CGRect(x: 900, y: 100, width: 500, height: 200), displays: displays))
        #expect(region.displayID == 22)
        #expect(region.rect == CGRect(x: 1000, y: 100, width: 400, height: 200))
        #expect(StudioPickerGeometry.resolve(CGRect(x: 2100, y: 0, width: 50, height: 50), displays: displays) == nil)
        #expect(StudioPickerGeometry.resolve(CGRect(x: 100, y: 100, width: 100, height: 100), displays: []) == nil)
        #expect(StudioPickerGeometry.resolve(CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20), displays: displays) == nil)
    }

    @Test("raw negative region sizes are rejected instead of selecting their standardized positive area", arguments: [
        CGSize(width: -100, height: 80), CGSize(width: 100, height: -80), CGSize(width: -100, height: -80)
    ])
    func negativeRegionSize(_ size: CGSize) {
        let region = CGRect(origin: CGPoint(x: 300, y: 250), size: size)
        let display = StudioPickerDisplay(id: 11, frame: CGRect(x: 0, y: 0, width: 500, height: 400), scale: 2)
        #expect(region.width > 1 && region.height > 1) // standardized accessors conceal raw negative sizes
        #expect(StudioPickerGeometry.resolve(region, displays: [display]) == nil)
        #expect(StudioPickerGeometry.resolve(region.standardized, displays: [display])?.displayID == 11)
    }

    @Test("raw negative display sizes are excluded even when their standardized area contains the region", arguments: [
        CGRect(x: 500, y: 0, width: -500, height: 400),
        CGRect(x: 0, y: 400, width: 500, height: -400),
        CGRect(x: 500, y: 400, width: -500, height: -400)
    ])
    func negativeDisplaySize(_ frame: CGRect) {
        let region = CGRect(x: 200, y: 100, width: 100, height: 80)
        let invalid = StudioPickerDisplay(id: 11, frame: frame, scale: 2)
        let valid = StudioPickerDisplay(id: 22, frame: frame.standardized, scale: 2)
        #expect(frame.width > 1 && frame.height > 1) // raw dimensions must be checked before RegionClamp
        #expect(StudioPickerGeometry.resolve(region, displays: [invalid]) == nil)
        #expect(StudioPickerGeometry.resolve(region, displays: [invalid, valid])?.displayID == 22)
    }

    @MainActor @Test("the picker survives its own expected hidden step-aside and commits a fresh immutable choice")
    func ownStepAside() async {
        let harness = StudioPickerHarness()
        let picker = StudioSourcePicker(operations: harness.operations())
        let task = Task { @MainActor in await picker.select() }
        await harness.waitForPick()
        #expect(!harness.visible)
        #expect(picker.isSelecting)
        harness.releasePick(.window(77))
        await harness.waitForResolution()
        harness.releaseResolution(.source(harness.choice))
        await task.value
        #expect(harness.applied.count == 1)
        #expect(harness.visible)
        #expect(!picker.isSelecting)
        #expect(picker.issue == nil)
    }

    @MainActor @Test("close or reopen during fresh-content resolution invalidates the old selection")
    func replacedPresentation() async {
        let harness = StudioPickerHarness()
        let picker = StudioSourcePicker(operations: harness.operations())
        let task = Task { @MainActor in await picker.select() }
        await harness.waitForPick()
        harness.releasePick(.window(77))
        await harness.waitForResolution()
        harness.epoch &+= 1 // a separate real presentation event, beyond picker step-aside
        harness.releaseResolution(.source(harness.choice))
        await task.value
        #expect(harness.applied.isEmpty)
        #expect(picker.issue == nil)
    }

    @MainActor @Test("a newer picker intent replaces pending content without an older task clearing the new operation")
    func newestPickerWins() async {
        let harness = StudioPickerHarness()
        let picker = StudioSourcePicker(operations: harness.operations())
        let older = Task { @MainActor in await picker.select() }
        await harness.waitForPick()
        harness.releasePick(.window(77))
        await harness.waitForResolution()
        let newer = Task { @MainActor in await picker.select() }
        await harness.waitForPick()
        harness.releaseResolution(.source(harness.choice))
        await older.value
        #expect(picker.isSelecting)
        #expect(harness.applied.isEmpty)
        harness.releasePick(.window(88))
        await harness.waitForResolution(id: 88)
        let choice = StudioSourceChoice(id: .window(88), title: "Newer fixture", frame: harness.choice.frame, pixelSize: harness.choice.pixelSize)
        harness.releaseResolution(.source(choice), id: 88)
        await newer.value
        #expect(harness.applied.count == 1)
        if let applied = harness.applied.first, case .source(let result) = applied { #expect(result.id == .window(88)) }
        else { Issue.record("The newer selected window was not applied") }
        #expect(!picker.isSelecting)
    }

    @MainActor @Test("module leave cancels owned work even if Studio is selected again before the overlay returns")
    func leaveAndReturn() async {
        let harness = StudioPickerHarness()
        let picker = StudioSourcePicker(operations: harness.operations())
        let task = Task { @MainActor in await picker.select() }
        await harness.waitForPick()
        harness.moduleChange?()
        harness.releasePick(.window(77))
        await task.value
        #expect(harness.applied.isEmpty)
        #expect(!harness.resolutionStarted)
        #expect(picker.issue == nil)
        #expect(!picker.isSelecting)
    }

    @MainActor @Test("another source choice wins over a previously accepted picker")
    func replacementSource() async {
        let harness = StudioPickerHarness()
        let picker = StudioSourcePicker(operations: harness.operations())
        let task = Task { @MainActor in await picker.select() }
        await harness.waitForPick()
        harness.releasePick(.window(77))
        await harness.waitForResolution()
        harness.sourceID = .display(55)
        harness.releaseResolution(.source(harness.choice))
        await task.value
        #expect(harness.applied.isEmpty)
        #expect(picker.issue == nil)
    }

    @MainActor @Test("picker cancellation is silent and does not clear the current source")
    func userCancelled() async {
        let harness = StudioPickerHarness()
        let picker = StudioSourcePicker(operations: harness.operations())
        let task = Task { @MainActor in await picker.select() }
        await harness.waitForPick()
        harness.releasePick(nil)
        await task.value
        #expect(harness.applied.isEmpty)
        #expect(!harness.resolutionStarted)
        #expect(picker.issue == nil)
    }

    @MainActor @Test("a disappearing picked window reports a real unavailable issue without source mutation")
    func disappearingWindow() async {
        let harness = StudioPickerHarness()
        let picker = StudioSourcePicker(operations: harness.operations())
        let task = Task { @MainActor in await picker.select() }
        await harness.waitForPick()
        harness.releasePick(.window(77))
        await harness.waitForResolution()
        harness.rejectResolution(.sourceUnavailable)
        await task.value
        #expect(harness.applied.isEmpty)
        #expect(picker.issue == .sourceUnavailable)
    }
}

@MainActor private final class StudioPickerHarness {
    private let windowIdentity = NSObject() // identity token only; no NSWindow or SCK mock object
    var visible = true
    var epoch: UInt64 = 7
    var sourceID: StudioSourceChoice.ID? = .display(11)
    var moduleChange: (@MainActor () -> Void)?
    var applied: [StudioSourcePicker.Resolved] = []
    var resolutionStarted = false
    let choice = StudioSourceChoice(id: .window(77), title: "Fixture window", frame: CGRect(x: 10, y: 20, width: 640, height: 480), pixelSize: CGSize(width: 1280, height: 960))
    private var pendingPick: CheckedContinuation<StudioSourcePicker.Pick?, Never>?
    private var pickArrival: CheckedContinuation<Void, Never>?
    private var pendingResolutions: [UInt32: CheckedContinuation<StudioSourcePicker.Resolved, Error>] = [:]
    private var resolutionArrivals: [UInt32: CheckedContinuation<Void, Never>] = [:]

    func operations() -> StudioSourcePicker.Operations {
        .init(context: { [self] in
            guard visible else { return nil }
            return .init(windowIdentity: ObjectIdentifier(windowIdentity), presentationEpoch: epoch, sourceID: sourceID, sourceFrame: nil)
        }, observeModuleChange: { [self] in moduleChange = $0 }, stepAside: { [self] work in
            epoch &+= 1
            visible = false
            await work()
            visible = true
        }, choose: { [self] in
            await withCheckedContinuation { pendingPick = $0; pickArrival?.resume(); pickArrival = nil }
        }, resolve: { [self] pick in
            resolutionStarted = true
            let id: UInt32
            switch pick { case .window(let windowID): id = windowID; case .region: id = 0 }
            return try await withCheckedThrowingContinuation { pendingResolutions[id] = $0; resolutionArrivals.removeValue(forKey: id)?.resume() }
        }, apply: { [self] in applied.append($0) })
    }
    func waitForPick() async {
        if pendingPick != nil { return }
        await withCheckedContinuation { pickArrival = $0 }
    }
    func releasePick(_ pick: StudioSourcePicker.Pick?) { pendingPick?.resume(returning: pick); pendingPick = nil }
    func waitForResolution(id: UInt32 = 77) async {
        if pendingResolutions[id] != nil { return }
        await withCheckedContinuation { resolutionArrivals[id] = $0 }
    }
    func releaseResolution(_ resolved: StudioSourcePicker.Resolved, id: UInt32 = 77) { pendingResolutions.removeValue(forKey: id)?.resume(returning: resolved) }
    func rejectResolution(_ issue: StudioIssue, id: UInt32 = 77) { pendingResolutions.removeValue(forKey: id)?.resume(throwing: issue) }
}
