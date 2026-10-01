import Foundation

/// Value snapshots cross from the serial media queue to the UI at most thirty times a
/// second. Counters describe eligible, unpaused samples, not intentional pause gaps.
struct SampleDeliveryStats: Sendable, Equatable {
    var delivered = 0
    var appended = 0
    var dropped = 0
}

struct AudioSourceHealth: Sendable, Equatable {
    let enabled: Bool
    var levels: AudioLevels?
    var lastSampleUptime: TimeInterval?
    var samples = SampleDeliveryStats()
    var processingFailed = false

    func isReceiving(at uptime: TimeInterval) -> Bool {
        lastSampleUptime.map { uptime - $0 < 2 } ?? false
    }
}

struct RecordingHealth: Sendable, Equatable {
    var compositorPoolExhaustions: UInt64 = 0
    var video = SampleDeliveryStats()
    var systemAudio: AudioSourceHealth
    var microphone: AudioSourceHealth
}

/// Immutable counters captured after the writer's serial-queue seal. The frame rate
/// is the configured interval, not a measurement of capture or displayed cadence.
struct RecordingFinalHealth: Sendable, Equatable {
    let epoch: UUID
    let health: RecordingHealth
    let nominalFPS: Double?
}
