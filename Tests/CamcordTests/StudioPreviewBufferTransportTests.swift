import CoreMedia
import CoreVideo
import Foundation
import Testing
import os
@testable import Camcord

@Suite("Studio native preview transport")
struct StudioPreviewBufferTransportTests {
    private final class DisplayState: Sendable {
        struct State {
            var ready = true
            var failed = false
            var samples: [StudioPreviewBufferTransport.Sample] = []
            var flushes = 0
        }
        let state = OSAllocatedUnfairLock(initialState: State())
        var display: StudioPreviewBufferTransport.Display {
            .init(ready: { self.state.withLock { $0.ready } }, failed: { self.state.withLock { $0.failed } },
                  enqueue: { sample in self.state.withLock { $0.samples.append(sample) } },
                  flush: { done in
                      self.state.withLock {
                          if let last = $0.samples.last { $0.samples = [last] }
                          $0.flushes += 1
                      }
                      done()
                  })
        }
    }
    private final class CopyGate: Sendable {
        private struct State { var entered = false; var waiter: CheckedContinuation<Void, Never>? }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let release = DispatchSemaphore(value: 0)
        func pause() {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.entered = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
            release.wait() // synchronous injected copy boundary, never an async executor
        }
        func entered() async {
            await withCheckedContinuation { continuation in
                let resume = state.withLock { state -> Bool in
                    if state.entered { return true }
                    state.waiter = continuation
                    return false
                }
                if resume { continuation.resume() }
            }
        }
        func open() { release.signal() }
    }
    private final class Pool: @unchecked Sendable {
        let value: CVPixelBufferPool
        init() throws {
            var pool: CVPixelBufferPool?
            let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            #expect(CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess)
            value = try #require(pool)
        }
        func allocate() -> (CVReturn, CVPixelBuffer?) {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, value,
                [kCVPixelBufferPoolAllocationThresholdKey as String: 1] as CFDictionary, &buffer)
            return (status, buffer)
        }
    }
    private func buffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        return try #require(buffer)
    }
    private func prepare(_ transport: StudioPreviewBufferTransport, display: StudioPreviewBufferTransport.Display,
                         owner: UUID) async {
        _ = transport.attach(display: display, viewport: .init(pixelSize: CGSize(width: 8, height: 8), refreshRate: 60))
        transport.activate(owner: owner)
        await transport.drain()
        await transport.drain() // the flush completion enqueues its causal state barrier
    }

    @Test("busy admission is nonblocking and retirement rejects an already admitted frame")
    func busyAndRetirement() async throws {
        let gate = CopyGate(), display = DisplayState(), owner = UUID()
        let transport = StudioPreviewBufferTransport(beforeCopy: { gate.pause() })
        await prepare(transport, display: display.display, owner: owner)
        let frame = PixelBufferBox(try buffer(), pts: .zero, epoch: UUID())
        #expect(transport.tryOffer(frame, owner: owner))
        await gate.entered()
        #expect(!transport.tryOffer(frame, owner: owner))
        transport.retire(owner: owner)
        #expect(!transport.tryOffer(frame, owner: owner))
        gate.open()
        await transport.drain(); await transport.drain()
        #expect(display.state.withLock { $0.samples.isEmpty })
        #expect(transport.statistics.busyDrops == 1)
        #expect(transport.statistics.retiredDrops >= 2)
        let replacement = UUID()
        transport.activate(owner: replacement)
        await transport.drain(); await transport.drain()
        transport.retire(owner: owner) // an old producer cannot retire the replacement
        gate.open()
        #expect(transport.tryOffer(frame, owner: replacement))
        await transport.drain()
        #expect(display.state.withLock { $0.samples.count } == 1)
    }

    @Test("renderer failure retires admission while preserving the last displayed image")
    func displayFailureRetainsImage() async throws {
        let display = DisplayState(), owner = UUID(), transport = StudioPreviewBufferTransport()
        await prepare(transport, display: display.display, owner: owner)
        let frame = PixelBufferBox(try buffer())
        #expect(transport.tryOffer(frame, owner: owner))
        await transport.drain()
        display.state.withLock { $0.failed = true }
        #expect(transport.tryOffer(frame, owner: owner))
        await transport.drain(); await transport.drain()
        #expect(transport.statistics.failures == 1)
        #expect(!transport.tryOffer(frame, owner: owner))
        #expect(display.state.withLock { $0.samples.count } == 1)
    }

    @Test("retirement at the final renderer readiness boundary cannot enqueue a stale copy")
    func retirementBeforeFinalEnqueue() async throws {
        let transport = StudioPreviewBufferTransport(), owner = UUID()
        let checks = OSAllocatedUnfairLock(initialState: 0)
        let samples = OSAllocatedUnfairLock(initialState: [StudioPreviewBufferTransport.Sample]())
        let display = StudioPreviewBufferTransport.Display(ready: {
            let count = checks.withLock { $0 += 1; return $0 }
            if count == 2 { transport.retire(owner: owner) }
            return true
        }, failed: { false }, enqueue: { sample in samples.withLock { $0.append(sample) } }, flush: { $0() })
        await prepare(transport, display: display, owner: owner)
        #expect(transport.tryOffer(PixelBufferBox(try buffer()), owner: owner))
        await transport.drain(); await transport.drain()
        #expect(checks.withLock { $0 } == 2)
        #expect(samples.withLock { $0.isEmpty })
        #expect(transport.statistics.retiredDrops == 1)
        #expect(transport.statistics.enqueued == 0)
    }

    @Test("renderer readiness drops without enqueue and independent output pool is bounded")
    func readinessAndPoolBudget() async throws {
        let display = DisplayState(), owner = UUID(), transport = StudioPreviewBufferTransport()
        await prepare(transport, display: display.display, owner: owner)
        let frame = PixelBufferBox(try buffer(), pts: .zero)
        display.state.withLock { $0.ready = false }
        #expect(transport.tryOffer(frame, owner: owner))
        await transport.drain()
        #expect(transport.statistics.readinessDrops == 1)
        #expect(display.state.withLock { $0.samples.isEmpty })
        display.state.withLock { $0.ready = true }
        for _ in 0..<3 { #expect(transport.tryOffer(frame, owner: owner)); await transport.drain() }
        #expect(display.state.withLock { $0.samples.count } == 2)
        #expect(transport.statistics.poolDrops == 1)
        transport.retire(owner: owner)
        let replacement = UUID()
        transport.activate(owner: replacement)
        await transport.drain(); await transport.drain()
        #expect(display.state.withLock { $0.samples.count } == 1)
        for _ in 0..<3 { #expect(transport.tryOffer(frame, owner: replacement)); await transport.drain() }
        // Two current outputs plus one retained image from the retired generation.
        #expect(display.state.withLock { $0.samples.count } == 3)
        #expect(transport.statistics.poolDrops == 2)
    }

    @Test("encoder input pool is reusable before display enqueue retains the preview copy")
    func inputReleasedBeforeEnqueue() async throws {
        let source = try Pool(), owner = UUID(), gate = CopyGate()
        let transport = StudioPreviewBufferTransport(beforeCopy: { gate.pause() })
        let statuses = OSAllocatedUnfairLock(initialState: [CVReturn]())
        let displayed = OSAllocatedUnfairLock<StudioPreviewBufferTransport.Sample?>(initialState: nil)
        let display = StudioPreviewBufferTransport.Display(ready: { true }, failed: { false }, enqueue: { sample in
            statuses.withLock { $0.append(source.allocate().0) }
            displayed.withLock { $0 = sample }
        }, flush: { $0() })
        await prepare(transport, display: display, owner: owner)
        func offerSource() throws -> Bool {
            let input = try #require(source.allocate().1)
            return transport.tryOffer(PixelBufferBox(input), owner: owner)
        }
        #expect(try offerSource())
        await gate.entered()
        gate.open()
        await transport.drain()
        #expect(statuses.withLock { $0 } == [kCVReturnSuccess])
        #expect(displayed.withLock { $0 != nil })
    }

    @Test("preview adds immediate-display timing only to its copy, leaving source attachments intact")
    func sourceAttachmentsImmutable() async throws {
        let source = try buffer(), display = DisplayState(), owner = UUID(), transport = StudioPreviewBufferTransport()
        let key = "dev.camcord.preview-test" as CFString
        CVBufferSetAttachment(source, key, "original" as CFString, .shouldPropagate)
        let before = CVBufferCopyAttachments(source, .shouldPropagate)
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: source,
                                                           formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: 9, timescale: 30), decodeTimeStamp: .invalid)
        var original: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: source,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &original) == noErr)
        let originalSample = try #require(original)
        let originalAttachments = try #require(CMSampleBufferGetSampleAttachmentsArray(originalSample, createIfNecessary: true))
        let originalDictionary = unsafeBitCast(CFArrayGetValueAtIndex(originalAttachments, 0), to: CFDictionary.self)
        let sampleBefore = CFDictionaryCreateCopy(nil, originalDictionary)
        await prepare(transport, display: display.display, owner: owner)
        #expect(transport.tryOfferIdle(StudioSampleFrame(sample: originalSample), owner: owner))
        await transport.drain()
        let sampleBox = try #require(display.state.withLock { $0.samples.first })
        let sample = sampleBox.value
        let preview = try #require(CMSampleBufferGetImageBuffer(sample))
        #expect(preview !== source)
        #expect(CVPixelBufferGetWidth(preview) == 8)
        #expect(CFEqual(before, CVBufferCopyAttachments(source, .shouldPropagate)))
        #expect(CFEqual(sampleBefore, originalDictionary))
        #expect(CMSampleBufferGetPresentationTimeStamp(sample) == CMTime(value: 9, timescale: 30))
        let attachment = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        #expect(attachment?.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)
    }
}
