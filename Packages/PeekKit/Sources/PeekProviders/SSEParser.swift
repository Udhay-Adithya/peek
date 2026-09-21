import Foundation

/// One dispatched server-sent event.
public struct ServerSentEvent: Sendable, Equatable {
    public let event: String?
    public let data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Incremental server-sent-events parser.
///
/// Line-oriented and synchronous by design: every provider streams SSE in some
/// dialect, and keeping the framing separate from both the transport and the
/// JSON decoding means the tricky part — multi-line `data:` fields, comments,
/// blank-line dispatch — is testable without a socket or a schema.
///
/// Implements the framing rules from the HTML spec's event-stream section: a
/// leading colon is a comment, a single space after the field colon is
/// stripped, multiple `data:` lines join with newlines, and a blank line
/// dispatches.
public struct SSEParser: Sendable {

    private var dataLines: [String] = []
    private var eventName: String?

    public init() {}

    /// Feeds one line of the stream.
    /// - Returns: the completed event, when this line terminated one.
    public mutating func consume(line: String) -> ServerSentEvent? {
        // Strip a trailing CR so CRLF streams behave the same as LF ones.
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line

        // Blank line dispatches whatever has accumulated.
        if line.isEmpty {
            guard !dataLines.isEmpty else {
                eventName = nil
                return nil
            }
            let event = ServerSentEvent(event: eventName, data: dataLines.joined(separator: "\n"))
            dataLines.removeAll(keepingCapacity: true)
            eventName = nil
            return event
        }

        // A line beginning with a colon is a comment, used for keep-alives.
        if line.hasPrefix(":") { return nil }

        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            // A field name with no colon has an empty value.
            field = line
            value = ""
        }

        switch field {
        case "data":  dataLines.append(value)
        case "event": eventName = value
        default:      break   // `id` and `retry` are not used here
        }
        return nil
    }

    /// Flushes a final event when the stream ends without a trailing blank line.
    ///
    /// Providers are inconsistent about this, and dropping the last token of a
    /// response is a highly visible bug.
    public mutating func finish() -> ServerSentEvent? {
        guard !dataLines.isEmpty else { return nil }
        let event = ServerSentEvent(event: eventName, data: dataLines.joined(separator: "\n"))
        dataLines.removeAll()
        eventName = nil
        return event
    }
}
