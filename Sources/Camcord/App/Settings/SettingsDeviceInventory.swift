import AVFoundation
import Foundation
import Observation

/// Metadata only. Device discovery never starts a capture session or requests permission.
struct SettingsCaptureDevice: Identifiable, Equatable {
    let id: String
    let name: String
    var formats: [CameraFormatDescriptor] = []
}

@MainActor @Observable
final class SettingsDeviceInventory {
    enum Kind { case microphone, camera }
    struct Snapshot: Equatable {
        var devices: [SettingsCaptureDevice]
        var defaultID: String?
    }

    private(set) var snapshot = Snapshot(devices: [], defaultID: nil)
    @ObservationIgnored private let load: () -> Snapshot
    @ObservationIgnored private let notifications: NotificationCenter
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(kind: Kind, notifications: NotificationCenter = .default, load: (() -> Snapshot)? = nil) {
        self.notifications = notifications
        self.load = load ?? { Self.discover(kind) }
    }

    /// A page subscribes only while visible, reloading once on re-entry and on hotplug.
    func start() {
        guard observers.isEmpty else { return }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // NotificationCenter's main operation queue owns this callback.
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func stop() {
        for observer in observers { notifications.removeObserver(observer) }
        observers.removeAll()
    }

    isolated deinit {
        for observer in observers { notifications.removeObserver(observer) }
    }

    private func refresh() {
        let next = load()
        if next != snapshot { snapshot = next }
    }

    func missing(_ selectedID: String?) -> Bool {
        selectedID.map { id in !snapshot.devices.contains { $0.id == id } } ?? false
    }

    /// An unavailable explicit device keeps its stored ID and offers no misleading formats
    /// from another device. Reconnecting it restores the available choices.
    func formats(for selectedID: String?) -> [CameraFormatDescriptor] {
        guard let id = selectedID ?? snapshot.defaultID else { return [] }
        return snapshot.devices.first { $0.id == id }?.formats ?? []
    }

    private static func discover(_ kind: Kind) -> Snapshot {
        let video = kind == .camera
        let types: [AVCaptureDevice.DeviceType] = video
            ? [.builtInWideAngleCamera, .external, .continuityCamera] : [.microphone, .external]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: video ? .video : .audio,
                                                       position: .unspecified).devices
        return Snapshot(devices: devices.map {
            SettingsCaptureDevice(id: $0.uniqueID, name: $0.localizedName,
                                  formats: video ? $0.formats.map(CameraFormatDescriptor.init) : [])
        }, defaultID: AVCaptureDevice.default(for: video ? .video : .audio)?.uniqueID)
    }
}
