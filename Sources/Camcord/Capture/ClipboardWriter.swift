import AppKit
import CoreGraphics
import os

/// Encodes a captured `CGImage` as PNG and writes it to the pasteboard.
///
/// The PNG encode (the expensive part) runs off the main actor in a detached task;
/// `NSPasteboard` is not `Sendable`, so the clear+write must happen on the caller's
/// own actor (`@MainActor` here) using the already-encoded, `Sendable` `Data`.
@MainActor
enum ClipboardWriter {
    private static let logger = Logger(subsystem: "dev.tavsan.camcord", category: "clipboard")

    /// Encodes `image` as PNG and copies it to `pasteboard` (defaults to the general
    /// pasteboard; tests pass a named pasteboard so they never touch the real clipboard).
    /// Uses `NSBitmapImageRep` -> `.png` representation, not `writeObjects`/TIFF (slower encode path).
    ///
    /// `pointSize` is the capture's on-screen size in POINTS. Without it the PNG is
    /// tagged 72 dpi (point size == pixel size), so a Retina capture pastes at 2x its
    /// physical size in DPI-aware apps. Passing the point size embeds the real density.
    static func copyPNG(_ image: CGImage, pointSize: CGSize? = nil, to pasteboard: NSPasteboard = .general) async -> Bool {
        guard let png = await Task.detached(priority: .userInitiated, operation: {
            encodePNG(image, pointSize: pointSize)
        }).value else {
            logger.error("Failed to encode captured image as PNG")
            return false
        }
        pasteboard.clearContents()
        return pasteboard.setData(png, forType: .png)
    }

    nonisolated private static func encodePNG(_ image: CGImage, pointSize: CGSize?) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        if let pointSize, pointSize.width > 0, pointSize.height > 0 {
            rep.size = pointSize
        }
        return rep.representation(using: .png, properties: [:])
    }
}
