import Testing
@testable import PeekProviders

@Suite("SSEParser")
struct SSEParserTests {

    /// Feeds lines and collects every dispatched event, including a trailing
    /// flush, mirroring how the provider drives the parser.
    private func run(_ lines: [String]) -> [ServerSentEvent] {
        var parser = SSEParser()
        var events: [ServerSentEvent] = []
        for line in lines {
            if let event = parser.consume(line: line) { events.append(event) }
        }
        if let trailing = parser.finish() { events.append(trailing) }
        return events
    }

    @Test("dispatches one event per blank line")
    func dispatchesOnBlankLine() {
        let events = run(["data: first", "", "data: second", ""])
        #expect(events.map(\.data) == ["first", "second"])
    }

    @Test("strips exactly one space after the field colon")
    func stripsSingleSpace() {
        let events = run(["data:  leading", ""])
        #expect(events.first?.data == " leading")
    }

    @Test("joins multiple data lines with newlines")
    func joinsMultilineData() {
        let events = run(["data: line one", "data: line two", ""])
        #expect(events.count == 1)
        #expect(events.first?.data == "line one\nline two")
    }

    @Test("ignores comment lines used as keep-alives")
    func ignoresComments() {
        let events = run([": keep-alive", "data: payload", ""])
        #expect(events.map(\.data) == ["payload"])
    }

    @Test("captures the event name when present")
    func capturesEventName() {
        let events = run(["event: message_stop", "data: {}", ""])
        #expect(events.first?.event == "message_stop")
    }

    @Test("tolerates CRLF line endings")
    func toleratesCRLF() {
        let events = run(["data: payload\r", "\r"])
        #expect(events.map(\.data) == ["payload"])
    }

    @Test("flushes a final event when the stream ends without a blank line")
    func flushesTrailingEvent() {
        // Dropping the last token of a response is a highly visible bug, and
        // providers are inconsistent about the trailing newline.
        let events = run(["data: last chunk"])
        #expect(events.map(\.data) == ["last chunk"])
    }

    @Test("a blank line with no data dispatches nothing")
    func blankLineAloneIsNoop() {
        #expect(run(["", "", ""]).isEmpty)
    }

    @Test("resets event name between events")
    func resetsEventName() {
        let events = run(["event: named", "data: a", "", "data: b", ""])
        #expect(events[0].event == "named")
        #expect(events[1].event == nil)
    }

    @Test("handles a field with no colon as an empty value")
    func fieldWithoutColon() {
        // "data" alone is a valid empty data line per the spec.
        let events = run(["data", ""])
        #expect(events.first?.data == "")
    }
}
