import Foundation

/// The sole native routing owner. Library always receives every event; the card matches its
/// own immutable UUID. A bounded early-save buffer handles disk completion before .ready.
@MainActor final class ScreenshotDeliveryFanout {
    static let earlySaveLimit = 16
    private let ingest: @MainActor (ScreenshotDeliveryEvent) -> Void
    private let ready: @MainActor (CapturedScreenshot) -> Void
    private let saved: @MainActor (UUID, URL) -> Void
    private let saveFailed: @MainActor (CapturedScreenshot) -> Void
    private var displayedID: UUID?
    private var earlySaved: [UUID: URL] = [:]
    private var earlyOrder: [UUID] = []
    var pendingSaveCount: Int { earlySaved.count }
    init(ingest: @escaping @MainActor (ScreenshotDeliveryEvent) -> Void,
         ready: @escaping @MainActor (CapturedScreenshot) -> Void,
         saved: @escaping @MainActor (UUID, URL) -> Void,
         saveFailed: @escaping @MainActor (CapturedScreenshot) -> Void) {
        self.ingest = ingest; self.ready = ready; self.saved = saved; self.saveFailed = saveFailed
    }
    func receive(_ event: ScreenshotDeliveryEvent) {
        ingest(event)
        switch event {
        case .ready(let capture):
            displayedID = capture.id
            ready(capture)
            if let url = removeEarlySave(capture.id) { saved(capture.id, url) }
        case .saved(let capture, let url):
            if displayedID != capture.id {
                if earlySaved[capture.id] == nil { earlyOrder.append(capture.id) }
                earlySaved[capture.id] = url
                while earlyOrder.count > Self.earlySaveLimit {
                    earlySaved.removeValue(forKey: earlyOrder.removeFirst())
                }
            }
            saved(capture.id, url)
        case .saveFailed(let capture):
            _ = removeEarlySave(capture.id)
            saveFailed(capture)
        }
    }
    private func removeEarlySave(_ id: UUID) -> URL? {
        earlyOrder.removeAll { $0 == id }
        return earlySaved.removeValue(forKey: id)
    }
}
