import CoreGraphics
import Foundation
import Testing
import os

@testable import Camcord

@MainActor
@Suite("Capture publication ownership")
struct CapturePublicationTests {
    @MainActor private final class PendingCapture {
        var continuation: CheckedContinuation<(image: CGImage, pointSize: CGSize), Never>?
        func capture() async -> (image: CGImage, pointSize: CGSize) {
            await withCheckedContinuation { continuation = $0 }
        }
    }

    @MainActor private final class PendingPNG {
        var continuation: CheckedContinuation<Bool, Never>?
        var shouldPublish: (@MainActor () -> Bool)?
        var initiallyPublished = false
        var onSave: (@MainActor (Result<URL, Error>) -> Void)?
        func copy(shouldPublish: @escaping @MainActor () -> Bool,
                  onSave: @escaping @MainActor (Result<URL, Error>) -> Void) async -> Bool {
            initiallyPublished = shouldPublish()
            self.shouldPublish = shouldPublish
            self.onSave = onSave
            return await withCheckedContinuation { continuation = $0 }
        }
    }
    @MainActor private final class PendingOCR {
        var continuation: CheckedContinuation<String, Never>?
        var completed = false
        func recognize() async -> String {
            let text = await withCheckedContinuation { continuation = $0 }
            completed = true
            return text
        }
    }
    enum DiskFailure: Error { case unavailable }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    private func image() -> CGImage {
        let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    @Test("newly accepted OCR supersedes an older screenshot before capture resolves")
    func acceptedRequestBeatsCompletionOrder() async {
        let pending = PendingCapture()
        var pngPublications = 0
        var textPublications: [String] = []
        var operations = CaptureCoordinator.Operations()
        operations.feedback = false
        operations.screenCaptureAuthorized = { true }
        operations.screenshotSettings = { ScreenshotSettings() }
        operations.fullScreen = { await pending.capture() }
        operations.recognize = { _ in "new text" }
        operations.publishText = { textPublications.append($0); return true }
        operations.copyPNG = { _, _, _, shouldPublish, _ in
            if shouldPublish() { pngPublications += 1; return true }
            return false
        }
        let coordinator = CaptureCoordinator(operations: operations)
        let older = Task { await coordinator.captureFullScreen() }
        await waitUntil { pending.continuation != nil }
        coordinator.captureTextFromImage(image())
        await waitUntil { !textPublications.isEmpty }
        #expect(textPublications == ["new text"])
        pending.continuation?.resume(returning: (image(), CGSize(width: 4, height: 3)))
        await older.value
        #expect(pngPublications == 0)
    }
    @Test("typed delivery freezes one identity, point size, kind and disk setting in either event order",
          arguments: [false, true])
    func stableDeliveryIdentity(savedBeforeReady: Bool) async throws {
        let pixels = image()
        let size = CGSize(width: 4, height: 3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        var settings = ScreenshotSettings(saveToDisk: true)
        var loads = 0
        var receivedSettings: ScreenshotSettings?
        var onSave: (@MainActor (Result<URL, Error>) -> Void)?
        var events: [ScreenshotDeliveryEvent] = []
        var operations = CaptureCoordinator.Operations()
        operations.feedback = false
        operations.screenshotSettings = { loads += 1; return settings }
        operations.copyPNG = { _, _, snapshot, publish, callback in
            receivedSettings = snapshot
            settings.saveToDisk = false
            onSave = callback
            if savedBeforeReady { callback(.success(url)) }
            return publish()
        }
        let coordinator = CaptureCoordinator(operations: operations)
        coordinator.onScreenshotDelivery = { events.append($0) }
        #expect(await coordinator.deliverScreenshotForTesting(pixels, pointSize: size, originDisplayID: 71) == true)
        if !savedBeforeReady { onSave?(.success(url)) }
        #expect(loads == 1 && receivedSettings?.saveToDisk == true)
        #expect(events.count == 2)
        let deliveries = events.map { event -> CapturedScreenshot in
            switch event {
            case .ready(let value), .saved(let value, _), .saveFailed(let value): return value
            }
        }
        #expect(Set(deliveries.map(\.id)).count == 1)
        #expect(deliveries.allSatisfy { $0.pointSize == size && $0.kind == .screenshot && $0.saveToDiskRequested })
        #expect(deliveries.allSatisfy { $0.image === pixels })
        #expect(deliveries.allSatisfy { $0.originDisplayID == 71 })
        if savedBeforeReady {
            guard case .saved(_, let savedURL) = events.first else { Issue.record("Save may finish before ready"); return }
            #expect(savedURL == url)
        } else {
            guard case .ready = events.first else { Issue.record("Ready may finish before save"); return }
        }
    }

    @Test("late accepted disk delivery survives stale clipboard ownership; stale ready never publishes",
          arguments: [false, true])
    func staleDiskDelivery(saveFails: Bool) async {
        let pending = PendingPNG()
        var textPublications: [String] = []
        var events: [ScreenshotDeliveryEvent] = []
        var operations = CaptureCoordinator.Operations()
        operations.feedback = false
        operations.screenshotSettings = { ScreenshotSettings(saveToDisk: true) }
        operations.copyPNG = { _, _, _, publish, callback in await pending.copy(shouldPublish: publish, onSave: callback) }
        operations.recognize = { _ in "new text" }
        operations.publishText = { textPublications.append($0); return true }
        let coordinator = CaptureCoordinator(operations: operations)
        coordinator.onScreenshotDelivery = { events.append($0) }
        let older = Task { await coordinator.deliverScreenshotForTesting(image(), pointSize: CGSize(width: 4, height: 3), originDisplayID: 81) }
        await waitUntil { pending.continuation != nil }
        coordinator.captureTextFromImage(image())
        await waitUntil { !textPublications.isEmpty }
        let allowed = pending.shouldPublish?() ?? true
        #expect(!allowed)
        #expect(pending.initiallyPublished)
        // The old clipboard write succeeded before a newer claim; its async return can
        // still arrive later. Ready belongs only to the currently accepted request.
        pending.continuation?.resume(returning: true)
        #expect(await older.value == nil)
        #expect(events.isEmpty)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        pending.onSave?(saveFails ? .failure(DiskFailure.unavailable) : .success(url))
        #expect(events.count == 1)
        switch events.first {
        case .saved(let value, let savedURL):
            #expect(!saveFails && savedURL == url && value.saveToDiskRequested && value.pointSize == CGSize(width: 4, height: 3))
            #expect(value.originDisplayID == 81)
        case .saveFailed(let value): #expect(saveFails && value.saveToDiskRequested && value.originDisplayID == 81)
        default: Issue.record("Actual disk outcome must be reported even after supersession")
        }
    }

    @Test("scroll delivery carries explicit kind and tags its accepted saved file")
    func scrollSavedKind() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var events: [ScreenshotDeliveryEvent] = []
        var operations = CaptureCoordinator.Operations()
        operations.feedback = false
        operations.screenshotSettings = { ScreenshotSettings(saveToDisk: true) }
        operations.copyPNG = { _, _, _, publish, callback in callback(.success(url)); return publish() }
        let coordinator = CaptureCoordinator(operations: operations)
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.onScreenshotDelivery = { events.append($0) }
        #expect(await coordinator.deliverScreenshotForTesting(image(), pointSize: CGSize(width: 4, height: 3), kind: .scrollCapture, originDisplayID: 91) == true)
        await waitUntil { events.count == 2 }
        let values = events.map { event -> CapturedScreenshot in
            switch event { case .ready(let value), .saved(let value, _), .saveFailed(let value): return value }
        }
        #expect(values.allSatisfy { $0.kind == .scrollCapture })
        #expect(values.allSatisfy { $0.originDisplayID == 91 })
        #expect(Set(values.map(\.id)).count == 1)
        #expect(CaptureFileRules.kind(of: url, tag: CaptureFileRules.readTag(url)) == .scrollCapture)
    }

    @Test("cancelled newer capture keeps its accepted clipboard claim and cannot resurrect older OCR")
    func cancelledRequestStillSupersedes() async {
        let oldOCR = PendingOCR()
        let newCapture = PendingCapture()
        var pngPublications = 0
        var textPublications = 0
        var recognitionFinished = false
        var operations = CaptureCoordinator.Operations()
        operations.feedback = false
        operations.screenCaptureAuthorized = { true }
        operations.screenshotSettings = { ScreenshotSettings() }
        operations.recognitionFinished = { recognitionFinished = true }
        operations.recognize = { _ in await oldOCR.recognize() }
        operations.fullScreen = { await newCapture.capture() }
        operations.publishText = { _ in textPublications += 1; return true }
        operations.copyPNG = { _, _, _, publish, _ in if publish() { pngPublications += 1 }; return publish() }
        let coordinator = CaptureCoordinator(operations: operations)
        coordinator.captureTextFromImage(image())
        await waitUntil { oldOCR.continuation != nil }
        let newer = Task { await coordinator.captureFullScreen() }
        await waitUntil { newCapture.continuation != nil }
        newer.cancel()
        oldOCR.continuation?.resume(returning: "old text")
        await waitUntil { recognitionFinished }
        #expect(textPublications == 0)
        newCapture.continuation?.resume(returning: (image(), CGSize(width: 4, height: 3)))
        await newer.value
        #expect(pngPublications == 0 && textPublications == 0)
    }

    @Test("actual disk failure and successful ready retain the same accepted identity")
    func failedSaveIdentity() async {
        var events: [ScreenshotDeliveryEvent] = []
        var operations = CaptureCoordinator.Operations()
        operations.feedback = false
        operations.screenshotSettings = { ScreenshotSettings(saveToDisk: true) }
        operations.copyPNG = { _, _, _, publish, callback in callback(.failure(DiskFailure.unavailable)); return publish() }
        let coordinator = CaptureCoordinator(operations: operations)
        coordinator.onScreenshotDelivery = { events.append($0) }
        #expect(await coordinator.deliverScreenshotForTesting(image(), pointSize: CGSize(width: 4, height: 3), originDisplayID: 101) == true)
        #expect(events.count == 2)
        guard case .saveFailed(let failed) = events.first, case .ready(let ready) = events.last else {
            Issue.record("Only actual failure emits saveFailed, followed by successful ready"); return
        }
        #expect(failed.id == ready.id && failed.saveToDiskRequested && ready.saveToDiskRequested)
        #expect(failed.originDisplayID == 101 && ready.originDisplayID == 101)
    }

    @Test("fullscreen freezes its selected display before capture suspension and retains it across cursor changes or hotplug",
          arguments: [false, true])
    func fullScreenOriginIsRequestScoped(hotplug: Bool) async throws {
        let pending = PendingCapture()
        var selectedDisplayID: CGDirectDisplayID? = 17
        var displaySelections = 0
        var onSave: (@MainActor (Result<URL, Error>) -> Void)?
        var events: [ScreenshotDeliveryEvent] = []
        var operations = CaptureCoordinator.Operations()
        operations.feedback = false
        operations.screenCaptureAuthorized = { true }
        operations.screenshotSettings = { ScreenshotSettings(saveToDisk: true) }
        operations.fullScreenDisplayID = { displaySelections += 1; return selectedDisplayID }
        operations.fullScreen = { await pending.capture() }
        operations.copyPNG = { _, _, _, publish, callback in onSave = callback; return publish() }
        let coordinator = CaptureCoordinator(operations: operations)
        coordinator.onScreenshotDelivery = { events.append($0) }
        let first = Task { await coordinator.captureFullScreen() }
        await waitUntil { pending.continuation != nil }
        #expect(displaySelections == 1)
        selectedDisplayID = hotplug ? nil : 29
        pending.continuation?.resume(returning: (image(), CGSize(width: 4, height: 3)))
        pending.continuation = nil
        await first.value
        onSave?(.success(URL(fileURLWithPath: "/private/origin-fixture.png")))
        #expect(events.count == 2 && displaySelections == 1)
        guard case .ready(let ready) = events.first, case .saved(let saved, _) = events.last else {
            Issue.record("The captured request must emit ready and its actual disk result"); return
        }
        #expect(ready.id == saved.id && ready.originDisplayID == 17 && saved.originDisplayID == 17)

        let second = Task { await coordinator.captureFullScreen() }
        await waitUntil { pending.continuation != nil }
        pending.continuation?.resume(returning: (image(), CGSize(width: 4, height: 3)))
        await second.value
        guard case .ready(let next) = events.last else { Issue.record("The next request must publish independently"); return }
        #expect(displaySelections == 2 && next.id != ready.id)
        #expect(next.originDisplayID == selectedDisplayID)
    }

    @Test("a Library-only screenshot is delivered without publishing to the clipboard")
    func libraryOnlyDelivery() async throws {
        let pending = PendingCapture()
        var published: [Bool] = []
        var events: [ScreenshotDeliveryEvent] = []
        var operations = CaptureCoordinator.Operations()
        operations.feedback = false
        operations.screenCaptureAuthorized = { true }
        operations.screenshotSettings = { ScreenshotSettings(copyToClipboard: false) }
        operations.fullScreenDisplayID = { 17 }
        operations.fullScreen = { await pending.capture() }
        operations.copyPNG = { _, _, _, publish, _ in let allowed = publish(); published.append(allowed); return allowed }
        let coordinator = CaptureCoordinator(operations: operations)
        coordinator.onScreenshotDelivery = { events.append($0) }
        let capture = Task { await coordinator.captureFullScreen() }
        await waitUntil { pending.continuation != nil }
        pending.continuation?.resume(returning: (image(), CGSize(width: 4, height: 3)))
        pending.continuation = nil
        await capture.value
        #expect(published == [false])
        guard case .ready(let ready) = events.first else { Issue.record("A Library-only capture must still be delivered"); return }
        #expect(!ready.copiedToClipboard && events.count == 1)
    }

    @Test("source rectangles choose the largest CG intersection including displays left of or above the primary screen")
    func originBySourceIntersection() {
        let displays: [(id: CGDirectDisplayID, frame: CGRect)] = [
            (30, CGRect(x: -1600, y: 0, width: 1600, height: 1000)),
            (20, CGRect(x: 0, y: 0, width: 1200, height: 1000)),
            (10, CGRect(x: 0, y: -900, width: 1200, height: 900)),
        ]
        #expect(CaptureCoordinator.originDisplayID(for: CGRect(x: -500, y: 200, width: 800, height: 200), displays: displays) == 30)
        #expect(CaptureCoordinator.originDisplayID(for: CGRect(x: 100, y: -600, width: 200, height: 700), displays: displays) == 10)
        let tied = CGRect(x: -200, y: 200, width: 400, height: 100)
        #expect(CaptureCoordinator.originDisplayID(for: tied, displays: displays) == 20)
        #expect(CaptureCoordinator.originDisplayID(for: tied, displays: Array(displays.reversed())) == 20)
        #expect(CaptureCoordinator.originDisplayID(for: CGRect(x: 2000, y: 2000, width: 10, height: 10), displays: displays) == nil)
        #expect(CaptureCoordinator.originDisplayID(for: .zero, displays: displays) == nil)
        #expect(CaptureCoordinator.originDisplayID(for: .null, displays: displays) == nil)
        #expect(CaptureCoordinator.originDisplayID(for: .infinite, displays: displays) == nil)
    }

    @Test("1× scroll raster planning bounds wide, tall and overflowing inputs before allocation")
    func oneXPixelBudget() throws {
        #expect(CaptureCoordinator.boundedScrollRasterSize(CGSize(width: 40, height: 120)) == CGSize(width: 40, height: 120))
        for size in [CGSize(width: 7680, height: 40_000), CGSize(width: 1, height: 100_000_000),
                     CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)] {
            let pixels = try #require(CaptureCoordinator.boundedScrollRasterSize(size))
            #expect(pixels.width >= 1 && pixels.height >= 1)
            #expect(pixels.width * pixels.height <= 50_000_000)
        }
        let tiny = try #require(CaptureCoordinator.boundedScrollRasterSize(CGSize(width: 40, height: 120), maximumPixels: 101))
        #expect(tiny.width * tiny.height <= 101)
        #expect(CaptureCoordinator.boundedScrollRasterSize(CGSize(width: CGFloat.infinity, height: 1)) == nil)
    }

    @Test("a rejected scroll tag keeps the accepted saved file and warns once without a false disk failure")
    func scrollTagFailureKeepsSavedFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let tags = OSAllocatedUnfairLock(initialState: (calls: 0, onMain: false, urls: [URL]()))
        var events: [ScreenshotDeliveryEvent] = []
        var warnings: [ToastRequest] = []
        var operations = CaptureCoordinator.Operations()
        operations.feedback = false
        operations.screenshotSettings = { ScreenshotSettings(saveToDisk: true) }
        operations.copyPNG = { _, _, _, publish, callback in callback(.success(url)); return publish() }
        operations.tagScrollCapture = { url in
            tags.withLock { $0.calls += 1; $0.onMain = $0.onMain || Thread.isMainThread; $0.urls.append(url) }
            return false
        }
        let coordinator = CaptureCoordinator(operations: operations)
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.onScreenshotDelivery = { events.append($0) }
        coordinator.onToast = { warnings.append($0) }
        #expect(await coordinator.deliverScreenshotForTesting(image(), pointSize: CGSize(width: 4, height: 3), kind: .scrollCapture) == true)
        await waitUntil { events.count == 2 }
        let saved = events.compactMap { event -> CapturedScreenshot? in
            if case .saved(let value, let savedURL) = event { #expect(savedURL == url); return value }
            return nil
        }
        #expect(saved.count == 1 && saved.first?.kind == .scrollCapture)
        #expect(!events.contains { if case .saveFailed = $0 { return true }; return false })
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(tags.withLock { $0.calls == 1 && !$0.onMain && $0.urls == [url] })
        #expect(warnings.count == 1 && warnings.first?.important == true)
        #expect(warnings.first?.text == String(localized: "Scroll capture saved, but its capture type could not be recorded"))
    }

}
