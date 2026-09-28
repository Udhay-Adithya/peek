import CoreGraphics
import OSLog
import PeekCore
import Vision

/// Reads text out of an image, on this Mac.
///
/// The last step of the capture cascade. Accessibility and the clipboard both
/// depend on an application *choosing* to expose its text; this depends only on
/// the pixels, so it reaches PDFs, images, video frames, canvas-drawn apps and
/// remote desktops — the cases where Peek previously had nothing at all.
///
/// Entirely on-device: Vision runs locally, and no new permission is needed
/// beyond the Screen Recording grant the screenshot feature already requires.
struct VisionTextRecognizer: Sendable {

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "ocr")

    enum Failure: LocalizedError {
        case recognitionFailed

        var errorDescription: String? {
            switch self {
            case .recognitionFailed: return "Could not read text from that region."
            }
        }
    }

    /// Recognises text and assembles it into reading order.
    ///
    /// - Returns: `nil` when the region contains no readable text, which is an
    ///   ordinary outcome rather than an error.
    func recognizeText(in image: CGImage) async throws -> TextRecognition.Result? {
        var request = RecognizeTextRequest()
        // `.accurate` over `.fast`: this runs once, on a region the user chose,
        // and a misread word is far more costly here than a few hundred
        // milliseconds — it becomes the question the model answers.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let observations: [RecognizedTextObservation]
        do {
            observations = try await request.perform(on: image)
        } catch {
            Self.logger.error("vision request failed")
            throw Failure.recognitionFailed
        }

        let lines = observations.compactMap { observation -> RecognizedLine? in
            guard let best = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return RecognizedLine(
                text: best.string,
                confidence: best.confidence,
                boundingBox: CGRect(origin: box.origin,
                                    size: CGSize(width: box.width, height: box.height))
            )
        }

        let result = TextRecognition.assemble(lines)

        // Counts only — recognised text is the user's screen contents.
        Self.logger.debug("ocr observations=\(observations.count, privacy: .public) kept=\(lines.count, privacy: .public) chars=\(result?.text.count ?? 0, privacy: .public)")
        return result
    }
}
