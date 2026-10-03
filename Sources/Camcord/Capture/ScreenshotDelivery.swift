import CoreGraphics
import Foundation

/// One accepted screenshot keeps its identity and physical size through clipboard and
/// asynchronous disk delivery. Saving may complete before the initial clipboard event.
struct CapturedScreenshot: Sendable {
    let id: UUID
    let image: CGImage
    let pointSize: CGSize
    let kind: CaptureItem.Kind
    let saveToDiskRequested: Bool
    /// The display selected by this capture, independent of later cursor or display changes.
    /// Older callers and imported images may not have a live display identity.
    let originDisplayID: CGDirectDisplayID?
    /// False when the owner chose to keep screenshots in the Library only.
    let copiedToClipboard: Bool

    init(id: UUID, image: CGImage, pointSize: CGSize, kind: CaptureItem.Kind,
         saveToDiskRequested: Bool, originDisplayID: CGDirectDisplayID? = nil, copiedToClipboard: Bool = true) {
        self.id = id
        self.copiedToClipboard = copiedToClipboard
        self.image = image
        self.pointSize = pointSize
        self.kind = kind
        self.saveToDiskRequested = saveToDiskRequested
        self.originDisplayID = originDisplayID
    }
}

enum ScreenshotDeliveryEvent: Sendable {
    case ready(CapturedScreenshot)
    case saved(CapturedScreenshot, URL)
    case saveFailed(CapturedScreenshot)
}
