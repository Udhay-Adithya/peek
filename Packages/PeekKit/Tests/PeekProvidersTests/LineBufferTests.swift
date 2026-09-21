import Testing
import Foundation
import PeekCore
@testable import PeekProviders

@Suite("LineBuffer")
struct LineBufferTests {

    private func split(_ text: String) -> [String] {
        var buffer = LineBuffer()
        var lines: [String] = []
        for byte in Array(text.utf8) {
            if let line = buffer.append(byte) { lines.append(line) }
        }
        if let trailing = buffer.flush() { lines.append(trailing) }
        return lines
    }

    @Test("preserves empty lines, which SSE depends on")
    func preservesEmptyLines() {
        // Foundation's AsyncLineSequence drops these, which silently breaks
        // event dispatch. This is the regression that motivated the type.
        #expect(split("a\n\nb\n") == ["a", "", "b"])
    }

    @Test("strips a single trailing CR from CRLF streams")
    func stripsCR() {
        #expect(split("a\r\nb\r\n") == ["a", "b"])
    }

    @Test("a bare CRLF yields an empty line")
    func crlfBlankLine() {
        // Gemini's event separator is exactly this.
        #expect(split("data: x\r\n\r\n") == ["data: x", ""])
    }

    @Test("keeps interior CR characters")
    func keepsInteriorCR() {
        #expect(split("a\rb\n") == ["a\rb"])
    }

    @Test("flushes a final unterminated line")
    func flushesTrailing() {
        #expect(split("no newline") == ["no newline"])
    }

    @Test("emits nothing for empty input")
    func emptyInput() {
        #expect(split("").isEmpty)
    }

    @Test("handles multi-byte UTF-8 split across appends")
    func handlesUTF8() {
        #expect(split("héllo → 世界\n") == ["héllo → 世界"])
    }
}

@Suite("Gemini real stream regression")
struct GeminiRealStreamTests {

    /// A genuine `streamGenerateContent?alt=sse` response body, captured from
    /// the live API. It uses CRLF framing and pretty-printed JSON — neither of
    /// which my hand-written fixtures had, which is why they all passed while
    /// the real thing failed.
    private func fixtureLines() throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/gemini-stream-crlf",
                                                 withExtension: "sse"))
        let raw = try Data(contentsOf: url)

        var buffer = LineBuffer()
        var lines: [String] = []
        for byte in raw {
            if let line = buffer.append(byte) { lines.append(line) }
        }
        if let trailing = buffer.flush() { lines.append(trailing) }
        return lines
    }

    @Test("the captured stream splits into data lines and blank separators")
    func framingIsPreserved() throws {
        let lines = try fixtureLines()
        let dataLines = lines.filter { $0.hasPrefix("data:") }
        let blanks = lines.filter { $0.isEmpty }
        #expect(dataLines.count == 5)
        // Five separators is the part AsyncLineSequence threw away.
        #expect(blanks.count >= 5)
    }

    @Test("decodes the captured stream into a complete response")
    func decodesRealStream() async throws {
        let provider = GeminiProvider(apiKey: { "test-key" },
                                      client: FixtureClient(lines: try fixtureLines()))
        var acc = StreamAccumulator()
        for try await event in provider.stream(AssistantRequest(
            model: "gemini-flash-latest",
            messages: [ChatMessage(role: .user, text: "explain bfs")]
        )) {
            try acc.apply(event)
        }

        #expect(acc.finishReason == .stop)
        #expect(acc.text.contains("Breadth-First Search"))
        // Five chunks must assemble into one continuous answer.
        #expect(acc.text.count > 400)
        #expect(acc.usage != nil)
    }
}
