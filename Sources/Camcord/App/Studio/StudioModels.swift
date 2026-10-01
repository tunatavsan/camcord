import CoreGraphics
import Foundation

struct StudioSourceChoice: Identifiable, Equatable, Sendable {
    enum ID: Hashable, Sendable { case display(UInt32), window(UInt32), region(UInt32) }
    let id: ID
    let title: String
    let frame: CGRect
    let pixelSize: CGSize
}

enum StudioPreviewState: Equatable, Sendable {
    case inactive, noSource, starting, live, recording, paused, permissionRequired, unavailable
}

enum StudioIssue: Error, Equatable, Sendable {
    case screenPermissionRequired, sourceUnavailable, sourceListUnavailable
    case previewFailed, layerLimit, imageTooLarge, invalidImage, textTooLong
}

struct StudioTextStyle: Equatable, Sendable {
    var fontSize: Double = 48
    var bold = true
    var red: Double = 1
    var green: Double = 1
    var blue: Double = 1
    var alpha: Double = 1

    func resolved() -> Self {
        var result = self
        result.fontSize = fontSize.isFinite ? min(256, max(8, fontSize)) : 48
        result.red = Self.unit(red)
        result.green = Self.unit(green)
        result.blue = Self.unit(blue)
        result.alpha = Self.unit(alpha)
        return result
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 1
    }
}

struct StudioLayer: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case text, image, logo }
    let id: UUID
    var kind: Kind
    var name: String
    var text: String
    var rect: CGRect
    var opacity: Double
    var isVisible: Bool
    var textStyle: StudioTextStyle

    init(id: UUID = UUID(), kind: Kind, name: String, text: String = "",
         rect: CGRect = CGRect(x: 0.05, y: 0.05, width: 0.4, height: 0.15),
         opacity: Double = 1, isVisible: Bool = true, textStyle: StudioTextStyle = .init()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.text = text
        self.rect = rect
        self.opacity = opacity
        self.isVisible = isVisible
        self.textStyle = textStyle
    }

    func resolved() -> Self {
        var result = self
        result.rect = Self.normalized(rect)
        result.opacity = opacity.isFinite ? min(1, max(0, opacity)) : 1
        result.name = String(name.prefix(160))
        result.textStyle = textStyle.resolved()
        return result
    }

    static func normalized(_ rect: CGRect) -> CGRect {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width > 0, rect.size.height > 0 else { return .zero }
        let x = min(1, max(0, rect.origin.x)), y = min(1, max(0, rect.origin.y))
        let right = min(1, max(0, rect.origin.x + rect.size.width))
        let bottom = min(1, max(0, rect.origin.y + rect.size.height))
        return CGRect(x: x, y: y, width: max(0, right - x), height: max(0, bottom - y))
    }
}

/// The only layer payload allowed onto a media queue. CGImage is an immutable retained
/// raster; no source URL, font object, AppKit image or mutable document crosses the boundary.
struct StudioRasterLayer: Sendable {
    enum Alignment: Equatable, Sendable { case topLeading, center }
    let id: UUID
    let image: CGImage
    let rect: CGRect
    let opacity: Double
    let alignment: Alignment

    init(id: UUID, image: CGImage, rect: CGRect, opacity: Double, alignment: Alignment = .center) {
        self.id = id
        self.image = image
        self.rect = rect
        self.opacity = opacity
        self.alignment = alignment
    }
}

struct StudioLayerSnapshot: Sendable {
    static let empty = StudioLayerSnapshot(layers: [])
    let layers: [StudioRasterLayer]
    var isEmpty: Bool { layers.isEmpty }

    init(layers: [StudioRasterLayer], maximumLayers: Int = 24, maximumBytes: Int = 64 * 1024 * 1024) {
        var accepted: [StudioRasterLayer] = []
        var bytes = 0
        for layer in layers.prefix(max(0, maximumLayers)) {
            let rect = StudioLayer.normalized(layer.rect)
            let (size, overflow) = layer.image.bytesPerRow.multipliedReportingOverflow(by: layer.image.height)
            guard !overflow, size > 0, size <= maximumBytes - bytes,
                  rect.width > 0, rect.height > 0, layer.opacity.isFinite, layer.opacity > 0 else { continue }
            bytes += size
            accepted.append(StudioRasterLayer(id: layer.id, image: layer.image, rect: rect,
                                              opacity: min(1, layer.opacity), alignment: layer.alignment))
        }
        self.layers = accepted
    }
}

struct StudioLayerLimits: Sendable {
    var maximumLayers = 24
    var maximumEncodedBytes = 20 * 1024 * 1024
    var maximumImagePixels = 16_000_000
    var maximumSnapshotBytes = 64 * 1024 * 1024
    var maximumRasterDimension = 2048
    var maximumTextCharacters = 8192
}

struct StudioVisibility: Equatable, Sendable {
    var moduleVisible = false
    var windowAllowsPreview = false
    var captureTransition = false
    var allowsPreview: Bool { moduleVisible && windowAllowsPreview && !captureTransition }
}

/// Source defaults never override explicit selection, Clear, or a vanished manual source.
struct StudioDefaultSourcePolicy: Equatable, Sendable {
    private(set) var eligible = true
    private(set) var automaticID: StudioSourceChoice.ID?

    mutating func manualIntent() { eligible = false; automaticID = nil }

    mutating func choose(from choices: [StudioSourceChoice], mainDisplayID: UInt32) -> StudioSourceChoice? {
        guard eligible else { return nil }
        let displays = choices.filter { if case .display = $0.id { true } else { false } }
        guard let selected = displays.first(where: { $0.id == .display(mainDisplayID) }) ?? displays.first else { return nil }
        eligible = false
        automaticID = selected.id
        return selected
    }

    mutating func sourceDisappeared(_ id: StudioSourceChoice.ID, idle: Bool) -> Bool {
        guard idle, automaticID == id else { return false }
        eligible = true
        automaticID = nil
        return true
    }
}
