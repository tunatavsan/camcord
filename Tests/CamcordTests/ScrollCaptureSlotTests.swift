import Testing

@testable import Camcord

@Suite("Scroll capture ownership", .serialized)
@MainActor
struct ScrollCaptureSlotTests {
    @Test("ownership never overlaps and a stale release cannot free the current owner")
    func tokenOwnershipIsExclusive() throws {
        let slot = ScrollCaptureSlot()
        let first = try #require(slot.acquireIfAvailable())
        #expect(slot.acquireIfAvailable() == nil)

        slot.release(first)
        let second = try #require(slot.acquireIfAvailable())
        slot.release(first)
        #expect(slot.isOccupied)
        #expect(slot.acquireIfAvailable() == nil)

        slot.release(second)
        #expect(!slot.isOccupied)
    }

    @Test("a delayed settled frame cannot clear movement that arrived during capture")
    func settledFramePreservesNewGesture() {
        var debt = ScrollCaptureDebt(accumulatedDeltaPoints: 146, settleGeneration: 11,
                                     pendingCapture: true, pendingSettledCapture: true,
                                     needsSettledFrame: true)
        let captureGeneration = debt.settleGeneration
        debt.settleGeneration += 1
        debt.accumulatedDeltaPoints += 220

        let staleCompletion = debt.resolveSettledFrame(succeeded: true, generation: captureGeneration)
        #expect(!staleCompletion)
        #expect(debt.needsSettledFrame)
        #expect(debt.accumulatedDeltaPoints == 366)
        #expect(debt.pendingCapture)
        #expect(debt.pendingSettledCapture)
        let failedCapture = debt.resolveSettledFrame(succeeded: false, generation: debt.settleGeneration)
        #expect(!failedCapture)
        #expect(debt.needsSettledFrame)

        let currentCompletion = debt.resolveSettledFrame(succeeded: true, generation: debt.settleGeneration)
        #expect(currentCompletion)
        #expect(!debt.needsSettledFrame)
        #expect(debt.accumulatedDeltaPoints == 366)
    }
}
