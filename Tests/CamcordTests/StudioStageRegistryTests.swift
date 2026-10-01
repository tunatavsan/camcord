import CoreMedia
import CoreVideo
import Foundation
import Testing
import os
@testable import Camcord

@MainActor @Suite("Studio stage subscriber admission")
struct StudioStageRegistryTests {
    @Test("legacy callbacks are admitted at ten Hz while native owners receive all accepted frames")
    func legacyCadence() throws {
        let registry = StudioStageRegistry()
        let counts = OSAllocatedUnfairLock(initialState: [0, 0])
        registry.subscribe(owner: UUID()) { _ in counts.withLock { $0[0] += 1 } }
        let native = UUID()
        registry.subscribe(owner: native, maximumFramesPerSecond: nil) { _ in counts.withLock { $0[1] += 1 } }
        let sink = try #require(registry.snapshot())
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer), epoch = UUID()
        for index in 0..<30 { sink(PixelBufferBox(pixels, pts: CMTime(value: Int64(index), timescale: 30), epoch: epoch)) }
        #expect(counts.withLock { $0 } == [10, 30])
        registry.unsubscribe(owner: native)
        sink(PixelBufferBox(pixels, pts: CMTime(value: 30, timescale: 30), epoch: epoch))
        #expect(counts.withLock { $0 } == [11, 30])
        // A new writer's timeline starts at zero; it must not inherit the old throttle.
        sink(PixelBufferBox(pixels, pts: .zero, epoch: UUID()))
        #expect(counts.withLock { $0 } == [12, 30])
    }
}
