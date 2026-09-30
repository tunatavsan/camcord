import AVFoundation
import Combine
import Foundation

/// Device notifications may arrive on the posting thread. Studio consumes them on the main run loop.
enum StudioDeviceNotifications {
    static func publisher(center: NotificationCenter = .default) -> AnyPublisher<Notification, Never> {
        center.publisher(for: AVCaptureDevice.wasConnectedNotification)
            .merge(with: center.publisher(for: AVCaptureDevice.wasDisconnectedNotification))
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }
}
