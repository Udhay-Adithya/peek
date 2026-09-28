import Testing
import CoreGraphics
@testable import PeekCore

@Suite("TextRecognition")
struct TextRecognitionTests {

    /// Builds a line in Vision's normalised, bottom-left-origin space.
    /// `top` is measured downward from the top of the image, which is how a
    /// human describes a layout.
    private func line(_ text: String,
                      top: CGFloat,
                      left: CGFloat = 0.1,
                      width: CGFloat = 0.3,
                      height: CGFloat = 0.05,
                      confidence: Float = 0.9) -> RecognizedLine {
        RecognizedLine(
            text: text,
            confidence: confidence,
            boundingBox: CGRect(x: left, y: 1 - top - height, width: width, height: height)
        )
    }

    @Test("reads top to bottom regardless of the order observations arrive in")
    func ordersTopToBottom() throws {
        // Vision does not guarantee ordering.
        let result = try #require(TextRecognition.assemble([
            line("third", top: 0.5),
            line("first", top: 0.1),
            line("second", top: 0.3),
        ]))
        #expect(result.text == "first\nsecond\nthird")
    }

    @Test("joins lines sharing a row with a space, not a newline")
    func joinsSameRow() throws {
        // A label and its value arrive as separate observations; stacking them
        // vertically would read as two unrelated fragments.
        let result = try #require(TextRecognition.assemble([
            line("Total:", top: 0.2, left: 0.1, width: 0.15),
            line("42", top: 0.2, left: 0.3, width: 0.05),
        ]))
        #expect(result.text == "Total: 42")
    }

    @Test("orders a shared row left to right")
    func ordersRowLeftToRight() throws {
        let result = try #require(TextRecognition.assemble([
            line("world", top: 0.2, left: 0.4),
            line("hello", top: 0.2, left: 0.1),
        ]))
        #expect(result.text == "hello world")
    }

    @Test("keeps rows separate when they barely overlap")
    func separatesAdjacentRows() throws {
        // Consecutive lines of a paragraph nearly touch but are not one row.
        let result = try #require(TextRecognition.assemble([
            line("line one", top: 0.10, height: 0.04),
            line("line two", top: 0.15, height: 0.04),
        ]))
        #expect(result.text == "line one\nline two")
    }

    @Test("groups by proportional overlap, so type size does not matter")
    func groupsAcrossTypeSizes() throws {
        // A heading beside a caption still shares a row.
        let result = try #require(TextRecognition.assemble([
            line("Heading", top: 0.20, left: 0.1, width: 0.3, height: 0.08),
            line("note", top: 0.22, left: 0.5, width: 0.1, height: 0.03),
        ]))
        #expect(result.text == "Heading note")
    }

    @Test("discards low-confidence lines and reports how many")
    func discardsLowConfidence() throws {
        let result = try #require(TextRecognition.assemble([
            line("real text", top: 0.1, confidence: 0.95),
            line("rn1sread", top: 0.3, confidence: 0.05),
        ]))
        #expect(result.text == "real text")
        #expect(result.discardedLineCount == 1)
    }

    @Test("keeps doubtful-but-plausible lines")
    func keepsBorderlineConfidence() throws {
        // OCR confidence drops on small or stylised type that reads fine.
        // Losing a real line is worse than passing along a doubtful one, since
        // the user can see what was captured.
        let result = try #require(TextRecognition.assemble([
            line("small print", top: 0.1, confidence: 0.35),
        ]))
        #expect(result.text == "small print")
        #expect(result.discardedLineCount == 0)
    }

    @Test("honours a stricter confidence threshold")
    func respectsCustomThreshold() {
        let lines = [line("uncertain", top: 0.1, confidence: 0.4)]
        #expect(TextRecognition.assemble(lines, minimumConfidence: 0.8) == nil)
        #expect(TextRecognition.assemble(lines, minimumConfidence: 0.2) != nil)
    }

    @Test("returns nil for a region with no text")
    func emptyInput() {
        #expect(TextRecognition.assemble([]) == nil)
    }

    @Test("returns nil when every line is discarded")
    func allDiscarded() {
        let lines = [
            line("junk", top: 0.1, confidence: 0.01),
            line("noise", top: 0.3, confidence: 0.02),
        ]
        #expect(TextRecognition.assemble(lines) == nil)
    }

    @Test("ignores whitespace-only observations")
    func ignoresWhitespaceLines() throws {
        let result = try #require(TextRecognition.assemble([
            line("   ", top: 0.1),
            line("actual", top: 0.3),
        ]))
        #expect(result.text == "actual")
    }

    @Test("trims each line without collapsing interior spacing")
    func trimsLines() throws {
        let result = try #require(TextRecognition.assemble([
            line("  padded  ", top: 0.1),
        ]))
        #expect(result.text == "padded")
    }

    @Test("handles a zero-height observation without dividing by zero")
    func toleratesDegenerateBounds() throws {
        let result = try #require(TextRecognition.assemble([
            RecognizedLine(text: "flat", confidence: 0.9,
                           boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0)),
            line("normal", top: 0.8),
        ]))
        #expect(result.text.contains("flat"))
        #expect(result.text.contains("normal"))
    }

    @Test("assembles a realistic multi-row capture in reading order")
    func assemblesRealisticLayout() throws {
        // Roughly a dialog: title, a labelled value, then a paragraph.
        let result = try #require(TextRecognition.assemble([
            line("paragraph continues here", top: 0.55, left: 0.1, width: 0.6),
            line("Disk Utility", top: 0.10, left: 0.1, width: 0.25, height: 0.06),
            line("42.1 GB", top: 0.30, left: 0.45, width: 0.15),
            line("Available:", top: 0.30, left: 0.1, width: 0.2),
            line("Some explanatory text", top: 0.48, left: 0.1, width: 0.6),
        ]))
        #expect(result.text == """
            Disk Utility
            Available: 42.1 GB
            Some explanatory text
            paragraph continues here
            """)
    }
}
