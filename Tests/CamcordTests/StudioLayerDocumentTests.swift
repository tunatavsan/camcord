import CoreGraphics
import Foundation
import ImageIO
import Observation
import Testing
import UniformTypeIdentifiers
import os
@testable import Camcord

@Suite("Studio layer document and bounded raster work")
struct StudioLayerDocumentTests {
    @MainActor @Test("dismissal cannot promote a failed raster, and removing that layer restores readiness")
    func failedCurrentSnapshot() async throws {
        var limits = StudioLayerLimits()
        limits.maximumSnapshotBytes = 1
        let document = StudioLayerDocument(rasterizer: .init(limits: limits))
        var published: [StudioLayerSnapshot] = []
        document.onSnapshot = { published.append($0) }
        document.addText("Visible text")
        #expect(document.isRasterizing && !document.isReady)
        try await settle(document)
        #expect(document.issue == .imageTooLarge && !document.isReady)
        #expect(published.isEmpty)
        document.dismissIssue()
        #expect(document.issue == nil && !document.isReady)
        document.remove(try #require(document.layers.first?.id))
        #expect(document.isReady && !document.isRasterizing)
        #expect(published.count == 1 && published[0].isEmpty)
    }

    @MainActor @Test("rapid edits publish only the current ordered and visible layers")
    func currentDocumentRevision() async throws {
        let document = StudioLayerDocument()
        var published: [StudioLayerSnapshot] = []
        document.onSnapshot = { published.append($0) }
        document.addText("A")
        let a = try #require(document.layers.first?.id)
        document.addText("B")
        let b = try #require(document.layers.last?.id)
        document.move(b, to: 0)
        document.update(a) { $0.isVisible = false }
        try await settle(document)
        #expect(document.isReady && document.issue == nil)
        #expect(published.count == 1)
        #expect(published.first?.layers.map(\.id) == [b])
        document.update(a) { $0.isVisible = true; $0.opacity = 0.5 }
        try await settle(document)
        #expect(published.last?.layers.map(\.id) == [b, a])
        #expect(published.last?.layers.last?.opacity == 0.5)
    }

    @MainActor @Test("fixing an invalid visible asset creates a fresh successful snapshot")
    func fixFailedLayer() async throws {
        let document = StudioLayerDocument()
        document.addText("A")
        let id = try #require(document.layers.first?.id)
        document.update(id) { $0.kind = .image }
        try await settle(document)
        #expect(document.issue == .invalidImage && !document.isReady)
        document.update(id) { $0.kind = .text }
        try await settle(document)
        #expect(document.issue == nil && document.isReady)
    }

    @Test("ImageIO rejects encoded and pixel limits before making a bounded raster")
    func imageBounds() throws {
        let data = try encodedPNG(width: 16, height: 8)
        var limits = StudioLayerLimits()
        limits.maximumEncodedBytes = data.count - 1
        #expect(throws: StudioIssue.invalidImage) { try StudioLayerRasterizer.decode(data, limits: limits) }
        limits.maximumEncodedBytes = data.count
        limits.maximumImagePixels = 127
        #expect(throws: StudioIssue.imageTooLarge) { try StudioLayerRasterizer.decode(data, limits: limits) }
        limits.maximumImagePixels = 128
        limits.maximumRasterDimension = 4
        let image = try StudioLayerRasterizer.decode(data, limits: limits)
        #expect(image.width == 4 && image.height == 2)
        #expect(throws: StudioIssue.invalidImage) { try StudioLayerRasterizer.decode(Data([1, 2, 3]), limits: limits) }
    }

    @Test("a retired raster ticket rejects queued work")
    func cancelledRaster() async {
        let ticket = StudioRasterTicket()
        ticket.cancel()
        await #expect(throws: CancellationError.self) {
            try await StudioLayerRasterizer().snapshot(layers: [.init(kind: .text, name: "A", text: "A")],
                                                       assets: [:], shouldContinue: { ticket.isCurrent })
        }
    }

    @MainActor @Test("raster work permits the main actor to run while its worker is busy")
    func mainActorResponsiveness() async throws {
        let rasterizer = StudioLayerRasterizer()
        let releaseWorker = DispatchSemaphore(value: 0)
        let entered = OSAllocatedUnfairLock(initialState: Optional<CheckedContinuation<Bool, Never>>.none)
        let first = OSAllocatedUnfairLock(initialState: true)
        let completed = OSAllocatedUnfairLock(initialState: false)
        var job: Task<StudioLayerSnapshot, Error>?
        let ranOffMain = await withCheckedContinuation { continuation in
            entered.withLock { $0 = continuation }
            job = Task {
                let snapshot = try await rasterizer.snapshot(layers: [.init(kind: .text, name: "A", text: "A")], assets: [:]) {
                    let firstCall = first.withLock { value in defer { value = false }; return value }
                    if firstCall {
                        let offMain = !Thread.isMainThread
                        entered.withLock { value in value?.resume(returning: offMain); value = nil }
                        // A main-queue mutant must reach the assertion instead of blocking it.
                        guard offMain else { return true }
                        releaseWorker.wait()
                    }
                    return true
                }
                completed.withLock { $0 = true }
                return snapshot
            }
        }
        #expect(ranOffMain)
        #expect(!completed.withLock { $0 })
        // This line runs on MainActor while the raster queue is still waiting.
        releaseWorker.signal()
        let snapshot = try await #require(job).value
        #expect(snapshot.layers.count == 1)
    }

    @MainActor private func settle(_ document: StudioLayerDocument) async throws {
        await withCheckedContinuation { continuation in
            guard document.isRasterizing else { continuation.resume(); return }
            // Success and handled failure both settle this current revision's property.
            withObservationTracking { _ = document.isRasterizing } onChange: {
                // Observation fires before the setter finishes its MainActor turn.
                Task { @MainActor in continuation.resume() }
            }
        }
        try #require(!document.isRasterizing, "raster completion did not arrive")
    }

    private func encodedPNG(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
