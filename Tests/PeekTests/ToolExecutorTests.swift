import Testing
import Foundation
import PeekCore
@testable import Peek

/// A fetcher with a scripted page, so the web tool is testable offline.
private struct StubFetcher: URLTextFetching {
    let page: String
    let failure: Error?

    init(page: String = "the page text", failure: Error? = nil) {
        self.page = page
        self.failure = failure
    }

    func text(at url: URL) async throws -> String {
        if let failure { throw failure }
        return page
    }
}

private func toolCall(_ name: String, _ arguments: String) -> ToolCall {
    ToolCall(id: "c1", name: name, arguments: Data(arguments.utf8))
}

@Suite("PeekToolExecutor")
struct ToolExecutorTests {

    private func executor(allowWebFetch: Bool = true,
                          store: RecordingStore = RecordingStore(),
                          fetcher: StubFetcher = StubFetcher()) -> PeekToolExecutor {
        PeekToolExecutor(store: store, allowWebFetch: allowWebFetch, fetcher: fetcher)
    }

    // MARK: - What is offered

    @Test("the web tool is withheld unless it is switched on")
    func withholdsWebToolWhenOff() {
        #expect(executor(allowWebFetch: false).tools.map(\.name) == ["search_conversations"])
        #expect(executor(allowWebFetch: true).tools.map(\.name)
                == ["search_conversations", "fetch_web_page"])
    }

    @Test("only the web tool is marked as leaving the machine")
    func marksOutwardTool() {
        let tools = executor().tools
        #expect(tools.first { $0.name == "search_conversations" }?.leavesTheMachine == false)
        #expect(tools.first { $0.name == "fetch_web_page" }?.leavesTheMachine == true)
    }

    @Test("a tool that was never offered is refused even if the model names it")
    func refusesUnofferedTool() async {
        // The model can invent a name, and the web tool being off is a
        // decision the user made.
        let result = await executor(allowWebFetch: false)
            .execute(toolCall("fetch_web_page", #"{"url":"https://example.com"}"#))

        #expect(result.isError)
        #expect(result.content.contains("No tool named fetch_web_page"))
    }

    @Test("an unknown tool name is refused rather than crashing")
    func refusesUnknownTool() async {
        let result = await executor().execute(toolCall("rm_rf", "{}"))
        #expect(result.isError)
    }

    // MARK: - Conversation search

    @Test("finds matching conversations and reports titles with dates")
    func searchesConversations() async throws {
        let store = RecordingStore()
        _ = try await store.createConversation(title: "Force Click research",
                                               providerID: "gemini", modelID: "m",
                                               sourceAppName: nil)
        _ = try await store.createConversation(title: "Dinner recipes",
                                               providerID: "gemini", modelID: "m",
                                               sourceAppName: nil)

        let result = await executor(store: store)
            .execute(toolCall("search_conversations", #"{"query":"force"}"#))

        #expect(!result.isError)
        #expect(result.content.contains("Force Click research"))
        #expect(!result.content.contains("Dinner recipes"))
    }

    @Test("says plainly when nothing matched")
    func searchFindsNothing() async {
        let result = await executor()
            .execute(toolCall("search_conversations", #"{"query":"nothing here"}"#))

        // A model that cannot tell "found nothing" from "the tool broke"
        // invents a past conversation.
        #expect(!result.isError)
        #expect(result.content == "No past conversations match that.")
    }

    @Test(arguments: ["{}", #"{"query":""}"#, #"{"query":"   "}"#, "not json"])
    func rejectsBadSearchArguments(_ arguments: String) async {
        let result = await executor().execute(toolCall("search_conversations", arguments))
        #expect(result.isError)
    }

    @Test("the result carries the call id back")
    func carriesCallID() async {
        let result = await executor()
            .execute(toolCall("search_conversations", #"{"query":"x"}"#))
        #expect(result.callID == "c1")
        #expect(result.name == "search_conversations")
    }

    @Test("a missing call id stays missing rather than becoming empty")
    func omitsEmptyCallID() async {
        let call = ToolCall(id: "", name: "search_conversations",
                            arguments: Data(#"{"query":"x"}"#.utf8))
        let result = await executor().execute(call)
        // Gemini omits ids on some models; sending "" back is not the same as
        // sending none.
        #expect(result.callID == nil)
    }

    // MARK: - Web fetch

    @Test("fetches an allowed page and returns its text")
    func fetchesPage() async {
        let result = await executor(fetcher: StubFetcher(page: "Hello from the page"))
            .execute(toolCall("fetch_web_page", #"{"url":"https://example.com"}"#))

        #expect(!result.isError)
        #expect(result.content == "Hello from the page")
    }

    @Test(arguments: ["http://example.com", "https://localhost:3000",
                      "https://169.254.169.254/latest/meta-data/",
                      "https://192.168.0.1", "file:///etc/passwd"])
    func refusesDisallowedURLs(_ url: String) async {
        let result = await executor()
            .execute(toolCall("fetch_web_page", #"{"url":"\#(url)"}"#))

        // The refusal reaches the model as an error it can explain, and the
        // fetcher is never reached.
        #expect(result.isError, "should refuse \(url)")
    }

    @Test("the refusal tells the model why, so it can say so")
    func explainsRefusal() async {
        let result = await executor()
            .execute(toolCall("fetch_web_page", #"{"url":"https://127.0.0.1/admin"}"#))
        #expect(result.content.contains("private or local"))
    }

    @Test("an oversized page is truncated and says it was")
    func truncatesLongPage() async {
        let huge = String(repeating: "a", count: WebFetchPolicy.maxCharacters + 500)
        let result = await executor(fetcher: StubFetcher(page: huge))
            .execute(toolCall("fetch_web_page", #"{"url":"https://example.com"}"#))

        #expect(result.content.count < huge.count)
        #expect(result.content.hasSuffix("[truncated]"))
    }

    @Test("a fetch failure is reported, not thrown")
    func reportsFetchFailure() async {
        let result = await executor(fetcher: StubFetcher(failure: URLError(.timedOut)))
            .execute(toolCall("fetch_web_page", #"{"url":"https://example.com"}"#))

        #expect(result.isError)
        #expect(result.content.contains("could not be fetched"))
    }

    @Test("an empty page is described rather than returned as nothing")
    func reportsEmptyPage() async {
        let result = await executor(fetcher: StubFetcher(page: ""))
            .execute(toolCall("fetch_web_page", #"{"url":"https://example.com"}"#))
        #expect(result.content.contains("no readable text"))
    }
}

@Suite("HTMLText")
struct HTMLTextTests {

    @Test("drops script and style bodies entirely")
    func dropsScriptAndStyle() {
        let html = """
            <html><head><style>body { color: red }</style></head>
            <body><script>var x = 1; alert("hi")</script><p>Real content</p></body></html>
            """
        let text = HTMLText.extract(html)

        // These are the bulk of a modern page and none of its meaning.
        #expect(text.contains("Real content"))
        #expect(!text.contains("color: red"))
        #expect(!text.contains("alert"))
    }

    @Test("keeps paragraph breaks")
    func keepsParagraphs() {
        let text = HTMLText.extract("<p>First</p><p>Second</p>")
        #expect(text.contains("First"))
        #expect(text.contains("Second"))
        #expect(text.contains("\n"))
    }

    @Test("decodes the common entities")
    func decodesEntities() {
        let text = HTMLText.extract("<p>Tom &amp; Jerry &lt;tag&gt; &quot;quoted&quot;&nbsp;end</p>")
        #expect(text.contains("Tom & Jerry"))
        #expect(text.contains("<tag>"))
        #expect(text.contains("\"quoted\""))
    }

    @Test("collapses the whitespace that stripping tags leaves")
    func collapsesWhitespace() {
        let text = HTMLText.extract("<div>  a   </div>   <div>   b  </div>")
        #expect(!text.contains("   "))
        #expect(text.contains("a"))
        #expect(text.contains("b"))
    }

    @Test("plain text with no markup survives unchanged")
    func passesPlainText() {
        #expect(HTMLText.extract("just words") == "just words")
    }

    @Test("an unclosed tag does not swallow the document")
    func toleratesBrokenMarkup() {
        let text = HTMLText.extract("<p>before<div>after")
        #expect(text.contains("before"))
        #expect(text.contains("after"))
    }
}
