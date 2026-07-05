import CoreGraphics
import Vision

/// The combined result of reading a captured region: OCR text plus any decoded
/// 1-D/2-D barcodes (QR codes, EAN, Code 128, …). Either half may be empty.
struct RegionReadResult: Equatable {
    /// Recognized text, laid out to match the source (reading order, paragraph blank lines,
    /// indentation). Empty = nothing readable.
    var text: String
    /// Decoded barcode/QR payloads, in detection order, de-duplicated.
    var barcodes: [String]

    var isEmpty: Bool { text.isEmpty && barcodes.isEmpty }

    /// What to put on the clipboard: decoded codes first (each on its own line — a scanned
    /// QR/URL is almost always the thing you want to paste), then the recognized text, with
    /// any OCR line that merely repeats a code dropped (e.g. the digits printed under an
    /// EAN barcode). Trimmed of surrounding whitespace.
    var clipboardString: String {
        // Compare whitespace-stripped so a printed caption ("5 901234 123457") is recognized
        // as the same as the decoded payload ("5901234123457") and dropped.
        func stripped(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        let codeSet = Set(barcodes.map(stripped))
        let textLines = text.isEmpty
            ? []
            : text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !codeSet.contains(stripped($0)) }
        return (barcodes + textLines)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reads a captured region with Vision's Swift-native requests (macOS 15+, matching the
/// deployment target exactly): `RecognizeTextRequest` for OCR and `DetectBarcodesRequest`
/// for QR/barcodes — no `VNImageRequestHandler` ceremony. Vision schedules the actual work
/// off the calling actor by itself.
enum TextRecognitionService {
    /// Recognizes text in `image` and returns it as STRUCTURED text — correct top-to-bottom
    /// reading order, paragraph blank lines, and code/column indentation preserved from the
    /// glyph positions (see `TextLayout`). A tall image is split into overlapping strips
    /// recognized CONCURRENTLY, both to go faster and to keep small text sharp (no giant-image
    /// downscale). An empty string means "nothing readable", not an error.
    static func recognizeText(in image: CGImage) async throws -> String {
        let lines = try await recognizeLines(in: image)
        return TextLayout.assemble(lines)
    }

    /// CGImage isn't `Sendable`-annotated, but it's an immutable, read-only snapshot — safe to
    /// hand a cropped strip to a concurrent recognition task.
    private struct StripImage: @unchecked Sendable {
        let image: CGImage
        let yOffset: CGFloat
        let size: CGSize
    }

    /// Runs recognition, tiling tall images across concurrent tasks, and returns every line in
    /// FULL-image pixel coordinates (top-left origin) for `TextLayout` to assemble.
    private static func recognizeLines(in image: CGImage) async throws -> [TextLine] {
        let fullSize = CGSize(width: image.width, height: image.height)
        let stripRects = TextLayout.strips(imageWidth: image.width, imageHeight: image.height)

        // Common case (normal-sized capture): a single pass, no tiling overhead.
        guard stripRects.count > 1 else {
            let observations = try await recognize(image)
            return observations.compactMap { line(from: $0, imageSize: fullSize, yOffset: 0) }
        }

        // Tall image: crop the overlapping strips up front (cheap CGImage views), then recognize
        // them all at once.
        let strips: [StripImage] = stripRects.compactMap { rect in
            guard let sub = image.cropping(to: rect) else { return nil }
            return StripImage(image: sub, yOffset: rect.minY, size: CGSize(width: rect.width, height: rect.height))
        }
        let lines = try await withThrowingTaskGroup(of: [TextLine].self) { group -> [TextLine] in
            for strip in strips {
                group.addTask {
                    let observations = try await recognize(strip.image)
                    return observations.compactMap { line(from: $0, imageSize: strip.size, yOffset: strip.yOffset) }
                }
            }
            var all: [TextLine] = []
            for try await batch in group { all.append(contentsOf: batch) }
            return all
        }
        return TextLayout.dedupOverlaps(lines)
    }

    private static func recognize(_ image: CGImage) async throws -> [RecognizedTextObservation] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        return try await request.perform(on: image)
    }

    /// Maps one observation to a `TextLine` in full-image pixel space (top-left origin), shifting
    /// a strip's local y by the strip's offset in the full image.
    private static func line(from observation: RecognizedTextObservation, imageSize: CGSize, yOffset: CGFloat) -> TextLine? {
        guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
        var rect = observation.boundingBox.toImageCoordinates(imageSize, origin: .upperLeft)
        rect.origin.y += yOffset
        return TextLine(text: text, rect: rect)
    }

    /// Detects every supported barcode symbology (QR included, the default) and returns the
    /// decoded payload strings in detection order, de-duplicated. Codes with no string
    /// payload (raw binary) are skipped.
    static func detectBarcodes(in image: CGImage) async throws -> [String] {
        let request = DetectBarcodesRequest()   // default: all supported symbologies incl. .qr
        let observations = try await request.perform(on: image)
        var seen = Set<String>()
        var payloads: [String] = []
        for observation in observations {
            guard
                let payload = observation.payloadString,
                !payload.isEmpty,
                seen.insert(payload).inserted
            else { continue }
            payloads.append(payload)
        }
        return payloads
    }

    /// Reads a region as both text and barcodes concurrently. OCR is primary — its errors
    /// propagate (an unreadable image is a real failure); barcode detection is a best-effort
    /// add-on, so its errors are swallowed and simply yield no codes.
    static func read(in image: CGImage) async throws -> RegionReadResult {
        async let barcodes = detectBarcodesSafely(image)
        let text = try await recognizeText(in: image)
        return RegionReadResult(text: text, barcodes: await barcodes)
    }

    private static func detectBarcodesSafely(_ image: CGImage) async -> [String] {
        (try? await detectBarcodes(in: image)) ?? []
    }
}
