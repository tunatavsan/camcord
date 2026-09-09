import Foundation

/// The panel's two stable destinations and their newest known captures. Paths are
/// resolved synchronously from settings; directory scans happen off the main actor.
struct CaptureLibrarySnapshot: Equatable, Sendable {
    let recordingDirectory: URL
    let screenshotDirectory: URL
    let newestRecording: URL?
    let newestScreenshot: URL?
}

enum CaptureLibrary {
    static let recordingExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static let screenshotExtensions: Set<String> = ["png"]

    static func directories(
        recordingSettings: RecordingSettings,
        screenshotSettings: ScreenshotSettings
    ) -> (recording: URL, screenshot: URL) {
        let recordingPath = recordingSettings.outputDirectoryPath.flatMap { $0.isEmpty ? nil : $0 }
            ?? RecordingSettings.defaultDirectoryPath()
        let screenshotPath = screenshotSettings.saveDirectoryPath.flatMap { $0.isEmpty ? nil : $0 }
            ?? ScreenshotSettings.defaultDirectoryPath()
        return (
            URL(fileURLWithPath: recordingPath, isDirectory: true),
            URL(fileURLWithPath: screenshotPath, isDirectory: true)
        )
    }

    static func scan(recordingDirectory: URL, screenshotDirectory: URL) async -> CaptureLibrarySnapshot {
        let recordingScan = Task.detached(priority: .utility) {
            newestFile(in: recordingDirectory, extensions: recordingExtensions)
        }
        let screenshotScan = Task.detached(priority: .utility) {
            newestFile(in: screenshotDirectory, extensions: screenshotExtensions)
        }

        return await withTaskCancellationHandler {
            CaptureLibrarySnapshot(
                recordingDirectory: recordingDirectory,
                screenshotDirectory: screenshotDirectory,
                newestRecording: await recordingScan.value,
                newestScreenshot: await screenshotScan.value
            )
        } onCancel: {
            recordingScan.cancel()
            screenshotScan.cancel()
        }
    }

    /// Creates an empty configured destination before asking Finder to reveal it.
    static func prepareDirectory(_ directory: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return true
            } catch {
                return false
            }
        }.value
    }

    nonisolated static func newestFile(in directory: URL, extensions: Set<String>) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: (url: URL, date: Date)?
        for url in urls where extensions.contains(url.pathExtension.lowercased()) {
            guard !Task.isCancelled else { return nil }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            let date = values.contentModificationDate ?? .distantPast
            if newest == nil || date > newest!.date {
                newest = (url, date)
            }
        }
        return newest?.url
    }
}
