import Foundation

/// Folds a stream of ``AssistantStreamEvent`` into an assembled response.
///
/// Kept as a value type with a `mutating` step so it can be driven from the
/// main actor for live UI updates and from a background context for
/// persistence, without either needing its own reducer.
public struct StreamAccumulator: Sendable, Equatable {
    public private(set) var responseID: String?
    public private(set) var text: String = ""
    public private(set) var reasoning: String = ""
    public private(set) var toolCalls: [ToolCall] = []
    public private(set) var usage: TokenUsage?
    public private(set) var finishReason: FinishReason?

    public init() {}

    /// True once a terminal event has been folded in.
    public var isFinished: Bool { finishReason != nil }

    /// Applies one event.
    /// - Throws: ``StreamProtocolError`` when the provider adapter emits a
    ///   sequence that cannot be reduced — for example text after the stream
    ///   already finished. Adapters are the only place such a bug can
    ///   originate, so failing loudly here keeps it out of the UI.
    public mutating func apply(_ event: AssistantStreamEvent) throws {
        if isFinished, case .finished = event {
            throw StreamProtocolError.duplicateTerminalEvent
        }
        if isFinished {
            throw StreamProtocolError.eventAfterFinish
        }

        switch event {
        case .responseStarted(let id):
            responseID = id
        case .textDelta(let chunk):
            text += chunk
        case .textSnapshot(let snapshot):
            text = snapshot
        case .reasoningDelta(let chunk):
            reasoning += chunk
        case .toolCall(let call):
            toolCalls.append(call)
        case .usage(let u):
            usage = u
        case .finished(let reason):
            finishReason = reason
        }
    }
}

public enum StreamProtocolError: Error, Equatable, Sendable {
    /// More than one terminal event arrived.
    case duplicateTerminalEvent
    /// A non-terminal event arrived after the stream had finished.
    case eventAfterFinish
}
