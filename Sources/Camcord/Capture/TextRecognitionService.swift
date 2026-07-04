import CoreGraphics
import Vision

/// The combined result of reading a captured region: OCR text plus any decoded
/// 1-D/2-D barcodes (QR codes, EAN, Code 128, …). Either half may be empty.
struct RegionReadResult: Equatable {
    /// Recognized text, one observation per line, top-to-bottom. Empty = nothing readable.
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
    /// Recognizes text in `image` and returns it top-to-bottom, one observation per line.
    /// An empty string means "nothing readable", not an error.
    static func recognizeText(in image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let observations = try await request.perform(on: image)
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
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
