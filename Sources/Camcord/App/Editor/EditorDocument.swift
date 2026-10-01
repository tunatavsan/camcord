import Foundation
import CoreGraphics

/// All persistent geometry is measured in source pixels, with origin at the top left.
struct EditorColor: Codable, Equatable, Sendable {
    var red: Double, green: Double, blue: Double, alpha: Double = 1
    static let ink = EditorColor(red: 0.92, green: 0.18, blue: 0.22)
    static let black = EditorColor(red: 0, green: 0, blue: 0)
    static let paper = EditorColor(red: 0.94, green: 0.95, blue: 0.97)
    var valid: Bool { [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

enum EditorTool: String, CaseIterable, Codable, Sendable {
    case select, arrow, rectangle, text, highlight, step, blur, pixelate, redact, crop
    var symbol: String {
        switch self {
        case .select: "cursorarrow"; case .arrow: "arrow.up.right"; case .rectangle: "rectangle"
        case .text: "textformat"; case .highlight: "highlighter"; case .step: "1.circle"
        case .blur: "drop.halffull"; case .pixelate: "square.grid.3x3"; case .redact: "rectangle.fill"; case .crop: "crop"
        }
    }
}

struct EditorStyle: Codable, Equatable, Sendable {
    var color = EditorColor.ink
    var lineWidth: Double = 4
    var fontSize: Double = 28
    var effectSize: Double = 12
    var textBackground = false
    private enum CodingKeys: String, CodingKey { case color, lineWidth, fontSize, effectSize, textBackground }
    init(color: EditorColor = .ink, lineWidth: Double = 4, fontSize: Double = 28, effectSize: Double = 12, textBackground: Bool = false) {
        self.color = color; self.lineWidth = lineWidth; self.fontSize = fontSize; self.effectSize = effectSize; self.textBackground = textBackground
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        color = try values.decode(EditorColor.self, forKey: .color)
        lineWidth = try values.decode(Double.self, forKey: .lineWidth)
        fontSize = try values.decode(Double.self, forKey: .fontSize)
        effectSize = try values.decode(Double.self, forKey: .effectSize)
        textBackground = try values.decodeIfPresent(Bool.self, forKey: .textBackground) ?? false
    }
    var valid: Bool { color.valid && lineWidth.isFinite && (1...100).contains(lineWidth) && fontSize.isFinite && (8...400).contains(fontSize) && effectSize.isFinite && (2...100).contains(effectSize) }
}

struct EditorAnnotation: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var kind: EditorTool
    var rect: CGRect
    var style = EditorStyle()
    var text = ""
    var stepNumber = 1
    /// Arrow endpoint orientation is retained even when a drag is reversed.
    var reversedX = false
    var reversedY = false
    var horizontalArrow = false
    var verticalArrow = false
    var arrowStart: CGPoint? = nil
    var arrowEnd: CGPoint? = nil
    var resolvedArrowEndpoints: (start: CGPoint, end: CGPoint) {
        if let arrowStart, let arrowEnd { return (arrowStart, arrowEnd) }
        return (CGPoint(x: verticalArrow ? rect.midX : (reversedX ? rect.maxX : rect.minX), y: horizontalArrow ? rect.midY : (reversedY ? rect.maxY : rect.minY)),
                CGPoint(x: verticalArrow ? rect.midX : (reversedX ? rect.minX : rect.maxX), y: horizontalArrow ? rect.midY : (reversedY ? rect.minY : rect.maxY)))
    }
    var valid: Bool {
        let pair = resolvedArrowEndpoints
        let geometry = kind == .arrow ? [pair.start.x, pair.start.y, pair.end.x, pair.end.y].allSatisfy(\.isFinite) && hypot(pair.end.x - pair.start.x, pair.end.y - pair.start.y) > 0 : !rect.isEmpty
        return EditorGeometry.valid(rect) && geometry && style.valid && text.utf8.count <= 16_384 && (1...9999).contains(stepNumber) && kind != .select && kind != .crop
    }
    init(id: UUID = UUID(), kind: EditorTool, rect: CGRect, style: EditorStyle = EditorStyle(), text: String = "", stepNumber: Int = 1, reversedX: Bool = false, reversedY: Bool = false, horizontalArrow: Bool = false, verticalArrow: Bool = false, arrowStart: CGPoint? = nil, arrowEnd: CGPoint? = nil) {
        self.id = id; self.kind = kind; self.rect = rect; self.style = style; self.text = text; self.stepNumber = stepNumber
        self.reversedX = reversedX; self.reversedY = reversedY; self.horizontalArrow = horizontalArrow; self.verticalArrow = verticalArrow
        self.arrowStart = kind == .arrow ? arrowStart : nil; self.arrowEnd = kind == .arrow ? arrowEnd : nil
        if kind == .arrow, let arrowStart, let arrowEnd { setArrowEndpoints(start: arrowStart, end: arrowEnd) }
    }
    private enum CodingKeys: String, CodingKey { case id, kind, rect, style, text, stepNumber, reversedX, reversedY, horizontalArrow, verticalArrow, arrowStart, arrowEnd }
    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try v.decode(UUID.self, forKey: .id), kind: try v.decode(EditorTool.self, forKey: .kind), rect: try v.decode(CGRect.self, forKey: .rect), style: try v.decode(EditorStyle.self, forKey: .style), text: try v.decode(String.self, forKey: .text), stepNumber: try v.decode(Int.self, forKey: .stepNumber), reversedX: try v.decodeIfPresent(Bool.self, forKey: .reversedX) ?? false, reversedY: try v.decodeIfPresent(Bool.self, forKey: .reversedY) ?? false, horizontalArrow: try v.decodeIfPresent(Bool.self, forKey: .horizontalArrow) ?? false, verticalArrow: try v.decodeIfPresent(Bool.self, forKey: .verticalArrow) ?? false, arrowStart: try v.decodeIfPresent(CGPoint.self, forKey: .arrowStart), arrowEnd: try v.decodeIfPresent(CGPoint.self, forKey: .arrowEnd))
        if kind == .arrow, arrowStart == nil || arrowEnd == nil { let pair = resolvedArrowEndpoints; setArrowEndpoints(start: pair.start, end: pair.end) }
    }
    mutating func setArrowEndpoints(start: CGPoint, end: CGPoint) {
        arrowStart = start; arrowEnd = end
        rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
    mutating func setRect(_ target: CGRect) {
        if kind == .arrow {
            let pair = resolvedArrowEndpoints, old = rect
            func map(_ p: CGPoint) -> CGPoint { CGPoint(x: old.width > 0 ? target.minX + (p.x - old.minX) * target.width / old.width : target.midX, y: old.height > 0 ? target.minY + (p.y - old.minY) * target.height / old.height : target.midY) }
            setArrowEndpoints(start: map(pair.start), end: map(pair.end))
        } else { rect = target }
    }
}

struct EditorBackground: Codable, Equatable, Sendable {
    enum Preset: String, CaseIterable, Codable, Sendable { case none, paper, graphite, gradient }
    enum ImageCorners: String, CaseIterable, Codable, Sendable { case auto, square, rounded }
    var preset: Preset = .none
    var padding: Double = 40
    var cornerRadius: Double = 12
    var frameWidth: Double = 0
    var shadow: Bool = true
    var color = EditorColor.paper
    var imageCorners: ImageCorners = .auto
    init(preset: Preset = .none, padding: Double = 40, cornerRadius: Double = 12, frameWidth: Double = 0, shadow: Bool = true, color: EditorColor = .paper, imageCorners: ImageCorners = .auto) {
        self.preset = preset; self.padding = padding; self.cornerRadius = cornerRadius; self.frameWidth = frameWidth; self.shadow = shadow; self.color = color; self.imageCorners = imageCorners
    }
    private enum CodingKeys: String, CodingKey { case preset, padding, cornerRadius, frameWidth, shadow, color, imageCorners }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(preset: try values.decode(Preset.self, forKey: .preset), padding: try values.decode(Double.self, forKey: .padding), cornerRadius: try values.decode(Double.self, forKey: .cornerRadius), frameWidth: try values.decode(Double.self, forKey: .frameWidth), shadow: try values.decode(Bool.self, forKey: .shadow), color: try values.decode(EditorColor.self, forKey: .color), imageCorners: try values.decodeIfPresent(ImageCorners.self, forKey: .imageCorners) ?? .auto)
    }
    var valid: Bool { color.valid && padding.isFinite && (0...1000).contains(padding) && cornerRadius.isFinite && (0...500).contains(cornerRadius) && frameWidth.isFinite && (0...100).contains(frameWidth) }
}

/// Undo entries contain edits only. The immutable source image is retained once.
struct EditorEdits: Equatable, Sendable {
    var annotations: [EditorAnnotation] = []
    var crop: CGRect
    var background = EditorBackground()
    var valid: Bool { annotations.count <= 500 && annotations.allSatisfy(\.valid) && EditorGeometry.valid(crop) && !crop.isEmpty && background.valid }
}

struct EditorDocument: Sendable {
    let id: UUID
    let source: CGImage
    let sourceURL: URL?
    let pointSize: CGSize
    var edits: EditorEdits
    var bounds: CGRect { CGRect(x: 0, y: 0, width: source.width, height: source.height) }
    init(id: UUID = UUID(), source: CGImage, sourceURL: URL? = nil, pointSize: CGSize? = nil) throws {
        try EditorGeometry.validateDimensions(width: source.width, height: source.height, pixels: 50_000_000)
        self.id = id; self.source = source; self.sourceURL = sourceURL
        let supplied = pointSize ?? CGSize(width: source.width, height: source.height)
        func safePoints(_ value: CGFloat, pixels: Int) -> CGFloat {
            let density = CGFloat(pixels) * 72 / value
            return value.isFinite && value > 0 && density.isFinite && (36...1200).contains(density) ? value : CGFloat(pixels)
        }
        self.pointSize = CGSize(width: safePoints(supplied.width, pixels: source.width), height: safePoints(supplied.height, pixels: source.height))
        self.edits = EditorEdits(crop: CGRect(x: 0, y: 0, width: source.width, height: source.height))
    }
}

enum EditorError: Error, LocalizedError, Sendable {
    case invalidImage, limit, invalidEdits, render, stale, unsaved, sourceOverwrite, busy, unsafeTemporaryDirectory
    var errorDescription: String? {
        switch self {
        case .invalidImage: String(localized: "This image could not be opened. Choose a PNG, JPEG or TIFF image.")
        case .limit: String(localized: "This image is too large to edit safely.")
        case .invalidEdits: String(localized: "The edit contains invalid image coordinates.")
        case .render: String(localized: "The edited image could not be rendered.")
        case .stale: String(localized: "The image changed. Try the action again.")
        case .unsaved: String(localized: "Export or discard your current edits before opening another image.")
        case .busy: String(localized: "An image export is already in progress.")
        case .sourceOverwrite: String(localized: "Choose a different file name to preserve the original image.")
        case .unsafeTemporaryDirectory: String(localized: "A private export file could not be created safely.")
        }
    }
}

enum EditorGeometry {
    static func valid(_ rect: CGRect) -> Bool { [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy(\.isFinite) && rect.width >= 0 && rect.height >= 0 }
    static func validateDimensions(width: Int, height: Int, pixels: Int) throws {
        guard width > 0, height > 0, width <= 40_000, height <= 40_000, width <= pixels / height else { throw EditorError.limit }
    }
    static func drag(from: CGPoint, to: CGPoint, bounds: CGRect) -> CGRect {
        guard [from.x, from.y, to.x, to.y].allSatisfy(\.isFinite) else { return .zero }
        return CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y)).intersection(bounds)
    }
    static func pixelRect(_ rect: CGRect, bounds: CGRect) -> CGRect {
        guard valid(rect) else { return .zero }
        return rect.integral.intersection(bounds)
    }
    static func sourcePoint(view: CGPoint, origin: CGPoint, zoom: CGFloat) -> CGPoint? {
        guard zoom.isFinite, zoom > 0, view.x.isFinite, view.y.isFinite else { return nil }
        return CGPoint(x: (view.x - origin.x) / zoom, y: (view.y - origin.y) / zoom)
    }
    static func visionRect(_ normalized: CGRect, width: Int, height: Int) -> CGRect {
        guard valid(normalized) else { return .zero }
        return CGRect(x: normalized.minX * CGFloat(width), y: (1 - normalized.maxY) * CGFloat(height), width: normalized.width * CGFloat(width), height: normalized.height * CGFloat(height)).intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }
    static func hit(_ point: CGPoint, annotations: [EditorAnnotation], zoom: CGFloat) -> UUID? {
        guard zoom > 0, zoom.isFinite else { return nil }
        return annotations.reversed().first { $0.rect.insetBy(dx: -6 / zoom, dy: -6 / zoom).contains(point) }?.id
    }
}
