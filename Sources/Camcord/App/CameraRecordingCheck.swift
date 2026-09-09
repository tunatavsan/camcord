import AppKit
import AVFoundation
@preconcurrency import ScreenCaptureKit

/// Explicit developer check: captures only this app's neutral test window, never
/// the desktop, without audio. Temporary camera video is decoded and then deleted.
@MainActor
enum CameraRecordingCheck {
    static func run() async -> Int32 {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              CGPreflightScreenCaptureAccess() else {
            print("recording check: camera/screen permission missing")
            return 2
        }
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 602, height: 340),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Camcord camera check"
        window.backgroundColor = .blue
        window.orderFrontRegardless()
        window.displayIfNeeded()
        defer { window.close() }
        let monitor = CameraPreviewMonitor.shared
        monitor.setVisible(true, owner: "recording-check")
        defer { monitor.setVisible(false, owner: "recording-check"); monitor.recordingEnded() }
        do {
            // WindowServer registration is asynchronous. The optimized executable
            // can reach SCK before this newly-created test window has a surface.
            var target: SCWindow?
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(50))
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                if let candidate = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
                    let filter = SCContentFilter(desktopIndependentWindow: candidate)
                    if filter.contentRect.width >= 2, filter.contentRect.height >= 2, filter.pointPixelScale > 0 {
                        target = candidate
                        break
                    }
                }
            }
            guard let target else { print("recording check: own test window not ready"); return 3 }
            for warm in [false, true] {
                var settings = RecordingSettings.load(from: .standard)
                settings.camera.enabled = true
                settings.camera.position = nil
                settings.camera.corner = .bottomRight
                settings.camera.widthFraction = 0.30
                settings.systemAudio = false
                settings.microphone = false
                settings.container = .mov
                if warm { await monitor.start(deviceID: settings.camera.deviceID, fps: settings.fps) }
                let prepared = await monitor.prepareForRecording(options: settings.camera)
                if warm && prepared == nil { print("recording check: warm handoff missing"); return 4 }
                let engine = RecordingEngine()
                var cameraFailed = false
                engine.onCameraIssue = { message in cameraFailed = true; print("recording check: \(message)") }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("camcord-camera-check-\(UUID()).mov")
                defer { try? FileManager.default.removeItem(at: url) }
                try await engine.start(target: .window(target), settings: settings, outputURL: url,
                                       initiallyPaused: true, preparedCamera: prepared)
                engine.resume()
                try await Task.sleep(for: .seconds(1.5))
                let health = await engine.healthSnapshot()
                let livePreview = monitor.image != nil
                _ = try await engine.stop()
                monitor.recordingEnded()
                let asset = AVURLAsset(url: url)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { return 5 }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(output)
                guard reader.startReading() else { return 6 }
                defer { reader.cancelReading() }
                var cameraFrames = 0, frameCount = 0
                while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
                    frameCount += 1
                    let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
                    let rect = settings.camera.rect(in: size)
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    if let bytes = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                        let x = Int(rect.midX), y = Int(size.height - 1 - rect.midY)
                        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                        // The test window is pure blue; a live camera center differs.
                        if bytes[offset] < 180 || bytes[offset + 1] > 50 || bytes[offset + 2] > 50 { cameraFrames += 1 }
                    }
                    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                }
                print("recording check: warm=\(warm), preview=\(livePreview), frames=\(frameCount), cameraFrames=\(cameraFrames), appended=\(health?.video.appended ?? 0), cameraFailure=\(cameraFailed)")
                guard !cameraFailed, livePreview, cameraFrames >= 10 else { return 7 }
            }
            return 0
        } catch {
            print("recording check error: \(error)")
            return 1
        }
    }
}
