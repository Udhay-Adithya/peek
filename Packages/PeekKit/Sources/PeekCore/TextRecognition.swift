import CoreGraphics
import Foundation

/// One line of text found in an image.
///
/// Mirrors what Vision reports, without depending on Vision: the assembly rules
/// below are the part that decides whether OCR output is usable prose or a
/// jumble, and they should be testable without a camera, a screen or a model.
public struct RecognizedLine: Sendable, Equatable {
    public let text: String
    /// 0…1, as reported by the recogniser for its best candidate.
    public let confidence: Float
    /// Normalised bounds with a bottom-left origin — Vision's convention.
    public let boundingBox: CGRect

    public init(text: String, confidence: Float, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// Turns scattered recognised lines into readable text.
///
/// Vision returns observations without a guaranteed order and with no notion of
/// layout, so raw output frequently reads as nonsense: a two-column page
/// interleaves, a toolbar's labels land in the middle of a paragraph, and a
/// misread watermark appears as a confident sentence. These rules exist to make
/// the result worth sending to a model.
public enum TextRecognition {

    /// Below this, a line is more likely to be an artefact than text.
    ///
    /// Deliberately permissive: OCR confidence drops on small or stylised type
    /// that is nonetheless perfectly readable, and discarding a real line is
    /// worse than passing along one doubtful one, since the user can see what
    /// was captured.
    public static let defaultMinimumConfidence: Float = 0.3

    public struct Result: Sendable, Equatable {
        public let text: String
        /// How many lines were discarded for low confidence. Surfaced so the
        /// UI can say the reading was partial rather than quietly truncating.
        public let discardedLineCount: Int

        public init(text: String, discardedLineCount: Int) {
            self.text = text
            self.discardedLineCount = discardedLineCount
        }
    }

    /// Assembles lines into reading order.
    ///
    /// Lines sharing a visual row are joined with a space and everything else
    /// with a newline, because Vision reports each run of text separately —
    /// a label and its value, or two columns, arrive as unrelated observations
    /// that would otherwise stack into a vertical list of fragments.
    ///
    /// - Returns: `nil` when nothing survives, which is a normal outcome for a
    ///   region containing no text.
    public static func assemble(
        _ lines: [RecognizedLine],
        minimumConfidence: Float = TextRecognition.defaultMinimumConfidence
    ) -> Result? {
        let usable = lines.filter {
            $0.confidence >= minimumConfidence
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let discarded = lines.count - usable.count
        guard !usable.isEmpty else { return nil }

        let rows = groupIntoRows(usable)
        let text = rows
            .map { row in
                row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return nil }
        return Result(text: text, discardedLineCount: discarded)
    }

    /// Groups lines that sit on the same visual row, top row first.
    ///
    /// Two lines belong together when their vertical extents overlap by more
    /// than half the shorter one. A fixed pixel tolerance would fail across the
    /// range of type sizes a screenshot contains; proportional overlap holds up
    /// for both a caption and a heading.
    private static func groupIntoRows(_ lines: [RecognizedLine]) -> [[RecognizedLine]] {
        // Vision's origin is bottom-left, so descending maxY is top-down.
        let ordered = lines.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }

        var rows: [[RecognizedLine]] = []
        for line in ordered {
            if let index = rows.indices.last, sharesRow(line, with: rows[index]) {
                rows[index].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows
    }

    private static func sharesRow(_ line: RecognizedLine, with row: [RecognizedLine]) -> Bool {
        guard let reference = row.last else { return false }
        let a = line.boundingBox
        let b = reference.boundingBox

        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard overlap > 0 else { return false }

        let shorter = min(a.height, b.height)
        guard shorter > 0 else { return false }
        return overlap / shorter > 0.5
    }
}
