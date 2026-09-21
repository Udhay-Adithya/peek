import Foundation
import PeekCore

/// Google Gemini, via `streamGenerateContent?alt=sse`.
///
/// Gemini's wire format is about as far from OpenAI's as mainstream providers
/// get — `contents`/`parts` instead of `messages`, `inlineData` for images, a
/// header-borne key, roles of `user`/`model`, and cumulative usage metadata. It
/// was chosen as the first adapter precisely for that reason: an abstraction
/// that survives Gemini is unlikely to be secretly OpenAI-shaped.
public struct GeminiProvider: AssistantProvider {

    public let identifier = ProviderIdentifier.gemini
    public let displayName = "Google Gemini"

    public let models: [ModelDescriptor] = [
        ModelDescriptor(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", supportsImages: true),
        ModelDescriptor(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", supportsImages: true),
        ModelDescriptor(id: "gemini-2.5-flash-lite", displayName: "Gemini 2.5 Flash Lite", supportsImages: true),
    ]

    private let client: StreamingHTTPClient
    private let apiKey: APIKeyProvider
    private let baseURL: URL

    public init(apiKey: @escaping APIKeyProvider,
                client: StreamingHTTPClient = URLSessionStreamingClient(),
                baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!) {
        self.apiKey = apiKey
        self.client = client
        self.baseURL = baseURL
    }

    public func stream(_ request: AssistantRequest) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AssistantError.cancelled)
                } catch let error as AssistantError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: AssistantError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: AssistantRequest,
                     into continuation: AsyncThrowingStream<AssistantStreamEvent, Error>.Continuation) async throws {

        let key = try await resolveKey()
        let spec = try makeRequestSpec(request, key: key)
        let (head, lines) = try await client.stream(spec)

        guard head.isSuccess else {
            throw try await mapFailure(head: head, lines: lines)
        }

        var parser = SSEParser()
        var startedEmitted = false
        var latestUsage: TokenUsage?
        var finish: FinishReason?

        func handle(_ event: ServerSentEvent) throws {
            // Some providers terminate with a sentinel; Gemini does not, but
            // tolerating it costs nothing and keeps the parser reusable.
            guard event.data != "[DONE]" else { return }

            let chunk: GeminiChunk
            do {
                chunk = try JSONDecoder().decode(GeminiChunk.self, from: Data(event.data.utf8))
            } catch {
                throw AssistantError.invalidResponse("undecodable stream chunk")
            }

            if !startedEmitted {
                startedEmitted = true
                continuation.yield(.responseStarted(id: chunk.responseId))
            }

            if let candidate = chunk.candidates?.first {
                for part in candidate.content?.parts ?? [] {
                    guard let text = part.text, !text.isEmpty else { continue }
                    // Gemini marks chain-of-thought parts with `thought: true`.
                    // Keeping them out of the visible transcript matters: they
                    // are not the answer.
                    continuation.yield(part.thought == true ? .reasoningDelta(text) : .textDelta(text))
                }
                if let reason = candidate.finishReason {
                    finish = Self.mapFinishReason(reason)
                }
            }

            // Usage is cumulative and repeats on every chunk. Retained and
            // emitted once at the end rather than spamming the accumulator.
            if let usage = chunk.usageMetadata {
                latestUsage = TokenUsage(
                    inputTokens: usage.promptTokenCount ?? 0,
                    outputTokens: usage.candidatesTokenCount ?? 0,
                    cachedInputTokens: usage.cachedContentTokenCount
                )
            }
        }

        for try await line in lines {
            try Task.checkCancellation()
            if let event = parser.consume(line: line) {
                try handle(event)
            }
        }
        if let trailing = parser.finish() {
            try handle(trailing)
        }

        if let latestUsage {
            continuation.yield(.usage(latestUsage))
        }
        // A stream that ends without an explicit reason still terminated
        // normally; the accumulator requires exactly one terminal event.
        continuation.yield(.finished(finish ?? .stop))
    }

    private func resolveKey() async throws -> String {
        let key: String
        do {
            key = try await apiKey()
        } catch {
            throw AssistantError.missingCredentials
        }
        guard !key.isEmpty else { throw AssistantError.missingCredentials }
        return key
    }

    // MARK: - Request encoding

    private func makeRequestSpec(_ request: AssistantRequest, key: String) throws -> HTTPRequestSpec {
        let url = baseURL
            .appending(path: "models/\(request.model):streamGenerateContent")
            .appending(queryItems: [URLQueryItem(name: "alt", value: "sse")])

        let body = GeminiRequestBody(
            contents: request.messages.map(Self.encode),
            systemInstruction: request.systemInstruction.map {
                GeminiContent(role: nil, parts: [GeminiPart(text: $0)])
            },
            generationConfig: GeminiGenerationConfig(
                temperature: request.temperature,
                maxOutputTokens: request.maxOutputTokens
            )
        )

        return HTTPRequestSpec(
            url: url,
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                // Header rather than a query parameter: a key in a URL leaks
                // into logs, proxies and crash reports.
                "x-goog-api-key": key,
                "Accept": "text/event-stream",
            ],
            body: try JSONEncoder().encode(body)
        )
    }

    private static func encode(_ message: ChatMessage) -> GeminiContent {
        GeminiContent(
            role: message.role == .user ? "user" : "model",
            parts: message.parts.map { part in
                switch part {
                case .text(let value):
                    return GeminiPart(text: value)
                case .image(let attachment):
                    return GeminiPart(inlineData: GeminiInlineData(
                        mimeType: attachment.mimeType,
                        data: attachment.data.base64EncodedString()
                    ))
                }
            }
        )
    }

    // MARK: - Failure mapping

    private func mapFailure(head: HTTPResponseHead,
                            lines: AsyncThrowingStream<String, Error>) async throws -> AssistantError {
        // Drain the error body; it carries the provider's explanation.
        var body = ""
        for try await line in lines { body += line }

        let message = (try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: Data(body.utf8)))?.error.message

        switch head.statusCode {
        case 401, 403:
            return .unauthorized
        case 429:
            let retryAfter = head.headers["Retry-After"].flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .serverError(status: head.statusCode, message: message)
        }
    }

    private static func mapFinishReason(_ raw: String) -> FinishReason {
        switch raw.uppercased() {
        case "STOP":         return .stop
        case "MAX_TOKENS":   return .maxTokens
        case "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII":
            return .contentFilter
        default:             return .other(raw)
        }
    }
}

// MARK: - Wire types

private struct GeminiRequestBody: Encodable {
    let contents: [GeminiContent]
    let systemInstruction: GeminiContent?
    let generationConfig: GeminiGenerationConfig?
}

private struct GeminiContent: Encodable {
    let role: String?
    let parts: [GeminiPart]
}

private struct GeminiPart: Encodable {
    var text: String?
    var inlineData: GeminiInlineData?
}

private struct GeminiInlineData: Encodable {
    let mimeType: String
    let data: String
}

private struct GeminiGenerationConfig: Encodable {
    let temperature: Double?
    let maxOutputTokens: Int?
}

private struct GeminiChunk: Decodable {
    let candidates: [GeminiCandidate]?
    let usageMetadata: GeminiUsage?
    let responseId: String?
}

private struct GeminiCandidate: Decodable {
    let content: GeminiResponseContent?
    let finishReason: String?
}

private struct GeminiResponseContent: Decodable {
    let parts: [GeminiResponsePart]?
}

private struct GeminiResponsePart: Decodable {
    let text: String?
    let thought: Bool?
}

private struct GeminiUsage: Decodable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let cachedContentTokenCount: Int?
}

private struct GeminiErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let code: Int?
        let message: String?
        let status: String?
    }
    let error: Payload
}
