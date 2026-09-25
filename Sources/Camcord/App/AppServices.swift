import SwiftUI

/// The app's long-lived services, built once at launch and handed to the main window's
/// modules through the environment — never through a global, so a module can be rendered
/// in a test with real services and nothing depends on launch order.
@MainActor
final class AppServices {
    let defaults: UserDefaults
    let coordinator: CaptureCoordinator
    let recordingController: RecordingController
    let eventTapEngine: EventTapEngine
    let recordingState: RecordingStateModel

    init(defaults: UserDefaults = .standard,
         coordinator: CaptureCoordinator,
         recordingController: RecordingController,
         eventTapEngine: EventTapEngine,
         recordingState: RecordingStateModel) {
        self.defaults = defaults
        self.coordinator = coordinator
        self.recordingController = recordingController
        self.eventTapEngine = eventTapEngine
        self.recordingState = recordingState
    }
}

extension EnvironmentValues {
    /// Nil only where no app is running (a preview or a test that renders a bare module).
    @Entry var appServices: AppServices?
}
