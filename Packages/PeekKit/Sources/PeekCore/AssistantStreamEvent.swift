import Foundation

/// The provider-neutral streaming vocabulary.
///
/// Every provider adapter translates its own wire dialect (Gemini's
/// `streamGenerateContent?alt=sse`, OpenAI's chat completion chunks,
/// Anthropic's typed SSE frames) into this one enum. The UI, persistence layer
/// and tests know only this type, which is what keeps provider specifics from
/// leaking into the rest of the app.
///
/// Errors are not cases here — they are thrown through the enclosing
/// `AsyncThrowingStream`, so a consumer cannot forget to handle them.
public enum AssistantStreamEvent: Sendable, Equatable {
    /// The provider accepted the request and a response is starting.
    case responseStarted(id: String?)
    /// A chunk of user-visible assistant text, appended to what came before.
    case textDelta(String)
    /// The complete user-visible text so far, replacing anything prior.
    ///
    /// Not redundant with ``textDelta``: Apple's on-device Foundation Models
    /// framework streams cumulative snapshots rather than increments, and a
    /// snapshot may *revise* earlier text rather than only extend it. Diffing
    /// snapshots into deltas would corrupt the transcript the moment a
    /// revision arrived, so the vocabulary carries both shapes and the
    /// accumulator handles each correctly.
    case textSnapshot(String)
    /// A chunk of model reasoning, where the provider exposes it separately.
    case reasoningDelta(String)
    /// A tool invocation has been fully decoded. Reserved; not yet emitted.
    case toolCall(ToolCall)
    /// Token accounting, where the provider reports it.
    case usage(TokenUsage)
    /// Terminal event. Exactly one per successful stream.
    case finished(FinishReason)
}

public enum FinishReason: Sendable, Equatable {
    case stop
    case maxTokens
    case toolCalls
    case contentFilter
    case cancelled
    case other(String)
}

public struct TokenUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    /// Prompt tokens served from the provider's cache, where reported.
    public var cachedInputTokens: Int?

    public init(inputTokens: Int, outputTokens: Int, cachedInputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
    }

    public var totalTokens: Int { inputTokens + outputTokens }
}

/// Reserved for the tool-calling phase. Defined now so the stream vocabulary
/// does not have to change shape later.
public struct ToolCall: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Raw JSON arguments, decoded by the tool implementation rather than here.
    public let arguments: Data

    public init(id: String, name: String, arguments: Data) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}
