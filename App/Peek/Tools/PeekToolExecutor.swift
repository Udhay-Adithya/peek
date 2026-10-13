import Foundation
import OSLog
import PeekCore

/// Fetches a web page as text. A seam so the web tool can be tested without
/// the network.
protocol URLTextFetching: Sendable {
    func text(at url: URL) async throws -> String
}

/// Runs Peek's tools.
///
/// The tool set is decided when the turn starts, on the main actor, and then
/// frozen into this value. That is deliberate twice over: the executor is
/// called from the provider's background task where `AppSettings` cannot be
/// read, and a user who revokes the web tool mid-turn should not have it used
/// for the rest of that turn either.
struct PeekToolExecutor: ToolExecuting {

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "tools")

    let tools: [ToolDefinition]
    private let store: ConversationStore
    private let fetcher: any URLTextFetching

    init(store: ConversationStore,
         allowWebFetch: Bool,
         fetcher: any URLTextFetching = LiveURLTextFetcher()) {
        self.store = store
        self.fetcher = fetcher
        self.tools = allowWebFetch
            ? [Self.searchConversations, Self.fetchWebPage]
            : [Self.searchConversations]
    }

    // MARK: - Declarations

    static let searchConversations = ToolDefinition(
        name: "search_conversations",
        description: """
            Search the user's own past Peek conversations by keyword. Use it \
            when the user refers to something they asked before, or when \
            earlier context would help. Returns conversation titles and dates, \
            not full transcripts.
            """,
        parameters: [
            ToolParameter(name: "query",
                          description: "Keywords to search for.",
                          kind: .string,
                          isRequired: true),
        ],
        leavesTheMachine: false
    )

    static let fetchWebPage = ToolDefinition(
        name: "fetch_web_page",
        description: """
            Fetch an https web page and return its visible text. Use it only \
            when the user asks about a specific page or link. The page is \
            fetched over the network.
            """,
        parameters: [
            ToolParameter(name: "url",
                          description: "The full https URL of the page.",
                          kind: .string,
                          isRequired: true),
        ],
        leavesTheMachine: true
    )

    // MARK: - Execution

    func execute(_ call: ToolCall) async -> ToolResult {
        // A tool the model was never offered must not run because it guessed
        // the name — the web tool in particular is a setting the user turned
        // off.
        guard tools.contains(where: { $0.name == call.name }) else {
            Self.logger.error("refused unoffered tool \(call.name, privacy: .public)")
            return failure(call, "No tool named \(call.name) is available.")
        }

        switch call.name {
        case Self.searchConversations.name:
            return await searchConversations(call)
        case Self.fetchWebPage.name:
            return await fetchWebPage(call)
        default:
            return failure(call, "No tool named \(call.name) is available.")
        }
    }

    private func searchConversations(_ call: ToolCall) async -> ToolResult {
        struct Arguments: Decodable { let query: String }
        guard let arguments = try? JSONDecoder().decode(Arguments.self, from: call.arguments),
              !arguments.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return failure(call, "search_conversations needs a non-empty query.")
        }

        do {
            let matches = try await store.search(arguments.query, limit: 10)
            guard !matches.isEmpty else {
                // Said plainly: a model that cannot tell "nothing found" from
                // "the search broke" will invent a past conversation.
                return success(call, "No past conversations match that.")
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            let lines = matches.map { summary in
                "- \(summary.title) (\(formatter.string(from: summary.updatedAt)))"
            }
            Self.logger.info("search_conversations matched \(matches.count, privacy: .public)")
            return success(call, lines.joined(separator: "\n"))
        } catch {
            Self.logger.error("search_conversations failed")
            return failure(call, "The conversation search failed.")
        }
    }

    private func fetchWebPage(_ call: ToolCall) async -> ToolResult {
        struct Arguments: Decodable { let url: String }
        guard let arguments = try? JSONDecoder().decode(Arguments.self, from: call.arguments) else {
            return failure(call, "fetch_web_page needs a url.")
        }

        switch WebFetchPolicy.validate(arguments.url) {
        case .failure(let refusal):
            // The host is recorded, never the full URL: a model-chosen URL can
            // carry a query string, and diagnostics stay content-free.
            Self.logger.error("fetch refused: \(String(describing: refusal), privacy: .public)")
            return failure(call, refusal.message)

        case .success(let url):
            do {
                let text = try await fetcher.text(at: url)
                guard !text.isEmpty else {
                    return success(call, "That page has no readable text.")
                }
                let clipped = text.count > WebFetchPolicy.maxCharacters
                    ? String(text.prefix(WebFetchPolicy.maxCharacters)) + "\n[truncated]"
                    : text
                Self.logger.info("fetched \(url.host() ?? "?", privacy: .public) chars=\(clipped.count, privacy: .public)")
                return success(call, clipped)
            } catch {
                Self.logger.error("fetch failed for \(url.host() ?? "?", privacy: .public)")
                return failure(call, "That page could not be fetched.")
            }
        }
    }

    private func success(_ call: ToolCall, _ content: String) -> ToolResult {
        ToolResult(callID: call.id.isEmpty ? nil : call.id, name: call.name, content: content)
    }

    private func failure(_ call: ToolCall, _ content: String) -> ToolResult {
        ToolResult(callID: call.id.isEmpty ? nil : call.id, name: call.name,
                   content: content, isError: true)
    }
}

/// Fetches a page with `URLSession` and reduces it to visible text.
struct LiveURLTextFetcher: URLTextFetching {

    func text(at url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // Identifies Peek rather than impersonating a browser, so a site that
        // wants to refuse automated fetches can.
        request.setValue("Peek/1.0 (+https://github.com/Udhay-Adithya/peek)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,text/plain", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        // Only text is useful to a language model, and decoding an arbitrary
        // binary as text would hand it noise.
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard type.contains("text/html") || type.contains("text/plain")
                || type.contains("application/xhtml") || type.isEmpty else {
            throw URLError(.cannotDecodeContentData)
        }

        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return type.contains("html") || type.isEmpty ? HTMLText.extract(raw) : raw
    }
}

/// Strips HTML down to readable text.
///
/// Deliberately crude — regular expressions, not a parser. The output feeds a
/// language model, which tolerates imperfect whitespace and the odd stray
/// entity far better than the app tolerates a parsing dependency. Script and
/// style bodies are removed first, because their contents are the bulk of a
/// modern page and none of its meaning.
enum HTMLText {

    static func extract(_ html: String) -> String {
        var text = html

        for tag in ["script", "style", "noscript", "svg", "head"] {
            text = text.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>.*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Block-level tags become line breaks so paragraphs survive.
        text = text.replacingOccurrences(
            of: "</(p|div|li|tr|h[1-6]|section|article|br)\\s*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )

        text = text.replacingOccurrences(of: "<[^>]+>", with: " ",
                                         options: .regularExpression)

        for (entity, replacement) in [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&mdash;", "—"),
            ("&ndash;", "–"), ("&hellip;", "…"),
        ] {
            text = text.replacingOccurrences(of: entity, with: replacement,
                                             options: .caseInsensitive)
        }

        // Collapse the whitespace that stripping tags leaves behind.
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n[ \\t]*\\n\\s*", with: "\n\n",
                                         options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
