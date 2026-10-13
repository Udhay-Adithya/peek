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

// MARK: - Tool calling

extension GeminiProviderTests {

    private static let weather = ToolDefinition(
        name: "get_weather",
        description: "Current weather for a city.",
        parameters: [
            ToolParameter(name: "city", description: "City name", kind: .string, isRequired: true),
            ToolParameter(name: "days", description: "Forecast length", kind: .integer, isRequired: false),
        ],
        leavesTheMachine: true
    )

    /// The request body as JSON, for asserting on the wire format rather than
    /// on our own encoder types.
    private func sentBody(_ recorder: RequestRecorder) async throws -> [String: Any] {
        let sent = try #require(await recorder.request)
        let body = try #require(sent.body)
        let object = try JSONSerialization.jsonObject(with: body)
        return try #require(object as? [String: Any])
    }

    @Test("declares tools as functionDeclarations with a JSON Schema")
    func declaresTools() async throws {
        let recorder = RequestRecorder()
        let client = FixtureClient(lines: [
            #"data: {"candidates":[{"finishReason":"STOP"}]}"#, "",
        ], recorder: recorder)

        _ = try await collect(GeminiProvider(apiKey: key, client: client),
                              request: AssistantRequest(model: "gemini-2.5-flash",
                                                        messages: [ChatMessage(role: .user, text: "hi")],
                                                        tools: [Self.weather]))

        let json = try await sentBody(recorder)
        let tools = try #require(json["tools"] as? [[String: Any]])
        let declarations = try #require(tools.first?["functionDeclarations"] as? [[String: Any]])
        #expect(declarations.count == 1)
        #expect(declarations[0]["name"] as? String == "get_weather")

        let schema = try #require(declarations[0]["parameters"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["city", "days"])
        let city = try #require(properties["city"] as? [String: Any])
        #expect(city["type"] as? String == "string")
        // Only the required ones, and the optional one must not appear.
        #expect(schema["required"] as? [String] == ["city"])
    }

    @Test("omits tools entirely when none are offered")
    func omitsToolsWhenEmpty() async throws {
        let recorder = RequestRecorder()
        let client = FixtureClient(lines: [
            #"data: {"candidates":[{"finishReason":"STOP"}]}"#, "",
        ], recorder: recorder)

        _ = try await collect(GeminiProvider(apiKey: key, client: client))

        // An empty `tools` array is not the same request as sending none.
        let json = try await sentBody(recorder)
        #expect(json["tools"] == nil)
    }

    @Test("omits `required` rather than sending an empty array")
    func omitsEmptyRequired() async throws {
        let recorder = RequestRecorder()
        let client = FixtureClient(lines: [
            #"data: {"candidates":[{"finishReason":"STOP"}]}"#, "",
        ], recorder: recorder)
        let optionalOnly = ToolDefinition(
            name: "ping", description: "ping", parameters: [
                ToolParameter(name: "note", description: "note", kind: .string, isRequired: false),
            ], leavesTheMachine: false)

        _ = try await collect(GeminiProvider(apiKey: key, client: client),
                              request: AssistantRequest(model: "m",
                                                        messages: [ChatMessage(role: .user, text: "hi")],
                                                        tools: [optionalOnly]))

        let json = try await sentBody(recorder)
        let tools = try #require(json["tools"] as? [[String: Any]])
        let declarations = try #require(tools.first?["functionDeclarations"] as? [[String: Any]])
        let schema = try #require(declarations[0]["parameters"] as? [String: Any])
        #expect(schema["required"] == nil)
    }

    @Test("decodes a functionCall part into a tool call event")
    func decodesFunctionCall() async throws {
        let client = FixtureClient(lines: [
            #"data: {"candidates":[{"content":{"parts":[{"functionCall":{"id":"call-1","name":"get_weather","args":{"city":"Paris"}}}],"role":"model"}}],"responseId":"r1"}"#, "",
            #"data: {"candidates":[{"finishReason":"STOP"}]}"#, "",
        ])

        let events = try await collect(GeminiProvider(apiKey: key, client: client))

        let calls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let call) = event { return call }
            return nil
        }
        #expect(calls.count == 1)
        #expect(calls.first?.id == "call-1")
        #expect(calls.first?.name == "get_weather")
        // Arguments stay raw for the tool that owns the schema to decode.
        let rawArguments = try #require(calls.first?.arguments)
        let decodedArguments = try JSONSerialization.jsonObject(with: rawArguments)
        let args = try #require(decodedArguments as? [String: Any])
        #expect(args["city"] as? String == "Paris")
    }

    @Test("a missing call id decodes as empty rather than failing")
    func decodesFunctionCallWithoutID() async throws {
        // Observed on some models: the id is simply absent.
        let client = FixtureClient(lines: [
            #"data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"get_weather","args":{}}}],"role":"model"}}]}"#, "",
            #"data: {"candidates":[{"finishReason":"STOP"}]}"#, "",
        ])

        let events = try await collect(GeminiProvider(apiKey: key, client: client))
        let calls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let call) = event { return call }
            return nil
        }
        #expect(calls.first?.id == "")
        #expect(calls.first?.name == "get_weather")
    }

    @Test("a functionCall part is not also emitted as text")
    func functionCallIsNotText() async throws {
        let client = FixtureClient(lines: [
            #"data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"get_weather","args":{}}}],"role":"model"}}]}"#, "",
            #"data: {"candidates":[{"finishReason":"STOP"}]}"#, "",
        ])

        let events = try await collect(GeminiProvider(apiKey: key, client: client))
        #expect(!events.contains { if case .textDelta = $0 { return true }; return false })
    }

    @Test("sends a tool result back as a functionResponse in a user turn")
    func encodesToolResult() async throws {
        let recorder = RequestRecorder()
        let client = FixtureClient(lines: [
            #"data: {"candidates":[{"finishReason":"STOP"}]}"#, "",
        ], recorder: recorder)

        let call = ToolCall(id: "call-1", name: "get_weather",
                            arguments: Data(#"{"city":"Paris"}"#.utf8))
        let request = AssistantRequest(model: "m", messages: [
            ChatMessage(role: .user, text: "weather?"),
            ChatMessage(role: .assistant, parts: [.toolCall(call)]),
            ChatMessage(role: .user, parts: [.toolResult(
                ToolResult(callID: "call-1", name: "get_weather", content: "17C")
            )]),
        ], tools: [Self.weather])

        _ = try await collect(GeminiProvider(apiKey: key, client: client), request: request)

        let json = try await sentBody(recorder)
        let contents = try #require(json["contents"] as? [[String: Any]])
        #expect(contents.count == 3)

        // The model's own call is replayed under the model role.
        #expect(contents[1]["role"] as? String == "model")
        let callPart = try #require((contents[1]["parts"] as? [[String: Any]])?.first)
        let functionCall = try #require(callPart["functionCall"] as? [String: Any])
        #expect(functionCall["name"] as? String == "get_weather")
        #expect(functionCall["id"] as? String == "call-1")
        // Arguments survive the round trip unchanged.
        #expect((functionCall["args"] as? [String: Any])?["city"] as? String == "Paris")

        // Gemini allows only "user" or "model", so a result travels as user.
        #expect(contents[2]["role"] as? String == "user")
        let resultPart = try #require((contents[2]["parts"] as? [[String: Any]])?.first)
        let response = try #require(resultPart["functionResponse"] as? [String: Any])
        #expect(response["name"] as? String == "get_weather")
        #expect(response["id"] as? String == "call-1")
        #expect((response["response"] as? [String: Any])?["result"] as? String == "17C")
    }

    @Test("a failed tool is reported to the model as an error payload")
    func encodesToolError() async throws {
        let recorder = RequestRecorder()
        let client = FixtureClient(lines: [
            #"data: {"candidates":[{"finishReason":"STOP"}]}"#, "",
        ], recorder: recorder)

        let request = AssistantRequest(model: "m", messages: [
            ChatMessage(role: .user, parts: [.toolResult(
                ToolResult(callID: nil, name: "get_weather", content: "network down", isError: true)
            )]),
        ], tools: [Self.weather])

        _ = try await collect(GeminiProvider(apiKey: key, client: client), request: request)

        let json = try await sentBody(recorder)
        let contents = try #require(json["contents"] as? [[String: Any]])
        let part = try #require((contents[0]["parts"] as? [[String: Any]])?.first)
        let response = try #require(part["functionResponse"] as? [String: Any])
        // A model that cannot tell "no results" from "the tool broke" invents
        // the answer, so the distinction is carried in the payload.
        #expect((response["response"] as? [String: Any])?["error"] as? String == "network down")
        #expect(response["id"] == nil)
    }
}
