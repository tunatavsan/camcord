import Foundation

enum CameraCorner: String, Codable, CaseIterable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

struct CameraOptions: Codable, Equatable, Sendable {
    static let aspectRatio: CGFloat = 16.0 / 9.0
    static let widthRange = 0.08...0.60
    /// The camera tile's corner, on screen and in the file. A fraction rather than a constant
    /// because the same placement is composited at video resolution, and it is tuned so a
    /// 320x180 preview lands exactly on `CamcordStyle.Radius.surface` -- the app's one corner.
    static func cornerRadius(for size: CGSize) -> CGFloat { min(size.width, size.height) * 0.10 }

    /// Hairline that separates the tile from whatever is behind it — one physical line at
    /// preview sizes, still visible after a 4K downscale.
    static func edgeHighlightWidth(for size: CGSize) -> CGFloat {
        max(1, min(size.width, size.height) * 0.006)
    }

    /// The tile's edge is glass, not a border: the hairline carries a diagonal gradient of
    /// light — bright where the light falls, almost gone at the opposite corner — so it
    /// separates the tile from the desktop without laying a flat white line over the video.
    /// Both renderers read these two numbers: the floating preview strokes them, the
    /// compositor draws the same gradient into the file.
    static let edgeHighlight: (bright: CGFloat, dim: CGFloat) = (0.55, 0.10)
    /// A darker line immediately inside the hairline. Light content behind the tile swallows
    /// a light-only edge; this is what keeps the boundary readable over a white window.
    static let edgeShadowAlpha: CGFloat = 0.25
    static func edgeShadowWidth(for size: CGSize) -> CGFloat { edgeHighlightWidth(for: size) / 2 }

    /// The tile's drop shadow, in fractions of its short side so the preview's points and
    /// the encoded frame's pixels drop the SAME shadow. At the 320x180 reference tile the
    /// numbers are blur 18, y -6, alpha 0.35 — soft and low, a lift rather than a border.
    static func shadow(for size: CGSize) -> (blur: CGFloat, offsetY: CGFloat, alpha: CGFloat) {
        let short = min(size.width, size.height)
        return (blur: short / 10, offsetY: -short / 30, alpha: 0.35)
    }

    var enabled: Bool
    var deviceID: String?
    var corner: CameraCorner
    var widthFraction: Double
    var mirrored: Bool
    /// Unit coordinates in the available travel area, with the origin at bottom-left.
    var position: CameraPosition?
    /// The owner's manual format per camera, keyed by `formatKey(deviceID)`; a camera with
    /// no entry is on Auto.
    var formats: [String: CameraFormatChoice] = [:]

    /// The format choice for the selected camera.
    var format: CameraFormatChoice {
        get { formats[Self.formatKey(deviceID)] ?? .auto }
        set { formats[Self.formatKey(deviceID)] = newValue == .auto ? nil : newValue }
    }

    /// The system default camera has no stored ID; it gets its own key.
    static func formatKey(_ deviceID: String?) -> String { deviceID ?? "default" }

    init(
        enabled: Bool = false,
        deviceID: String? = nil,
        corner: CameraCorner = .bottomRight,
        widthFraction: Double = 0.22,
        mirrored: Bool = true,
        position: CameraPosition? = nil
    ) {
        self.enabled = enabled
        self.deviceID = deviceID
        self.corner = corner
        self.widthFraction = widthFraction
        self.mirrored = mirrored
        self.position = position
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CameraOptions()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        corner = (try? container.decodeIfPresent(CameraCorner.self, forKey: .corner))
            ?? defaults.corner
        widthFraction = try container.decodeIfPresent(Double.self, forKey: .widthFraction)
            ?? defaults.widthFraction
        mirrored = try container.decodeIfPresent(Bool.self, forKey: .mirrored) ?? defaults.mirrored
        position = try container.decodeIfPresent(CameraPosition.self, forKey: .position)
        // Older settings have no formats; an entry this build cannot read is dropped alone.
        formats = (try? container.decodeIfPresent([String: FailableChoice].self, forKey: .formats))?
            .compactMapValues(\.choice) ?? [:]
    }

    private struct FailableChoice: Decodable {
        let choice: CameraFormatChoice?
        init(from decoder: Decoder) throws { choice = try? CameraFormatChoice(from: decoder) }
    }

    /// Sanitizes persisted/external values before they reach capture or layout math.
    func resolved() -> CameraOptions {
        var result = self
        let trimmed = deviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        result.deviceID = trimmed?.isEmpty == false ? trimmed : nil
        result.widthFraction = widthFraction.isFinite
            ? min(max(widthFraction, Self.widthRange.lowerBound), Self.widthRange.upperBound)
            : 0.22
        result.position = position?.resolved()
        return result
    }

    /// Shared by the live window and the video compositor; moving the preview moves
    /// the camera in the recording, without a second layout or an export pass.
    func rect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let options = resolved()
        let margin = Self.margin(in: size)
        var width = min(max(1, size.width - margin * 2), size.width * options.widthFraction)
        var height = width / Self.aspectRatio
        if height > size.height * 0.65 {
            width *= size.height * 0.65 / height
            height = size.height * 0.65
        }
        let position = options.position ?? CameraPosition(corner: options.corner)
        return CGRect(
            x: margin + max(0, size.width - margin * 2 - width) * position.x,
            y: margin + max(0, size.height - margin * 2 - height) * position.y,
            width: width, height: height
        )
    }

    static func margin(in size: CGSize) -> CGFloat {
        // Proportional in both AppKit points and encoded pixels: a fixed minimum
        // would place the video camera closer to the edge than its Retina preview.
        min(size.width, size.height) * 0.03
    }

    /// Hysteresis keeps the attraction stable around the capture area's inset corners.
    /// The pointer is never warped; only the camera is pulled toward its resting place.
    /// `reach` overrides the proximity limit — a release projects its throw and must be
    /// able to pick the nearest corner from anywhere in the frame.
    static func magnet(for rect: CGRect, in size: CGSize, latched: CameraCorner?,
                       reach limit: CGFloat? = nil) -> (rect: CGRect, corner: CameraCorner)? {
        let margin = margin(in: size)
        func destination(_ corner: CameraCorner) -> CGRect {
            let unit = CameraPosition(corner: corner)
            return CGRect(x: margin + max(0, size.width - margin * 2 - rect.width) * unit.x,
                          y: margin + max(0, size.height - margin * 2 - rect.height) * unit.y,
                          width: rect.width, height: rect.height)
        }
        let reach = limit ?? min(84, min(size.width, size.height) * 0.18)
        let candidates = latched.map { [$0] } ?? CameraCorner.allCases
        let nearest = candidates.min {
            hypot(destination($0).minX - rect.minX, destination($0).minY - rect.minY)
                < hypot(destination($1).minX - rect.minX, destination($1).minY - rect.minY)
        }
        guard let nearest else { return nil }
        let target = destination(nearest)
        let distance = hypot(target.minX - rect.minX, target.minY - rect.minY)
        guard distance <= reach * (latched == nil ? 1 : 1.4) else { return nil }
        return (target, nearest)
    }

    mutating func place(_ rect: CGRect, in size: CGSize, snapDistance: CGFloat = 0) {
        let margin = Self.margin(in: size)
        let travelX = max(1, size.width - margin * 2 - rect.width)
        let travelY = max(1, size.height - margin * 2 - rect.height)
        var point = CameraPosition(x: (rect.minX - margin) / travelX, y: (rect.minY - margin) / travelY).resolved()
        if snapDistance > 0 {
            for corner in CameraCorner.allCases {
                let candidate = CameraPosition(corner: corner)
                if hypot((point.x - candidate.x) * travelX, (point.y - candidate.y) * travelY) <= snapDistance {
                    point = candidate
                    self.corner = corner
                    break
                }
            }
        }
        position = point
    }
}

struct CameraPosition: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) { self.x = x; self.y = y }
    init(corner: CameraCorner) {
        x = corner == .topRight || corner == .bottomRight ? 1 : 0
        y = corner == .topLeft || corner == .topRight ? 1 : 0
    }
    func resolved() -> Self {
        Self(x: x.isFinite ? min(max(x, 0), 1) : 1,
             y: y.isFinite ? min(max(y, 0), 1) : 0)
    }
}
