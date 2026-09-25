import Foundation
import Testing

@testable import Camcord

/// Camera format: Auto picks the smallest 1080p-or-taller format at the highest rate ≤ 60 (or
/// the largest format when nothing is that tall); Manual offers the device's `W×H @ fps`.
/// All on fake format descriptors, so no camera is needed.
@Suite("Camera format")
struct CameraFormatTests {
    private func format(_ width: Int, _ height: Int, _ ranges: ClosedRange<Double>...) -> CameraFormatDescriptor {
        CameraFormatDescriptor(width: width, height: height, fpsRanges: ranges)
    }

    @Test("Auto on a 4K60 camera takes 1080p60, not 4K")
    func autoOn4K60() throws {
        let formats = [format(1280, 720, 1...60), format(3840, 2160, 1...30), format(1920, 1080, 1...60),
                       format(3840, 2160, 1...60)]
        let auto = try #require(CameraFormatSelection.auto(formats))
        #expect((auto.width, auto.height, auto.fps) == (1920, 1080, 60))
        #expect(auto.index == 2)
    }

    @Test("Auto on a 720p30-only camera takes its largest format")
    func autoOn720p30() throws {
        let auto = try #require(CameraFormatSelection.auto([format(640, 480, 1...30), format(1280, 720, 1...30)]))
        #expect((auto.width, auto.height, auto.fps) == (1280, 720, 30))
    }

    @Test("Auto on a camera whose 1080p stops at 30 takes 1080p30 over 720p60")
    func autoOn1080p30() throws {
        let auto = try #require(CameraFormatSelection.auto([format(1280, 720, 1...60), format(1920, 1080, 1...30)]))
        #expect((auto.width, auto.height, auto.fps) == (1920, 1080, 30))
    }

    @Test("Auto on this MacBook's camera (measured 2026-09-25) takes 1920×1080 @ 30, never a portrait format")
    func autoOnMacBookCamera() throws {
        // The built-in camera's real list, in its own order: portrait twins of the same size.
        let formats = [format(640, 480, 15...30), format(1280, 720, 15...30), format(1760, 1328, 15...30),
                       format(1328, 1760, 15...30), format(1552, 1552, 15...30), format(1080, 1920, 15...30),
                       format(1920, 1080, 15...30)]
        let auto = try #require(CameraFormatSelection.auto(formats))
        #expect((auto.width, auto.height, auto.fps) == (1920, 1080, 30))
        // A camera that only has portrait formats still gets one.
        let portrait = try #require(CameraFormatSelection.auto([format(1080, 1920, 1...30)]))
        #expect((portrait.width, portrait.height) == (1080, 1920))
    }

    @Test("Auto never asks for more than 60, and prefers the faster of two same-sized formats")
    func autoCapsAndPrefersFaster() throws {
        let auto = try #require(CameraFormatSelection.auto([format(1920, 1080, 1...30), format(1920, 1080, 1...120)]))
        #expect((auto.width, auto.height, auto.fps) == (1920, 1080, 60))
        #expect(auto.index == 1)
        #expect(CameraFormatSelection.auto([]) == nil)
        // A format that only runs above 60 is not usable for Auto.
        #expect(CameraFormatSelection.auto([format(1920, 1080, 100...120)]) == nil)
    }

    @Test("Manual lists each W×H @ fps once, at standard rates the ranges reach, sorted")
    func manualList() {
        let formats = [format(1920, 1080, 1...30), format(1280, 720, 1...60), format(1920, 1080, 1...30),
                       format(1920, 1080, 50...60)]
        #expect(CameraFormatSelection.manualOptions(formats) == [
            .manual(width: 1280, height: 720, fps: 24), .manual(width: 1280, height: 720, fps: 25),
            .manual(width: 1280, height: 720, fps: 30), .manual(width: 1280, height: 720, fps: 50),
            .manual(width: 1280, height: 720, fps: 60),
            .manual(width: 1920, height: 1080, fps: 24), .manual(width: 1920, height: 1080, fps: 25),
            .manual(width: 1920, height: 1080, fps: 30), .manual(width: 1920, height: 1080, fps: 50),
            .manual(width: 1920, height: 1080, fps: 60),
        ])
    }

    @Test("Manual resolves to its own format; one the camera lacks falls back to Auto")
    func resolveManual() throws {
        let formats = [format(1280, 720, 1...60), format(1920, 1080, 1...30)]
        let exact = try #require(CameraFormatSelection.resolve(.manual(width: 1280, height: 720, fps: 60), formats: formats))
        #expect((exact.index, exact.fps) == (0, 60))
        let missing = try #require(CameraFormatSelection.resolve(.manual(width: 1920, height: 1080, fps: 60), formats: formats))
        #expect(missing == CameraFormatSelection.auto(formats))
        #expect(CameraFormatSelection.resolve(.auto, formats: formats) == CameraFormatSelection.auto(formats))
    }

    @Test("the choice is kept per camera, defaults to Auto, and survives old or damaged settings")
    func perDevicePersistence() throws {
        var options = CameraOptions(enabled: true, deviceID: "cam-A")
        #expect(options.format == .auto)
        options.format = .manual(width: 1280, height: 720, fps: 60)
        options.deviceID = "cam-B"
        #expect(options.format == .auto)
        options.deviceID = "cam-A"
        #expect(options.format == .manual(width: 1280, height: 720, fps: 60))
        options.deviceID = nil
        options.format = .manual(width: 1920, height: 1080, fps: 30)
        #expect(options.formats[CameraOptions.formatKey(nil)] == .manual(width: 1920, height: 1080, fps: 30))
        // Back to Auto removes the entry instead of storing it.
        options.format = .auto
        #expect(options.formats[CameraOptions.formatKey(nil)] == nil)

        let decoded = try JSONDecoder().decode(CameraOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded.formats == options.formats)
        let legacy = try JSONDecoder().decode(CameraOptions.self, from: Data("{\"enabled\":true}".utf8))
        #expect(legacy.format == .auto && legacy.formats.isEmpty)
        let damaged = try JSONDecoder().decode(CameraOptions.self, from: Data(
            "{\"deviceID\":\"cam-A\",\"formats\":{\"cam-A\":{\"manual\":{\"width\":1280,\"height\":720,\"fps\":60}},\"cam-B\":{\"hologram\":{}}}}".utf8))
        #expect(damaged.format == .manual(width: 1280, height: 720, fps: 60))
        #expect(damaged.formats.count == 1)
    }

    @Test("a running preview is handed to the recording only when camera AND format match")
    func handOffNeedsDeviceAndFormat() {
        var options = CameraOptions(enabled: true, deviceID: "cam-A")
        options.format = .manual(width: 1920, height: 1080, fps: 30)
        let format = options.format
        #expect(CameraPreviewMonitor.canHandOff(running: true, deviceID: "cam-A", format: format, to: options))
        #expect(!CameraPreviewMonitor.canHandOff(running: true, deviceID: "cam-A", format: .auto, to: options))
        #expect(!CameraPreviewMonitor.canHandOff(running: true, deviceID: "cam-B", format: format, to: options))
        #expect(!CameraPreviewMonitor.canHandOff(running: false, deviceID: "cam-A", format: format, to: options))
        options.enabled = false
        #expect(!CameraPreviewMonitor.canHandOff(running: true, deviceID: "cam-A", format: format, to: options))
    }
}
