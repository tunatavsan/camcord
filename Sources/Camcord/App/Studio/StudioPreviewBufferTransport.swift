import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

struct StudioPreviewViewport: Equatable, Sendable {
    let pixelSize: CGSize
    let refreshRate: Int

    init(pixelSize: CGSize, refreshRate: Int) {
        func dimension(_ value: CGFloat) -> CGFloat {
            guard value.isFinite else { return 2 }
            return CGFloat(max(2, RegionClamp.evenFloor(min(16_384, max(2, value)))))
        }
        self.pixelSize = CGSize(width: dimension(pixelSize.width), height: dimension(pixelSize.height))
        self.refreshRate = refreshRate > 60 ? 120 : 60
    }
}

struct StudioIdlePreviewConfiguration: Sendable {
    var cameraSource: (any CameraFrameSource)?
    var cameraOptions: CameraOptions = .init()
    var layers: StudioLayerSnapshot = .empty
    var fitsWindow = false
}

/// One admission permit spans native composition, transfer and enqueue. Native media
/// objects, the transfer session and the single output pool live only on `queue`.
/// The lock carries immutable configuration and liveness across synchronous producers.
final class StudioPreviewBufferTransport: @unchecked Sendable {
    struct Geometry: Equatable, Sendable {
        let pixelSize: CGSize
        let contentRect: CGRect?
    }
    enum Event: Sendable {
        case firstFrameOrGeometry(owner: UUID, host: UUID, geometry: Geometry)
        case failed(owner: UUID, host: UUID)
    }
    struct Statistics: Sendable {
        var admitted: UInt64 = 0
        var enqueued: UInt64 = 0
        var busyDrops: UInt64 = 0
        var readinessDrops: UInt64 = 0
        var poolDrops: UInt64 = 0
        var retiredDrops: UInt64 = 0
        var failures: UInt64 = 0
    }
    /// Injectable native boundary for deterministic backpressure/lifetime tests.
    /// Enqueue is synchronous, nonblocking, and must not reenter this transport.
    struct Display: Sendable {
        let ready: @Sendable () -> Bool
        let failed: @Sendable () -> Bool
        let enqueue: @Sendable (Sample) -> Void
        let flush: @Sendable (@escaping @Sendable () -> Void) -> Void
    }
    struct Sample: @unchecked Sendable { let value: CMSampleBuffer }
    private final class Renderer: @unchecked Sendable {
        let value: AVSampleBufferVideoRenderer
        init(_ value: AVSampleBufferVideoRenderer) { self.value = value }
    }
    private enum Input: Sendable {
        case recorded(PixelBufferBox)
        case idle(StudioSampleFrame)
    }
    /// Initialized before dispatch; mutated/released only on the transport queue.
    private final class Pending: @unchecked Sendable {
        var input: Input?
        let ticket: UUID
        let owner: UUID
        let host: UUID
        let generation: UInt64
        let viewport: StudioPreviewViewport
        let idle: StudioIdlePreviewConfiguration
        init(input: Input, ticket: UUID, owner: UUID, host: UUID, generation: UInt64,
             viewport: StudioPreviewViewport, idle: StudioIdlePreviewConfiguration) {
            self.input = input; self.ticket = ticket; self.owner = owner; self.host = host
            self.generation = generation; self.viewport = viewport; self.idle = idle
        }
    }
    private struct State {
        var host: UUID?
        var owner: UUID?
        var generation: UInt64 = 0
        var viewport: StudioPreviewViewport?
        var permit: UUID?
        var flushing = true
        var idle = StudioIdlePreviewConfiguration()
        var latestIdle: StudioSampleFrame?
        var geometry: Geometry?
        var event: (@Sendable (Event) -> Void)?
        var statistics = Statistics()
    }
    private struct PoolKey: Equatable {
        let width: Int
        let height: Int
        let format: OSType
    }
    private struct CopiedFrame {
        let frame: PixelBufferBox
        let geometry: Geometry
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "dev.tavsan.camcord.studio.native-preview", qos: .userInteractive)
    private var display: Display?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolKey: PoolKey?
    private var format: CMVideoFormatDescription?
    private let idleRenderer = StudioIdlePreviewRenderer()
    private var cameraTimer: DispatchSourceTimer?
    private let beforeCopy: (@Sendable () -> Void)?

    init(beforeCopy: (@Sendable () -> Void)? = nil) { self.beforeCopy = beforeCopy }
    deinit { cameraTimer?.cancel() }
    var statistics: Statistics { state.withLock { $0.statistics } }
    func setEventHandler(_ event: @escaping @Sendable (Event) -> Void) { state.withLock { $0.event = event } }
    func updateIdleConfiguration(_ configuration: StudioIdlePreviewConfiguration) {
        state.withLock { $0.idle = configuration }
        queue.async { [self] in
            updateCameraTimer()
            if let pending = idleSnapshot() { offer(.idle(pending.0), owner: pending.1) }
        }
    }

    @MainActor
    func attach(_ layer: AVSampleBufferDisplayLayer, viewport: StudioPreviewViewport) -> UUID {
        let renderer = Renderer(layer.sampleBufferRenderer)
        return attach(display: Display(
            ready: { renderer.value.isReadyForMoreMediaData },
            failed: { renderer.value.status == .failed || renderer.value.requiresFlushToResumeDecoding },
            enqueue: { renderer.value.enqueue($0.value) },
            flush: { renderer.value.flush(removingDisplayedImage: false, completionHandler: $0) }
        ), viewport: viewport)
    }

    func attach(display: Display, viewport: StudioPreviewViewport) -> UUID {
        let host = UUID()
        let generation = state.withLock { state -> UInt64 in
            state.host = host; state.viewport = viewport; state.generation &+= 1
            state.flushing = true; state.geometry = nil
            return state.generation
        }
        queue.async { [self] in
            let old = self.display
            self.display = display
            if let old {
                old.flush { [self] in queue.async { [self] in flush(generation: generation, host: host) } }
            } else { flush(generation: generation, host: host) }
        }
        return host
    }

    func updateViewport(_ viewport: StudioPreviewViewport, host: UUID) {
        let generation = state.withLock { state -> UInt64? in
            guard state.host == host, state.viewport != viewport else { return nil }
            state.viewport = viewport; state.generation &+= 1; state.flushing = true; state.geometry = nil
            return state.generation
        }
        if let generation { queue.async { [self] in flush(generation: generation, host: host) } }
    }

    func detach(host: UUID) {
        let generation = state.withLock { state -> UInt64? in
            guard state.host == host else { return nil }
            state.host = nil; state.owner = nil; state.viewport = nil
            state.latestIdle = nil
            state.generation &+= 1; state.flushing = true
            return state.generation
        }
        guard generation != nil else { return }
        queue.async { [self] in
            display?.flush {}
            display = nil
            clearPool()
            updateCameraTimer()
        }
    }

    func activate(owner: UUID) {
        let token = state.withLock { state -> (UInt64, UUID?) in
            state.owner = owner; state.generation &+= 1; state.flushing = true; state.geometry = nil; state.latestIdle = nil
            return (state.generation, state.host)
        }
        queue.async { [self] in flush(generation: token.0, host: token.1) }
    }

    func retire(owner: UUID) {
        let token = state.withLock { state -> (UInt64, UUID?)? in
            guard state.owner == owner else { return nil }
            state.owner = nil; state.generation &+= 1; state.flushing = true; state.latestIdle = nil
            return (state.generation, state.host)
        }
        if let token { queue.async { [self] in flush(generation: token.0, host: token.1) } }
    }

    @discardableResult
    func tryOffer(_ frame: PixelBufferBox, owner: UUID) -> Bool { offer(.recorded(frame), owner: owner) }
    @discardableResult
    func tryOfferIdle(_ frame: StudioSampleFrame, owner: UUID) -> Bool {
        let cameraDriven = state.withLockIfAvailable { state -> Bool? in
            guard state.owner == owner else { return nil }
            state.latestIdle = frame
            return state.idle.cameraSource != nil
        } ?? nil
        guard let cameraDriven else { return false }
        // Static screen capture need not deliver new complete samples. A native queue
        // timer reads the live camera source at viewport cadence in that case.
        return cameraDriven ? true : offer(.idle(frame), owner: owner)
    }

    @discardableResult
    private func offer(_ input: Input, owner: UUID) -> Bool {
        let pending = state.withLockIfAvailable { state -> Pending? in
            guard state.owner == owner, let host = state.host, let viewport = state.viewport, !state.flushing else {
                state.statistics.retiredDrops &+= 1
                return nil
            }
            guard state.permit == nil else { state.statistics.busyDrops &+= 1; return nil }
            let ticket = UUID()
            state.permit = ticket; state.statistics.admitted &+= 1
            return Pending(input: input, ticket: ticket, owner: owner, host: host,
                           generation: state.generation, viewport: viewport, idle: state.idle)
        } ?? nil
        guard let pending else { return false }
        queue.async { [self, pending] in process(pending) }
        return true
    }

    private func current(_ pending: Pending) -> Bool {
        state.withLock { $0.owner == pending.owner && $0.host == pending.host && $0.generation == pending.generation && !$0.flushing }
    }

    private func process(_ pending: Pending) {
        defer {
            pending.input = nil
            state.withLock { if $0.permit == pending.ticket { $0.permit = nil } }
        }
        guard current(pending), let display else { state.withLock { $0.statistics.retiredDrops &+= 1 }; return }
        guard !display.failed() else { fail(pending); return }
        guard display.ready() else { state.withLock { $0.statistics.readinessDrops &+= 1 }; return }
        beforeCopy?()
        guard current(pending) else { state.withLock { $0.statistics.retiredDrops &+= 1 }; return }
        // `copy`'s source locals die on return; clear the sole queued input reference
        // before any sample is offered to the display renderer.
        let copied = copy(pending)
        pending.input = nil
        guard let copied else { return }
        guard current(pending) else { state.withLock { $0.statistics.retiredDrops &+= 1 }; return }
        guard display.ready() else { state.withLock { $0.statistics.readinessDrops &+= 1 }; return }
        guard let sample = makeSample(copied.frame) else { fail(pending); return }
        let displaySample = Sample(value: sample)
        let geometry = copied.geometry
        let event = state.withLock { state -> (@Sendable (Event) -> Void)? in
            guard state.generation == pending.generation, state.owner == pending.owner,
                  state.host == pending.host, !state.flushing else {
                state.statistics.retiredDrops &+= 1
                return nil
            }
            // Retirement and enqueue share the final liveness boundary. Producers
            // use try-lock admission, so native enqueue cannot hold up the encoder.
            display.enqueue(displaySample)
            state.statistics.enqueued &+= 1
            guard state.geometry != geometry else { return nil }
            state.geometry = geometry
            return state.event
        }
        event?(.firstFrameOrGeometry(owner: pending.owner, host: pending.host, geometry: geometry))
    }

    private func copy(_ pending: Pending) -> CopiedFrame? {
        let source: PixelBufferBox
        switch pending.input {
        case .recorded(let frame): source = frame
        case .idle(let frame):
            guard let composed = idleRenderer.render(frame, configuration: pending.idle) else { fail(pending); return nil }
            source = composed
        case nil: return nil
        }
        let key = PoolKey(width: Int(pending.viewport.pixelSize.width), height: Int(pending.viewport.pixelSize.height),
                          format: CVPixelBufferGetPixelFormatType(source.value))
        if poolKey != key {
            // A live format change requires a flushed generation before another
            // pool can be allocated; never overlap two active pool budgets.
            guard poolKey == nil else { fail(pending); return nil }
            // Only two current-pool buffers: the third slot is reserved for the last
            // displayed image retained across a flushed/retired pool generation.
            clearPool()
            let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: key.width,
                kCVPixelBufferHeightKey as String: key.height, kCVPixelBufferPixelFormatTypeKey as String: key.format,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { fail(pending); return nil }
            poolKey = key
        }
        guard let pool else { fail(pending); return nil }
        var destination: CVPixelBuffer?
        let allocated = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: 2] as CFDictionary, &destination)
        if allocated == kCVReturnWouldExceedAllocationThreshold { state.withLock { $0.statistics.poolDrops &+= 1 }; return nil }
        guard allocated == kCVReturnSuccess, let destination else { fail(pending); return nil }
        if transfer == nil, VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) != noErr {
            fail(pending); return nil
        }
        guard let transfer, VTPixelTransferSessionTransferImage(transfer, from: source.value, to: destination) == noErr else {
            fail(pending); return nil
        }
        let sx = pending.viewport.pixelSize.width / source.pixelSize.width
        let sy = pending.viewport.pixelSize.height / source.pixelSize.height
        let rect = source.contentRect.map { CGRect(x: $0.minX * sx, y: $0.minY * sy, width: $0.width * sx, height: $0.height * sy) }
        return CopiedFrame(frame: PixelBufferBox(destination, cameraContentRect: rect, pts: source.pts,
                                                sequence: source.sequence, epoch: source.epoch),
                           geometry: Geometry(pixelSize: source.pixelSize, contentRect: source.contentRect))
    }

    private func makeSample(_ frame: PixelBufferBox) -> CMSampleBuffer? {
        if format == nil, CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame.value,
                                                                      formatDescriptionOut: &format) != noErr { return nil }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: frame.pts.isNumeric ? frame.pts : .zero,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: frame.value, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { return nil }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        return sample
    }

    private func fail(_ pending: Pending) {
        let event = state.withLock { state -> (@Sendable (Event) -> Void)? in
            guard state.generation == pending.generation, state.owner == pending.owner else { return nil }
            state.statistics.failures &+= 1
            return state.event
        }
        retire(owner: pending.owner)
        event?(.failed(owner: pending.owner, host: pending.host))
    }

    private func clearPool() { pool = nil; poolKey = nil; format = nil }
    private func idleSnapshot() -> (StudioSampleFrame, UUID)? {
        state.withLock {
            guard let owner = $0.owner, let frame = $0.latestIdle, !$0.flushing else { return nil }
            return (frame, owner)
        }
    }
    private func updateCameraTimer() {
        cameraTimer?.cancel()
        cameraTimer = nil
        let refresh = state.withLock { state -> Int? in
            guard state.owner != nil, state.host != nil, state.idle.cameraSource != nil else { return nil }
            return state.viewport?.refreshRate
        }
        guard let refresh else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / refresh), leeway: .microseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, let frame = self.idleSnapshot() else { return }
            self.offer(.idle(frame.0), owner: frame.1)
        }
        cameraTimer = timer
        timer.resume()
    }
    private func flush(generation: UInt64, host: UUID?) {
        let complete: @Sendable () -> Void = { [self] in
            queue.async { [self] in
                guard state.withLock({ $0.generation == generation && $0.host == host }) else { return }
                clearPool()
                state.withLock { $0.flushing = false }
                updateCameraTimer()
            }
        }
        if let display { display.flush(complete) } else { complete() }
    }

    /// A causal queue barrier for tests; it makes no claim about actual presentation.
    func drain() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
}
