import Testing
import Foundation
import PeekCore
@testable import PeekProviders

/// Replays a recorded SSE body. No network, no sockets, no timing.
struct FixtureClient: StreamingHTTPClient {
    let head: HTTPResponseHead
    let lines: [String]
    /// Captures what the provider actually sent, so request encoding is testable.
    let recorder: RequestRecorder?

    init(status: Int = 200,
         headers: [String: String] = [:],
         lines: [String],
         recorder: RequestRecorder? = nil) {
        self.head = HTTPResponseHead(statusCode: status, headers: headers)
        self.lines = lines
        self.recorder = recorder
    }

    func stream(_ request: HTTPRequestSpec) async throws
        -> (HTTPResponseHead, AsyncThrowingStream<String, Error>) {
        await recorder?.record(request)
        let captured = lines
        return (head, AsyncThrowingStream { continuation in
            for line in captured { continuation.yield(line) }
            continuation.finish()
        })
    }
}

actor RequestRecorder {
    private(set) var request: HTTPRequestSpec?
    func record(_ spec: HTTPRequestSpec) { request = spec }
}

@Suite("GeminiProvider")
struct GeminiProviderTests {

    private let key: APIKeyProvider = { "test-key" }

    private func collect(
        _ provider: GeminiProvider,
        request: AssistantRequest = AssistantRequest(
            model: "gemini-2.5-flash",
            messages: [ChatMessage(role: .user, text: "hello")]
        )
    ) async throws -> [AssistantStreamEvent] {
        var events: [AssistantStreamEvent] = []
        for try await event in provider.stream(request) { events.append(event) }
        return events
    }

    // MARK: - Happy path

    @Test("translates text chunks into ordered text deltas")
    func streamsTextDeltas() async throws {
        let client = FixtureClient(lines: [
            #"data: {"candidates":[{"content":{"parts":[{"text":"Force "}],"role":"model"}}],"responseId":"r1"}"#, "",
            #"data: {"candidates":[{"content":{"parts":[{"text":"Touch"}],"role":"model"}}]}"#, "",
            #"data: {"candidates":[{"content":{"parts":[]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":9,"candidatesTokenCount":4}}"#, "",
        ])
        let events = try await collect(GeminiProvider(apiKey: key, client: client))

        // Fold through the real accumulator: this is how the app consumes it.
        var acc = StreamAccumulator()
        for event in events { try acc.apply(event) }

        #expect(acc.responseID == "r1")
        #expect(acc.text == "Force Touch")
        #expect(acc.finishReason == .stop)
        #expect(acc.usage == TokenUsage(inputTokens: 9, outputTokens: 4))
    }

    @Test("keeps thought parts out of the visible transcript")
    func separatesThoughtParts() async throws {
        let client = FixtureClient(lines: [
            #"data: {"candidates":[{"content":{"parts":[{"text":"weighing options","thought":true}]}}]}"#, "",
            #"data: {"candidates":[{"content":{"parts":[{"text":"the answer"}]},"finishReason":"STOP"}]}"#, "",
        ])
        var acc = StreamAccumulator()
        for event in try await collect(GeminiProvider(apiKey: key, client: client)) {
            try acc.apply(event)
        }
        #expect(acc.text == "the answer")
        #expect(acc.reasoning == "weighing options")
    }

    @Test("emits usage exactly once despite cumulative reporting")
    func emitsUsageOnce() async throws {
        // Gemini repeats usageMetadata on every chunk.
        let client = FixtureClient(lines: [
            #"data: {"candidates":[{"content":{"parts":[{"text":"a"}]}}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":1}}"#, "",
            #"data: {"candidates":[{"content":{"parts":[{"text":"b"}]}}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2}}"#, "",
            #"data: {"candidates":[{"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":3}}"#, "",
        ])
        let events = try await collect(GeminiProvider(apiKey: key, client: client))
        let usageEvents = events.filter { if case .usage = $0 { return true }; return false }
        #expect(usageEvents.count == 1)
        #expect(usageEvents.first == .usage(TokenUsage(inputTokens: 5, outputTokens: 3)))
    }

    @Test("emits exactly one terminal event")
    func emitsSingleTerminalEvent() async throws {
        let client = FixtureClient(lines: [
            #"data: {"candidates":[{"content":{"parts":[{"text":"x"}]},"finishReason":"STOP"}]}"#, "",
        ])
        let events = try await collect(GeminiProvider(apiKey: key, client: client))
        let terminals = events.filter { if case .finished = $0 { return true }; return false }
        #expect(terminals == [.finished(.stop)])
    }

    @Test("treats a stream that ends without a finish reason as a normal stop")
    func inferredStop() async throws {
        let client = FixtureClient(lines: [
            #"data: {"candidates":[{"content":{"parts":[{"text":"truncated"}]}}]}"#, "",
        ])
        var acc = StreamAccumulator()
        for event in try await collect(GeminiProvider(apiKey: key, client: client)) {
            try acc.apply(event)
        }
        #expect(acc.text == "truncated")
        #expect(acc.finishReason == .stop)
    }

    // MARK: - Finish reason mapping

    @Test("maps provider finish reasons", arguments: [
        ("STOP", FinishReason.stop),
        ("MAX_TOKENS", .maxTokens),
        ("SAFETY", .contentFilter),
        ("PROHIBITED_CONTENT", .contentFilter),
        ("WEIRD_NEW_REASON", .other("WEIRD_NEW_REASON")),
    ])
    func mapsFinishReasons(raw: String, expected: FinishReason) async throws {
        let client = FixtureClient(lines: [
            #"data: {"candidates":[{"content":{"parts":[]},"finishReason":"\#(raw)"}]}"#, "",
        ])
        let events = try await collect(GeminiProvider(apiKey: key, client: client))
        #expect(events.last == .finished(expected))
    }

    // MARK: - Errors

    @Test("maps 401 to unauthorized rather than a generic failure")
    func mapsUnauthorized() async throws {
        let client = FixtureClient(status: 401, lines: [
            #"{"error":{"code":401,"message":"API key not valid","status":"UNAUTHENTICATED"}}"#,
        ])
        await #expect(throws: AssistantError.unauthorized) {
            _ = try await collect(GeminiProvider(apiKey: key, client: client))
        }
    }

    @Test("maps 429 and carries Retry-After through")
    func mapsRateLimit() async throws {
        let client = FixtureClient(status: 429, headers: ["Retry-After": "30"], lines: ["{}"])
        await #expect(throws: AssistantError.rateLimited(retryAfter: 30)) {
            _ = try await collect(GeminiProvider(apiKey: key, client: client))
        }
    }

    @Test("surfaces the provider's own message on a server error")
    func mapsServerError() async throws {
        let client = FixtureClient(status: 500, lines: [
            #"{"error":{"code":500,"message":"backend overloaded","status":"INTERNAL"}}"#,
        ])
        await #expect(throws: AssistantError.serverError(status: 500, message: "backend overloaded")) {
            _ = try await collect(GeminiProvider(apiKey: key, client: client))
        }
    }

    @Test("server errors are retryable but auth errors are not")
    func retryability() {
        #expect(AssistantError.serverError(status: 503, message: nil).isRetryable)
        #expect(AssistantError.rateLimited(retryAfter: nil).isRetryable)
        #expect(AssistantError.unauthorized.isRetryable == false)
        #expect(AssistantError.missingCredentials.isRetryable == false)
    }

    @Test("an empty API key fails before any request is sent")
    func rejectsEmptyKey() async throws {
        let recorder = RequestRecorder()
        let client = FixtureClient(lines: [], recorder: recorder)
        await #expect(throws: AssistantError.missingCredentials) {
            _ = try await collect(GeminiProvider(apiKey: { "" }, client: client))
        }
        #expect(await recorder.request == nil)
    }

    @Test("a throwing key provider surfaces as missing credentials")
    func mapsKeychainFailure() async throws {
        struct Boom: Error {}
        let client = FixtureClient(lines: [])
        await #expect(throws: AssistantError.missingCredentials) {
            _ = try await collect(GeminiProvider(apiKey: { throw Boom() }, client: client))
        }
    }

    @Test("reports undecodable chunks instead of silently dropping them")
    func rejectsGarbage() async throws {
        let client = FixtureClient(lines: ["data: not json at all", ""])
        await #expect(throws: AssistantError.invalidResponse("undecodable stream chunk")) {
            _ = try await collect(GeminiProvider(apiKey: key, client: client))
        }
    }

    // MARK: - Request encoding

    @Test("sends the key as a header, never in the URL")
    func keyTravelsInHeader() async throws {
        let recorder = RequestRecorder()
        let client = FixtureClient(lines: [
            #"data: {"candidates":[{"finishReason":"STOP"}]}"#, "",
        ], recorder: recorder)
        _ = try await collect(GeminiProvider(apiKey: key, client: client))

        let sent = try #require(await recorder.request)
        #expect(sent.headers["x-goog-api-key"] == "test-key")
        // A key in a query string leaks into logs, proxies and crash reports.
        #expect(sent.url.absoluteString.contains("test-key") == false)
        #expect(sent.url.absoluteString.contains("alt=sse"))
        #expect(sent.url.absoluteString.contains("gemini-2.5-flash:streamGenerateContent"))
    }

    @Test("encodes roles, system instruction and images in Gemini's shape")
    func encodesBody() async throws {
        let recorder = RequestRecorder()
        let client = FixtureClient(lines: [
            #"data: {"candidates":[{"finishReason":"STOP"}]}"#, "",
        ], recorder: recorder)

        let request = AssistantRequest(
            model: "gemini-2.5-flash",
            systemInstruction: "Be concise.",
            messages: [
                ChatMessage(role: .user, text: "what is this"),
                ChatMessage(role: .assistant, text: "a trackpad"),
                ChatMessage(role: .user, parts: [
                    .text("and this?"),
                    .image(ImageAttachment(mimeType: "image/jpeg", data: Data([0xFF, 0xD8]))),
                ]),
            ]
        )
        _ = try await collect(GeminiProvider(apiKey: key, client: client), request: request)

        let sent = try #require(await recorder.request)
        let body = try #require(sent.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        let contents = try #require(json["contents"] as? [[String: Any]])
        #expect(contents.count == 3)
        // Gemini names the assistant role "model", not "assistant".
        #expect(contents.map { $0["role"] as? String } == ["user", "model", "user"])

        let systemParts = try #require((json["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])
        #expect(systemParts.first?["text"] as? String == "Be concise.")

        let lastParts = try #require(contents[2]["parts"] as? [[String: Any]])
        let inline = try #require(lastParts.compactMap { $0["inlineData"] as? [String: Any] }.first)
        #expect(inline["mimeType"] as? String == "image/jpeg")
        #expect(inline["data"] as? String == Data([0xFF, 0xD8]).base64EncodedString())
    }
}

@Suite("GeminiProvider stream robustness")
struct GeminiProviderRobustnessTests {

    private let key: APIKeyProvider = { "test-key" }

    private func collect(_ lines: [String]) async throws -> [AssistantStreamEvent] {
        let provider = GeminiProvider(apiKey: key, client: FixtureClient(lines: lines))
        var events: [AssistantStreamEvent] = []
        for try await event in provider.stream(AssistantRequest(
            model: "gemini-2.5-flash",
            messages: [ChatMessage(role: .user, text: "hi")]
        )) {
            events.append(event)
        }
        return events
    }

    @Test("ignores empty data lines instead of failing the stream")
    func toleratesEmptyDataLines() async throws {
        // Legal SSE, and Gemini emits them. JSONDecoder throws on empty input,
        // so failing to skip these aborts an otherwise healthy response.
        let events = try await collect([
            "data:", "",
            #"data: {"candidates":[{"content":{"parts":[{"text":"hello"}]}}]}"#, "",
            "data: ", "",
            #"data: {"candidates":[{"finishReason":"STOP"}]}"#, "",
        ])
        var acc = StreamAccumulator()
        for event in events { try acc.apply(event) }
        #expect(acc.text == "hello")
        #expect(acc.finishReason == .stop)
    }

    @Test("ignores whitespace-only data lines")
    func toleratesWhitespaceData() async throws {
        let events = try await collect([
            "data:    ", "",
            #"data: {"candidates":[{"content":{"parts":[{"text":"x"}]},"finishReason":"STOP"}]}"#, "",
        ])
        var acc = StreamAccumulator()
        for event in events { try acc.apply(event) }
        #expect(acc.text == "x")
    }

    @Test("tolerates a keep-alive comment mid-stream")
    func toleratesKeepAlive() async throws {
        let events = try await collect([
            ": ping", "",
            #"data: {"candidates":[{"content":{"parts":[{"text":"y"}]},"finishReason":"STOP"}]}"#, "",
        ])
        var acc = StreamAccumulator()
        for event in events { try acc.apply(event) }
        #expect(acc.text == "y")
    }

    @Test("tolerates a trailing [DONE] sentinel")
    func toleratesDoneSentinel() async throws {
        let events = try await collect([
            #"data: {"candidates":[{"content":{"parts":[{"text":"z"}]},"finishReason":"STOP"}]}"#, "",
            "data: [DONE]", "",
        ])
        var acc = StreamAccumulator()
        for event in events { try acc.apply(event) }
        #expect(acc.text == "z")
    }

    @Test("an empty stream still terminates cleanly")
    func emptyStreamTerminates() async throws {
        let events = try await collect([])
        #expect(events == [.finished(.stop)])
    }
}
