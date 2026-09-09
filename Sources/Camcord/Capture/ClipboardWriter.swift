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

    private static var pendingWrites: [UUID: Task<Void, Never>] = [:]
    static var isSaving: Bool { !pendingWrites.isEmpty }

    static func waitForPendingSaves() async {
        for task in Array(pendingWrites.values) { await task.value }
    }

    /// Encodes `image` as PNG and copies it to `pasteboard` (defaults to the general
    /// pasteboard; tests pass a named pasteboard so they never touch the real clipboard).
    /// Uses `NSBitmapImageRep` -> `.png` representation, not `writeObjects`/TIFF (slower encode path).
    ///
    /// `pointSize` is the capture's on-screen size in POINTS. Without it the PNG is
    /// tagged 72 dpi (point size == pixel size), so a Retina capture pastes at 2x its
    /// physical size in DPI-aware apps. Passing the point size embeds the real density.
    /// `saveTo`, when non-nil, also writes the PNG to that file (best-effort; a failed
    /// disk write is logged but never fails the clipboard copy).
    static func copyPNG(
        _ image: CGImage,
        pointSize: CGSize? = nil,
        to pasteboard: NSPasteboard = .general,
        saveTo saveURL: URL? = nil,
        saveSettings: ScreenshotSettings? = nil,
        shouldPublish: @MainActor () -> Bool = { true },
        onSaveComplete: (@MainActor (Result<URL, Error>) -> Void)? = nil
    ) async -> Bool {
        guard let png = await Task.detached(priority: .userInitiated, operation: {
            encodePNG(image, pointSize: pointSize)
        }).value else {
            logger.error("Failed to encode captured image as PNG")
            return false
        }
        // Encoding can finish after a newer capture/OCR has claimed the clipboard.
        // The accepted screenshot may still be saved, but must not overwrite that result.
        let wrote = shouldPublish() ? write(png: png, to: pasteboard) : false
        if saveURL != nil || saveSettings?.saveToDisk == true {
            let id = UUID()
            let task = Task { @MainActor in
                let result = await Task.detached(priority: .utility) {
                    Result { try savePNG(png, to: saveURL, settings: saveSettings) }
                }.value
                if case .failure(let error) = result {
                    logger.error("Screenshot save failed: \(String(describing: error), privacy: .public)")
                }
                onSaveComplete?(result)
                pendingWrites[id] = nil
            }
            pendingWrites[id] = task
        }
        return wrote
    }

    /// Publish only a complete PNG. The temporary sibling is invisible to the capture
    /// library and the final move refuses collisions, including concurrent saves.
    nonisolated static func savePNG(_ png: Data, to requestedURL: URL? = nil, settings: ScreenshotSettings? = nil) throws -> URL {
        let settings = settings ?? ScreenshotSettings(saveToDisk: true)
        guard let first = requestedURL ?? settings.uniqueSaveURL(date: Date()) else {
            throw SaveError.directoryUnavailable
        }
        let directory = first.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".camcord-\(UUID().uuidString).pending")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try png.write(to: temporary, options: .withoutOverwriting)
        var destination = first
        for attempt in 0..<100 {
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
                return destination
            } catch {
                guard requestedURL == nil, FileManager.default.fileExists(atPath: destination.path) else { throw error }
                let stem = first.deletingPathExtension().lastPathComponent
                destination = directory.appendingPathComponent("\(stem) (\(attempt + 2)).png")
            }
        }
        throw SaveError.nameUnavailable
    }

    enum SaveError: Error { case directoryUnavailable, nameUnavailable }

    /// PNG eagerly + TIFF as a lazily-provided second representation: some legacy
    /// paste targets only look for public.tiff, and the provider only pays the TIFF
    /// encode if such a target actually asks — nothing is added to the hot path.
    private static func write(png: Data, to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        _ = item.setDataProvider(LazyTIFFProvider(png: png), forTypes: [.tiff])
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    nonisolated private static func encodePNG(_ image: CGImage, pointSize: CGSize?) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        if let pointSize, pointSize.width > 0, pointSize.height > 0 {
            rep.size = pointSize
        }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Renders the TIFF representation on demand from the already-encoded PNG (which
/// carries the density tag, so point size survives the round-trip). Immutable data
/// only; the pasteboard may call the provider on any thread.
private final class LazyTIFFProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let png: Data

    init(png: Data) {
        self.png = png
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard
            type == .tiff,
            let rep = NSBitmapImageRep(data: png),
            let tiff = rep.representation(using: .tiff, properties: [:])
        else {
            return
        }
        item.setData(tiff, forType: .tiff)
    }
}
