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
}

enum ScreenshotDeliveryEvent: Sendable {
    case ready(CapturedScreenshot)
    case saved(CapturedScreenshot, URL)
    case saveFailed(CapturedScreenshot)
}
