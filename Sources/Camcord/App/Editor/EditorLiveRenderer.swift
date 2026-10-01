import AppKit
import CoreGraphics
import CoreImage
import Metal

/// Viewport patches contain their real destination pixels, so multiply highlighting
/// has the same underlay as export. No blend filter or full-source display redraw.
@MainActor final class EditorLiveRenderer {
    struct Treatment {
        let luminance: Double
        let highlight: EditorRenderer.HighlightTreatment
    }
    private var cachedBaseGeneration = -1
    private var baseEdits: EditorEdits?
    private var cachedAnnotations: [EditorAnnotation] = []
    private var treatments: [UUID: Treatment] = [:]
    private(set) var treatmentComputations = 0
    private static let privacyContext = MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice:$0,options:[.cacheIntermediates:false]) }
    private(set) var privacyPatchComputations = 0
    private var privacyCache: (region:CGRect, scale:CGFloat, image:CGImage)?
    private static func privacy(_ annotations:[EditorAnnotation]) -> [EditorAnnotation] { annotations.filter { [.redact,.blur,.pixelate].contains($0.kind) } }
    func requiresLivePrivacy(_ annotations:[EditorAnnotation]) -> Bool { Self.privacy(annotations) != Self.privacy(baseEdits?.annotations ?? cachedAnnotations) }
    func preparePrivacy(region:CGRect,scale:CGFloat,base:EditorDisplayBase,document:EditorDocument,annotations:[EditorAnnotation]) throws {
        privacyCache = nil
        _ = try privacyPatch(region:region,scale:scale,base:base,document:document,annotations:annotations)
    }
    private func privacyPatch(region:CGRect,scale:CGFloat,base:EditorDisplayBase,document:EditorDocument,annotations:[EditorAnnotation]) throws -> CGImage? {
        guard requiresLivePrivacy(annotations), let source = base.privacySource else { return nil }
        if let cached = privacyCache {
            let overlap = cached.region.intersection(region)
            guard !overlap.isNull, !overlap.isEmpty else { return nil }
            let patch = cached.image.cropping(to:CGRect(x:(overlap.minX-cached.region.minX)*cached.scale,y:(overlap.minY-cached.region.minY)*cached.scale,width:overlap.width*cached.scale,height:overlap.height*cached.scale))
            if cached.region.contains(region) { return patch }
            let output = try EditorRenderer.context(width:max(1,Int(ceil(region.width*scale))),height:max(1,Int(ceil(region.height*scale))))
            let crop = (baseEdits?.crop ?? document.edits.crop).integral
            if let original = base.underlay.cropping(to:region.offsetBy(dx:-crop.minX,dy:-crop.minY)) {
                output.draw(original,in:CGRect(x:0,y:0,width:output.width,height:output.height))
            }
            if let patch {
                output.setBlendMode(.copy)
                output.draw(patch,in:CGRect(x:(overlap.minX-region.minX)*scale,y:(region.maxY-overlap.maxY)*scale,width:overlap.width*scale,height:overlap.height*scale))
            }
            return output.makeImage()
        }
        guard let renderer = Self.privacyContext else { throw EditorError.render }
        let crop = (baseEdits?.crop ?? document.edits.crop).integral
        var input = CIImage(cgImage:source)
        for item in annotations where item.kind == .redact {
            let rect = EditorGeometry.pixelRect(item.rect,bounds:document.bounds).intersection(crop)
            guard !rect.isEmpty else { continue }
            let box = CGRect(x:rect.minX-crop.minX,y:crop.maxY-rect.maxY,width:rect.width,height:rect.height)
            input = CIImage(color:.black).cropped(to:box).composited(over:input)
        }
        var result = input
        let pixels = CGSize(width:CGFloat(document.source.width)/document.pointSize.width,height:CGFloat(document.source.height)/document.pointSize.height)
        for item in annotations where item.kind == .blur || item.kind == .pixelate {
            let rect = item.rect.intersection(crop)
            guard !rect.isEmpty else { continue }
            let box = CGRect(x:rect.minX-crop.minX,y:crop.maxY-rect.maxY,width:rect.width,height:rect.height)
            let effect = EditorRenderer.privacyFilter(item,input:input,pixelScale:pixels,effectScale:sqrt(pixels.width*pixels.height)).cropped(to:box)
            result = effect.composited(over:result)
        }
        let box = CGRect(x:region.minX-crop.minX,y:crop.maxY-region.maxY,width:region.width,height:region.height)
        let transform = CGAffineTransform(scaleX:scale,y:scale)
        guard let patch = renderer.createCGImage(result.transformed(by:transform),from:box.applying(transform)) else { throw EditorError.render }
        privacyCache = (region,scale,patch)
        privacyPatchComputations += 1; return patch
    }

    func invalidate(baseGeneration: Int, annotations: [EditorAnnotation], baseEdits: EditorEdits? = nil) {
        self.baseEdits = baseEdits
        if cachedBaseGeneration != baseGeneration || Self.privacy(cachedAnnotations) != Self.privacy(annotations) { treatments.removeAll(); privacyCache = nil }
        else {
            let common = zip(cachedAnnotations, annotations).prefix { $0 == $1 }.count
            for annotation in cachedAnnotations.dropFirst(common) { treatments.removeValue(forKey: annotation.id) }
            for annotation in annotations.dropFirst(common) { treatments.removeValue(forKey: annotation.id) }
        }
        cachedBaseGeneration = baseGeneration; cachedAnnotations = annotations
    }
    static func drawingBounds(_ annotation: EditorAnnotation, document: EditorDocument) -> CGRect {
        let density = max(CGFloat(document.source.width) / document.pointSize.width, CGFloat(document.source.height) / document.pointSize.height)
        let extent = CGFloat(annotation.style.lineWidth * 2 + 8) * density
        return annotation.rect.insetBy(dx: -extent, dy: -extent).intersection(document.edits.crop.integral)
    }
    func treatment(for annotation: EditorAnnotation, index: Int, base: EditorDisplayBase, document: EditorDocument, annotations: [EditorAnnotation]) throws -> Treatment {
        if let cached = treatments[annotation.id] { return cached }
        let rect = annotation.rect.intersection(document.edits.crop.integral)
        let scale = min(1, min(512 / max(1, rect.width), 256 / max(1, rect.height)))
        let prefix = Array(annotations.prefix(index))
        let image = try compose(rect: rect, scale: scale, base: base, document: document, annotations: prefix, samplingUnderlay: true)
        let pixelScale = CGSize(width: CGFloat(document.source.width) / document.pointSize.width, height: CGFloat(document.source.height) / document.pointSize.height)
        let value = Treatment(luminance: try EditorRenderer.meanLuminance(image), highlight: annotation.kind == .highlight ? try EditorRenderer.highlightTreatment(image, color: annotation.style.color, pixelScale: CGSize(width: pixelScale.width * scale, height: pixelScale.height * scale)) : .init(blendMode: .multiply, opacity: 0.6))
        treatmentComputations += 1; treatments[annotation.id] = value; return value
    }
    func compose(rect: CGRect, scale: CGFloat, base: EditorDisplayBase, document: EditorDocument, annotations: [EditorAnnotation], samplingUnderlay: Bool = false) throws -> CGImage {
        let region = rect.integral.intersection(document.edits.crop.integral)
        guard !region.isNull, !region.isEmpty, scale > 0 else { throw EditorError.invalidEdits }
        let width = max(1, Int(ceil(region.width * scale))), height = max(1, Int(ceil(region.height * scale)))
        let context = try EditorRenderer.context(width: width, height: height)
        let crop = (baseEdits?.crop ?? document.edits.crop).integral
        let padding: CGFloat = 0
        let outputRegion = region.offsetBy(dx: -crop.minX + padding, dy: -crop.minY + padding)
        // Only the affected source crop is sampled, never a full-sized temporary bitmap.
        if let underlay = try privacyPatch(region:region,scale:scale,base:base,document:document,annotations:cachedAnnotations) ?? base.underlay.cropping(to: outputRegion) {
            context.interpolationQuality = scale == 1 ? .none : .high
            context.draw(underlay, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.translateBy(x: -region.minX * scale, y: CGFloat(height) + region.minY * scale)
        context.scaleBy(x: scale, y: -scale)
        // Current solid coverage precedes every live vector and underlay sample.
        // A retained old base can be over-obscured but may never reveal a new secret.
        context.saveGState(); context.setBlendMode(.copy); context.setShouldAntialias(false)
        context.setFillColor(EditorColor.black.cgColor)
        for item in cachedAnnotations where item.kind == .redact {
            context.fill(EditorGeometry.pixelRect(item.rect, bounds: document.bounds))
        }
        context.restoreGState()
        let pixelScale = CGSize(width: CGFloat(document.source.width) / document.pointSize.width, height: CGFloat(document.source.height) / document.pointSize.height)
        for (index, item) in annotations.enumerated() where ![.redact, .blur, .pixelate].contains(item.kind) {
            guard Self.drawingBounds(item, document: document).intersects(region) else { continue }
            let value = (item.kind == .text || item.kind == .highlight) ? try treatment(for: item, index: index, base: base, document: document, annotations: annotations) : Treatment(luminance: 1, highlight: .init(blendMode: .multiply, opacity: 0.6))
            EditorRenderer.draw(item, context: context, pixelScale: pixelScale, underlyingLuminance: value.luminance, highlightTreatment: value.highlight, presentationScale: scale)
        }
        guard let image = context.makeImage() else { throw EditorError.render }
        guard !samplingUnderlay, document.edits.background.preset != .none || document.edits.background.imageCorners == .rounded else { return image }
        // Apply the established corner mask exactly once, after vectors, onto a
        // freshly drawn bounded backdrop. Re-clipping an already rounded base
        // would compound the antialiased edge coverage.
        let output = try EditorRenderer.context(width: width, height: height)
        let currentCrop = document.edits.crop.integral, background = document.edits.background
        let inset = background.preset == .none ? 0 : ceil(background.padding + background.frameWidth)
        let outputHeight = currentCrop.height + inset * 2
        let destination = region.offsetBy(dx: -currentCrop.minX + inset, dy: -currentCrop.minY + inset)
        let y = outputHeight - destination.maxY
        if let backdrop = base.backdrop?.cropping(to: destination) {
            output.interpolationQuality = scale == 1 ? .none : .high
            output.draw(backdrop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        if let mask = base.sourceClip?.cropping(to: destination) {
            output.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: mask)
        }
        output.translateBy(x: -destination.minX * scale, y: -y * scale); output.scaleBy(x: scale, y: scale)
        if base.backdrop == nil { try EditorRenderer.prepareBackground(document, context: output, presentationScale: scale, clipSource: false, shadowSource: base.underlay) }
        if base.sourceClip == nil { EditorRenderer.clipSource(document, context: output, destination: CGRect(x: inset, y: inset, width: currentCrop.width, height: currentCrop.height)) }
        output.draw(image, in: CGRect(x: destination.minX, y: y, width: region.width, height: region.height))
        guard let result = output.makeImage() else { throw EditorError.render }; return result
    }
}
