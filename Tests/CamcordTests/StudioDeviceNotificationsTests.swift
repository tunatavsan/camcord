import AVFoundation
import Combine
import Foundation
import Testing
import os
@testable import Camcord

@Suite("Studio device notification delivery")
struct StudioDeviceNotificationsTests {
    @MainActor @Test("both background hotplug events reach the actual Studio publisher subscriber on the main thread")
    func backgroundHotplugDelivery() async {
        let center = NotificationCenter() // isolated; no device enumeration or global observers
        let observed = OSAllocatedUnfairLock(initialState: [HotplugReceipt]())
        let deliveries = MainDeliveryCounter()
        let subscription = StudioDeviceNotifications.publisher(center: center).sink { @Sendable notification in
            // Capture the actual downstream thread before hopping actors. This closure itself
            // has no inherited MainActor isolation, so a scheduler mutant records a failure
            // rather than tripping the test's own actor-isolation precondition.
            let receipt = HotplugReceipt(name: notification.name.rawValue, onMain: Thread.isMainThread)
            observed.withLock { $0.append(receipt) }
            Task { @MainActor in deliveries.count += 1 }
        }
        defer { subscription.cancel() }

        let postedOffMain = await Task.detached { Self.postHotplug(to: center) }.value
        #expect(postedOffMain)

        // Bound missing-delivery failures; suspension lets RunLoop.main deliver real events.
        let deadline = ContinuousClock.now + .seconds(5)
        while deliveries.count < 2, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let receipts = observed.withLock { $0 }
        #expect(deliveries.count == 2)
        #expect(receipts.map(\.name).sorted() == [AVCaptureDevice.wasConnectedNotification.rawValue,
                                                AVCaptureDevice.wasDisconnectedNotification.rawValue].sorted())
        #expect(receipts.allSatisfy { $0.onMain })
    }

    /// Synchronous post boundary permits a thread check without async-context Thread APIs.
    private static func postHotplug(to center: NotificationCenter) -> Bool {
        let offMain = !Thread.isMainThread
        center.post(name: AVCaptureDevice.wasConnectedNotification, object: nil)
        center.post(name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        return offMain
    }
}

private struct HotplugReceipt: Sendable {
    let name: String
    let onMain: Bool
}

@MainActor private final class MainDeliveryCounter {
    var count = 0
}
