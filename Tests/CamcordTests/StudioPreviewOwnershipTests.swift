import Foundation
import CoreMedia
import Testing
@testable import Camcord

@MainActor @Suite("Studio preview ownership")
struct StudioPreviewOwnershipTests {
    private final class Preview: StudioPreviewCapture {
        var stops = 0
        func start(target: RecordingEngine.Target, canvasSize: CGSize, capturesAudio: Bool) async throws {}
        func stop() async { stops += 1 }
        func latestFrame() -> StudioSampleFrame? { nil }
        func audioSnapshot() -> MicrophoneProbeSnapshot { .init() }
        func updateGain(_ gainDB: Double) {}
        func configure(viewport: StudioPreviewViewport, frameSink: @escaping @Sendable (StudioSampleFrame) -> Void) {}
        func updateViewport(_ viewport: StudioPreviewViewport) async throws {}
    }

    @Test("an old start completion stops only the old preview and preserves the replacement")
    func staleStart() async throws {
        let owner = StudioPreviewOwner(), a = Preview(), b = Preview()
        var pending: CheckedContinuation<Void, Never>?
        let token = owner.generation
        let first = Task { try await owner.install(a, generation: token) {
            await withCheckedContinuation { pending = $0 }
        } }
        while pending == nil { await Task.yield() }
        let retired = owner.detach()
        #expect(retired === a)
        #expect(try await owner.install(b, generation: owner.generation, start: {}))
        pending?.resume()
        #expect(try await first.value == false)
        #expect(owner.capture === b)
        #expect(a.stops == 1 && b.stops == 0)
    }

    @Test("bounded idle configuration has no microphone or passive audio", arguments: [false, true])
    func previewConfiguration(explicitAudioTest: Bool) {
        let configuration = StudioScreenPreview.configuration(canvasSize: CGSize(width: 7680, height: 4320),
            capturesAudio: explicitAudioTest, viewport: .init(pixelSize: CGSize(width: 1536, height: 864), refreshRate: 120))
        #expect(configuration.width == 1536 && configuration.height == 864)
        #expect(configuration.minimumFrameInterval == CMTime(value: 1, timescale: 120))
        #expect(configuration.queueDepth == 3)
        #expect(!configuration.captureMicrophone)
        #expect(configuration.capturesAudio == explicitAudioTest)
        #expect(configuration.excludesCurrentProcessAudio)
    }
}
