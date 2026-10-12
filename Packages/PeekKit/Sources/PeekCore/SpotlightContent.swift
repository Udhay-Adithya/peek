import Foundation

/// What a conversation looks like to Spotlight.
///
/// Kept separate from CoreSpotlight so the decisions that matter — what is
/// indexed, what is deliberately withheld, and how much — are testable without
/// a system index, and reviewable in one place rather than scattered through
/// the code that talks to the framework.
public enum SpotlightContent {

    /// Upper bound on indexed body text per conversation.
    ///
    /// Spotlight keeps what it is given, and a conversation can grow without
    /// limit. Indexing all of it would put an unbounded copy of the user's
    /// content in a second place for steadily less search benefit — the first
    /// few thousand characters is what someone is recalling when they search.
    public static let maxBodyCharacters = 4_000

    public struct Item: Sendable, Equatable {
        public let title: String
        /// One-line summary shown under the result.
        public let summary: String
        /// Searchable body text.
        public let body: String

        public init(title: String, summary: String, body: String) {
            self.title = title
            self.summary = summary
            self.body = body
        }
    }

    /// Builds the indexable form of a conversation.
    ///
    /// - Returns: `nil` when there is nothing worth indexing, so an empty
    ///   conversation never becomes a dead Spotlight result.
    public static func item(title: String,
                            messages: [PersistedMessage],
                            sourceAppName: String? = nil) -> Item? {
        let usable = messages.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usable.isEmpty else { return nil }

        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = displayTitle.isEmpty ? "Conversation" : displayTitle

        // Attachments are referenced, never indexed: the bytes are a
        // screenshot of the user's screen and have no business in a system
        // index that other software can read.
        let attachmentCount = messages.reduce(0) { $0 + $1.attachments.count }

        var summaryParts: [String] = []
        if let sourceAppName { summaryParts.append(sourceAppName) }
        summaryParts.append("\(usable.count) message\(usable.count == 1 ? "" : "s")")
        if attachmentCount > 0 {
            summaryParts.append("\(attachmentCount) screenshot\(attachmentCount == 1 ? "" : "s")")
        }

        // The selection a turn was about is indexed alongside it: searching for
        // the text you asked about is at least as natural as searching for what
        // you typed.
        let body = usable
            .map { message -> String in
                if let context = message.contextText, !context.isEmpty {
                    return "\(context)\n\(message.text)"
                }
                return message.text
            }
            .joined(separator: "\n\n")

        let clipped = body.count > maxBodyCharacters
            ? String(body.prefix(maxBodyCharacters))
            : body

        return Item(title: resolvedTitle,
                    summary: summaryParts.joined(separator: " · "),
                    body: clipped)
    }
}
