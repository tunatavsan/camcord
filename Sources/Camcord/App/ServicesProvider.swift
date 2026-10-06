import AppKit

/// Backs the macOS **Services** entry "Extract Text with Camcord":
/// select an image file in Finder (or an image in any app) → Services → this runs OCR on it and
/// copies the text. Registered via `NSApp.servicesProvider`; the matching `NSServices` entry
/// lives in Info.plist. A discoverable in-app "Extract Text from Image…" menu item does the
/// same for anyone who doesn't reach for the Services menu.
@MainActor
final class ServicesProvider: NSObject {
    private let coordinator: CaptureCoordinator

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp",
    ]

    init(coordinator: CaptureCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    /// Selector `extractText:userData:error:` (NSMessage = "extractText"). Reads an image
    /// off the service pasteboard — a file URL from Finder, or raw image data pasted from
    /// an app — OCRs it, and copies the recognized text to the general clipboard.
    @objc func extractText(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            let imageURL = urls.first(where: { Self.imageExtensions.contains($0.pathExtension.lowercased()) }) {
            coordinator.captureTextFromImageFile(imageURL)
            return
        }
        if let image = NSImage(pasteboard: pasteboard),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            coordinator.captureTextFromImage(cgImage)
            return
        }
        error?.pointee = String(localized: "Camcord: no image found in the selection.",
                                 comment: "Services menu error: the selection holds no image") as NSString
    }
}
