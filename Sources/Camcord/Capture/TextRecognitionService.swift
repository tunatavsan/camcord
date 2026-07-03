import CoreGraphics
import Vision

/// OCR for the "capture region as text" flow: Vision's Swift-native
/// `RecognizeTextRequest` (macOS 15+, matches the deployment target exactly), no
/// `VNImageRequestHandler` ceremony. Vision schedules the actual work off the
/// calling actor by itself.
enum TextRecognitionService {
    /// Recognizes text in `image` and returns it top-to-bottom, one observation per
    /// line. An empty string means "nothing readable", not an error.
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
}
