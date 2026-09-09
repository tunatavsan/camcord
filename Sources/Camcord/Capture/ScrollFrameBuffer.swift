import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Owns immutable copies of complete ScreenCaptureKit frames without retaining stream
/// pixel buffers or their IOSurfaces.
final class ScrollFrameBuffer: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let image: CGImage
        let seq: UInt64
    }

    struct Stats: Sendable, Equatable {
        let pendingFrameCount: Int
        let ownedBytes: Int
        let droppedFrames: UInt64
    }

    private struct Entry: @unchecked Sendable {
        let frame: Frame
        let byteCount: Int
    }

    private struct State {
        var pending: [Entry] = []
        var pendingBytes = 0
        var latest: Entry?
        var nextSequence: UInt64 = 0
        var droppedFrames: UInt64 = 0
        var intakeGeneration: UInt64 = 0
        var acceptingFrames = true
        var closed = false
    }

    private let lock = NSLock()
    private let maximumBytes: Int
    private let maximumFrames: Int
    private let onFrame: @Sendable () -> Void
    private var state = State()

    init(
        maximumBytes: Int = 1024 * 1024 * 1024,
        maximumFrames: Int = 90,
        onFrame: @escaping @Sendable () -> Void = {}
    ) {
        self.maximumBytes = max(0, maximumBytes)
        self.maximumFrames = max(0, maximumFrames)
        self.onFrame = onFrame
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        ingest(sampleBuffer, of: type)
    }

    /// Internal entry point keeps the delegate's validation and ownership path testable without
    /// constructing a live SCStream or requesting screen-capture permission.
    func ingest(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
            sampleBuffer.isValid,
            isComplete(sampleBuffer),
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
            CVPixelBufferGetPlaneCount(pixelBuffer) == 0,
            let byteCount = Self.storageSize(pixelBuffer)
        else { return }

        lock.lock()
        guard state.acceptingFrames, !state.closed else {
            lock.unlock()
            return
        }
        let intakeGeneration = state.intakeGeneration
        guard maximumFrames > 0, byteCount <= maximumBytes else {
            state.droppedFrames &+= 1
            lock.unlock()
            return
        }
        lock.unlock()

        guard let image = Self.copyImage(pixelBuffer, byteCount: byteCount) else { return }

        lock.lock()
        guard state.acceptingFrames, !state.closed,
            state.intakeGeneration == intakeGeneration
        else {
            lock.unlock()
            return
        }
        state.nextSequence &+= 1
        let entry = Entry(
            frame: Frame(image: image, seq: state.nextSequence),
            byteCount: byteCount
        )
        state.pending.append(entry)
        state.pendingBytes += entry.byteCount
        state.latest = entry

        while state.pending.count > maximumFrames || state.pendingBytes > maximumBytes {
            let removed = state.pending.removeFirst()
            state.pendingBytes -= removed.byteCount
            state.droppedFrames &+= 1
        }
        lock.unlock()

        onFrame()
    }

    /// Stops accepting new frames while preserving pending and latest owned snapshots.
    /// Advancing the generation also rejects a copy that began before this call.
    func suspendIntake() {
        lock.lock()
        guard !state.closed else {
            lock.unlock()
            return
        }
        state.acceptingFrames = false
        state.intakeGeneration &+= 1
        lock.unlock()
    }

    /// Resumes intake after a temporary suspension. A permanently closed buffer stays closed.
    func resumeIntake() {
        lock.lock()
        guard !state.closed, !state.acceptingFrames else {
            lock.unlock()
            return
        }
        state.intakeGeneration &+= 1
        state.acceptingFrames = true
        lock.unlock()
    }

    /// Permanently rejects future frames and releases every snapshot owned by the buffer.
    func close() {
        lock.lock()
        guard !state.closed else {
            lock.unlock()
            return
        }
        state.closed = true
        state.acceptingFrames = false
        state.intakeGeneration &+= 1
        state.pending.removeAll()
        state.pendingBytes = 0
        state.latest = nil
        lock.unlock()
    }

    func peekLatest() -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        return state.latest?.frame
    }

    func frames(after sequence: UInt64) -> [Frame] {
        lock.lock()
        defer { lock.unlock() }
        return state.pending.lazy
            .map(\.frame)
            .filter { $0.seq > sequence }
    }

    /// Transfers one owned frame at a time. A slow batch must not retain every
    /// already-consumed Retina image while the producer fills another whole batch.
    func takeNext(after sequence: UInt64, through lastSequence: UInt64) -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        while let first = state.pending.first, first.frame.seq <= sequence {
            state.pendingBytes -= state.pending.removeFirst().byteCount
        }
        guard let first = state.pending.first, first.frame.seq <= lastSequence else { return nil }
        state.pending.removeFirst()
        state.pendingBytes -= first.byteCount
        return first.frame
    }

    func discard(through sequence: UInt64) {
        lock.lock()
        let firstRemaining = state.pending.firstIndex { $0.frame.seq > sequence }
            ?? state.pending.endIndex
        if firstRemaining > state.pending.startIndex {
            for entry in state.pending[..<firstRemaining] {
                state.pendingBytes -= entry.byteCount
            }
            state.pending.removeFirst(firstRemaining)
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        state.intakeGeneration &+= 1
        state.pending.removeAll()
        state.pendingBytes = 0
        state.latest = nil
        state.nextSequence = 0
        state.droppedFrames = 0
        if !state.closed { state.acceptingFrames = true }
        lock.unlock()
    }

    /// Storage currently retained by this buffer. Frames copied out by a caller are not counted.
    var stats: Stats {
        lock.lock()
        defer { lock.unlock() }
        let latestIsPending = state.latest.map { latest in
            state.pending.last?.frame.seq == latest.frame.seq
        } ?? false
        return Stats(
            pendingFrameCount: state.pending.count,
            ownedBytes: state.pendingBytes + (latestIsPending ? 0 : state.latest?.byteCount ?? 0),
            droppedFrames: state.droppedFrames
        )
    }

    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int
        else { return false }
        return SCFrameStatus(rawValue: rawStatus) == .complete
    }

    private static func storageSize(_ pixelBuffer: CVPixelBuffer) -> Int? {
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let (byteCount, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !overflow, byteCount > 0 else { return nil }
        return byteCount
    }

    private static func copyImage(_ pixelBuffer: CVPixelBuffer, byteCount: Int) -> CGImage? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow / 4 >= width,
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
            let data = CFDataCreate(
                kCFAllocatorDefault,
                baseAddress.assumingMemoryBound(to: UInt8.self),
                byteCount
            ),
            let provider = CGDataProvider(data: data)
        else { return nil }

        let colorSpace = CVImageBufferGetColorSpace(pixelBuffer)?.takeUnretainedValue()
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
