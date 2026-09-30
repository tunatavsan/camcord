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
    var valid: Bool { EditorGeometry.valid(rect) && !rect.isEmpty && style.valid && text.utf8.count <= 16_384 && (1...9999).contains(stepNumber) && kind != .select && kind != .crop }
}

struct EditorBackground: Codable, Equatable, Sendable {
    enum Preset: String, CaseIterable, Codable, Sendable { case none, paper, graphite, gradient }
    var preset: Preset = .none
    var padding: Double = 40
    var cornerRadius: Double = 12
    var frameWidth: Double = 0
    var shadow: Bool = true
    var color = EditorColor.paper
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
