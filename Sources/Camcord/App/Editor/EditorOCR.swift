import Vision
import Foundation

struct EditorSensitiveSuggestion: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case email, phone }
    let id: UUID
    let kind: Kind
    let rect: CGRect
    init(kind: Kind, rect: CGRect) { id = UUID(); self.kind = kind; self.rect = rect }
}

enum EditorSensitiveText {
    static func kinds(in text: String) -> [EditorSensitiveSuggestion.Kind] {
        var kinds: [EditorSensitiveSuggestion.Kind] = []
        let patterns: [(EditorSensitiveSuggestion.Kind, String)] = [
            (.email, #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#),
            (.phone, #"(?<!\d)(?:\+\d{1,3}[\s.\-]?)?(?:\(?\d{2,4}\)?[\s.\-]?){2,4}\d{2,4}(?!\d)"#)
        ]
        for (kind, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            if matches.contains(where: { match in
                guard let range = Range(match.range, in: text) else { return false }
                return kind != .phone || text[range].filter(\.isNumber).count >= 7
            }) { kinds.append(kind) }
        }
        return kinds
    }
}

/// A serial actor bounds expensive image work to one operation at a time.
actor EditorWorker {
    private let decoder: (@Sendable (URL) async throws -> EditorDocument)?
    private let recognizer: (@Sendable (EditorDocument) async throws -> [EditorSensitiveSuggestion])?
    init(decoder: (@Sendable (URL) async throws -> EditorDocument)? = nil,
         recognizer: (@Sendable (EditorDocument) async throws -> [EditorSensitiveSuggestion])? = nil) {
        self.decoder = decoder; self.recognizer = recognizer
    }
    func decode(_ url: URL) async throws -> EditorDocument {
        try Task.checkCancellation()
        if let decoder { return try await decoder(url) }
        return try EditorRenderer.decode(url)
    }
    func png(_ rendered: EditorRendered) throws -> Data { try Task.checkCancellation(); return try rendered.png }
    func render(_ document: EditorDocument) throws -> EditorRendered { try EditorRenderer.render(document) }
    func recognize(_ document: EditorDocument) async throws -> [EditorSensitiveSuggestion] {
        if let recognizer { return try await recognizer(document) }
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: document.source, options: [:]).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).prefix(500).flatMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return [EditorSensitiveSuggestion]() }
            let rect = EditorGeometry.visionRect(observation.boundingBox, width: document.source.width, height: document.source.height).insetBy(dx: -2, dy: -2).intersection(document.bounds)
            return EditorSensitiveText.kinds(in: candidate.string).map { EditorSensitiveSuggestion(kind: $0, rect: rect) }
        }
    }
}
