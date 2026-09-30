import AVFoundation
import Testing

@testable import Camcord

@MainActor
@Suite("Settings devices")
struct SettingsDeviceTests {
    @Test("hotplug refreshes cached choices only while the Settings page is visible")
    func hotplugAndLifecycle() {
        let notifications = NotificationCenter()
        let format = CameraFormatDescriptor(width: 1920, height: 1080, fpsRanges: [24...60])
        var connected = true
        var loads = 0
        let inventory = SettingsDeviceInventory(kind: .camera, notifications: notifications) {
            loads += 1
            return .init(devices: connected ? [.init(id: "camera", name: "Fixture camera", formats: [format])] : [],
                         defaultID: connected ? "camera" : nil)
        }
        #expect(loads == 0)
        inventory.start()
        inventory.start()
        #expect(loads == 1)
        #expect(inventory.formats(for: nil) == [format])
        #expect(!inventory.missing("camera"))
        connected = false
        notifications.post(name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        #expect(loads == 2)
        #expect(inventory.missing("camera"))
        #expect(inventory.formats(for: "camera").isEmpty)
        inventory.stop()
        connected = true
        notifications.post(name: AVCaptureDevice.wasConnectedNotification, object: nil)
        #expect(loads == 2)
        inventory.start()
        #expect(loads == 3)
        #expect(!inventory.missing("camera"))
        #expect(inventory.formats(for: "camera") == [format])
        #expect(inventory.formats(for: "disconnected-other-camera").isEmpty)
        inventory.stop()
    }

    @Test("discarding a visible page removes its notification observers")
    func releasesObservers() {
        let notifications = NotificationCenter()
        var loads = 0
        var inventory: SettingsDeviceInventory? = SettingsDeviceInventory(kind: .microphone, notifications: notifications) {
            loads += 1
            return .init(devices: [], defaultID: nil)
        }
        weak let released = inventory
        inventory?.start()
        inventory = nil
        #expect(released == nil)
        notifications.post(name: AVCaptureDevice.wasConnectedNotification, object: nil)
        #expect(loads == 1)
    }
}
