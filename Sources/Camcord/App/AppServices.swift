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
    let studioSession: StudioSession
    let editor: EditorSession
    let library: LibraryStore

    init(defaults: UserDefaults = .standard,
         coordinator: CaptureCoordinator,
         recordingController: RecordingController,
         eventTapEngine: EventTapEngine,
         recordingState: RecordingStateModel,
         library: LibraryStore? = nil,
         editor: EditorSession? = nil,
         studioSession: StudioSession? = nil) {
        self.defaults = defaults
        self.coordinator = coordinator
        self.recordingController = recordingController
        self.eventTapEngine = eventTapEngine
        self.recordingState = recordingState
        self.studioSession = studioSession ?? StudioSession(defaults: defaults, controller: recordingController,
                                                           recordingState: recordingState, coordinator: coordinator)
        self.library = library ?? LibraryStore(defaults: defaults)
        self.editor = editor ?? EditorSession(defaults: defaults)
        self.editor.claimClipboardPublication = { [weak coordinator] in
            coordinator?.claimClipboardPublication() ?? { false }
        }
        self.library.claimClipboardPublication = { [weak coordinator] in
            coordinator?.claimClipboardPublication() ?? { false }
        }
        self.editor.onDocumentAccepted = { [weak self] in self?.mainWindow?.model.select(.edit) }
        self.library.onOpenScreenshot = { [weak self] url in
            guard let self else { throw EditorError.stale }
            if case .failed(let message) = await self.editor.requestOpen(url: url) {
                throw LibraryStore.ActionFailure(message: message)
            }
        }
    }

    /// The main window, so a capture started from it can step the window aside.
    weak var mainWindow: MainWindowController?

    /// Starts a capture from the main window: the window steps aside, the capture runs through
    /// the coordinator's own entry point, the window comes back.
    func capture(_ kind: CaptureKind) {
        let coordinator = coordinator
        Task { @MainActor [weak self] in
            await self?.stepAside { await kind.perform(with: coordinator) }
        }
    }

    /// Record from the main window: a stop happens in place; a start steps the window aside for
    /// the target picker, as the hotkey does.
    func toggleRecording() {
        let controller = recordingController
        Task { @MainActor [weak self] in
            guard let self else { return }
            if controller.isBusy {
                await controller.toggleRecording()
            } else {
                await self.stepAside { await controller.toggleRecording() }
            }
        }
    }

    private func stepAside(_ work: @MainActor () async -> Void) async {
        if let mainWindow { await mainWindow.stepAside(during: work) } else { await work() }
    }
}

extension EnvironmentValues {
    /// Nil only where no app is running (a preview or a test that renders a bare module).
    @Entry var appServices: AppServices?
}
