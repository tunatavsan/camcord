import Foundation
import Testing

@testable import Camcord

@Suite("CaptureLibrary")
struct CaptureLibraryTests {
    @Test("scan returns the newest supported recording and screenshot")
    func newestSupportedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("camcord-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldMovie = directory.appendingPathComponent("old.mp4")
        let newMovie = directory.appendingPathComponent("new.MOV")
        let screenshot = directory.appendingPathComponent("shot.PNG")
        let unsupported = directory.appendingPathComponent("later.txt")
        let movieNamedDirectory = directory.appendingPathComponent("folder.mov", isDirectory: true)
        for url in [oldMovie, newMovie, screenshot, unsupported] {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }
        try FileManager.default.createDirectory(at: movieNamedDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: oldMovie.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: newMovie.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 30)], ofItemAtPath: screenshot.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 40)], ofItemAtPath: unsupported.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 50)], ofItemAtPath: movieNamedDirectory.path)

        let snapshot = await CaptureLibrary.scan(recordingDirectory: directory, screenshotDirectory: directory)
        #expect(snapshot.newestRecording?.resolvingSymlinksInPath() == newMovie.resolvingSymlinksInPath())
        #expect(snapshot.newestScreenshot?.resolvingSymlinksInPath() == screenshot.resolvingSymlinksInPath())
    }

    @Test("empty configured paths resolve to the stable default destinations")
    func emptyPathsUseDefaults() {
        let directories = CaptureLibrary.directories(
            recordingSettings: RecordingSettings(outputDirectoryPath: ""),
            screenshotSettings: ScreenshotSettings(saveDirectoryPath: "")
        )
        #expect(directories.recording.path == RecordingSettings.defaultDirectoryPath())
        #expect(directories.screenshot.path == ScreenshotSettings.defaultDirectoryPath())
    }

    @Test("prepareDirectory creates a missing configured destination")
    func prepareDirectoryCreatesDestination() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("camcord-library-tests-\(UUID().uuidString)/nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        #expect(await CaptureLibrary.prepareDirectory(directory))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}
