import AVFoundation
import CoreMedia

/// The camera's capture format: Camcord's choice, or the user's. Persisted per device in
/// `CameraOptions.formats`, keyed by the device's `uniqueID`.
enum CameraFormatChoice: Codable, Hashable, Sendable {
    case auto
    case manual(width: Int, height: Int, fps: Int)
}

/// One device format, reduced to what choosing needs, so the rules run on fakes in tests.
struct CameraFormatDescriptor: Equatable, Sendable {
    var width: Int
    var height: Int
    var fpsRanges: [ClosedRange<Double>]

    init(width: Int, height: Int, fpsRanges: [ClosedRange<Double>]) {
        self.width = width
        self.height = height
        self.fpsRanges = fpsRanges
    }

    init(_ format: AVCaptureDevice.Format) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        width = Int(dimensions.width)
        height = Int(dimensions.height)
        fpsRanges = format.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate }
    }

    var area: Int { width * height }

    func supports(_ fps: Double) -> Bool {
        fpsRanges.contains { $0.contains(fps) }
    }

    /// The highest rate at or under `limit` any range reaches.
    func highestFPS(atMost limit: Double) -> Double? {
        fpsRanges.filter { $0.lowerBound <= limit }.map { min($0.upperBound, limit) }.max()
    }
}

/// A format the device will run: which descriptor, at which rate.
struct CameraFormatResolution: Equatable, Sendable {
    var index: Int
    var width: Int
    var height: Int
    var fps: Double

    var label: String { "\(width)×\(height) @ \(Int(fps.rounded()))" }
}

enum CameraFormatSelection {
    /// The rates a manual choice offers, where a format's ranges reach them.
    static let standardRates = [24, 25, 30, 50, 60, 120]
    /// Auto never asks a camera for more than this.
    static let autoRateLimit: Double = 60

    /// Auto: among formats at least 1080 tall, favor the 16:9 tile aspect, then smaller area
    /// and the highest rate ≤ 60 it runs. With
    /// nothing that tall, the largest format there is. Same-sized formats: the faster one.
    /// Landscape formats only, when the camera has any: the tile is 16:9, and a MacBook camera
    /// also lists 1080×1920 at the same size as 1920×1080.
    static func auto(_ formats: [CameraFormatDescriptor]) -> CameraFormatResolution? {
        let all = formats.enumerated().compactMap { index, format -> CameraFormatResolution? in
            format.highestFPS(atMost: autoRateLimit).map {
                CameraFormatResolution(index: index, width: format.width, height: format.height, fps: $0)
            }
        }
        let landscape = all.filter { $0.width >= $0.height }
        let usable = landscape.isEmpty ? all : landscape
        let tall = usable.filter { $0.height >= 1080 }
        if !tall.isEmpty {
            if landscape.isEmpty {
                return tall.min { ($0.width * $0.height, -$0.fps) < ($1.width * $1.height, -$1.fps) }
            }
            return tall.min {
                (abs(Double($0.width) / Double($0.height) - 16.0 / 9.0), $0.width * $0.height, -$0.fps)
                    < (abs(Double($1.width) / Double($1.height) - 16.0 / 9.0), $1.width * $1.height, -$1.fps)
            }
        }
        return usable.max { ($0.width * $0.height, $0.fps) < ($1.width * $1.height, $1.fps) }
    }

    /// The manual list: every `W×H @ fps` the device runs at a standard rate, once, sorted.
    static func manualOptions(_ formats: [CameraFormatDescriptor]) -> [CameraFormatChoice] {
        var seen = Set<CameraFormatChoice>()
        var options: [(width: Int, height: Int, fps: Int)] = []
        for format in formats {
            for rate in standardRates where format.supports(Double(rate)) {
                let choice = CameraFormatChoice.manual(width: format.width, height: format.height, fps: rate)
                if seen.insert(choice).inserted { options.append((format.width, format.height, rate)) }
            }
        }
        return options
            .sorted { ($0.width, $0.height, $0.fps) < ($1.width, $1.height, $1.fps) }
            .map { .manual(width: $0.width, height: $0.height, fps: $0.fps) }
    }

    /// What `choice` runs as on these formats. A manual format the device no longer offers
    /// (another camera, a firmware change) falls back to Auto rather than failing.
    static func resolve(_ choice: CameraFormatChoice, formats: [CameraFormatDescriptor]) -> CameraFormatResolution? {
        if case .manual(let width, let height, let fps) = choice,
           let index = formats.firstIndex(where: { $0.width == width && $0.height == height && $0.supports(Double(fps)) }) {
            return CameraFormatResolution(index: index, width: width, height: height, fps: Double(fps))
        }
        return auto(formats)
    }

    static func label(_ choice: CameraFormatChoice) -> String {
        switch choice {
        case .auto: String(localized: "Auto", comment: "Camera format: Camcord chooses")
        case .manual(let width, let height, let fps): "\(width)×\(height) @ \(fps)"
        }
    }
}
