import Foundation
import PeekCore

/// Runs the tool-call loop around any provider that reports tool calls as
/// stream events.
///
/// A decorator rather than logic inside each adapter: the loop — ask, receive a
/// call, run it, ask again with the result — is identical for every HTTP
/// provider, and an adapter's job is translation, not orchestration. The same
/// shape as ``RetryingProvider``.
///
/// **Not for every provider.** Two requirements:
///
/// * The provider must report tool calls as ``AssistantStreamEvent/toolCall(_:)``
///   and accept ``ContentPart/toolCall(_:)`` and ``ContentPart/toolResult(_:)``
///   in a request. Apple Intelligence does neither — the Foundation Models
///   framework calls Swift tools itself, inside its own session — so it is
///   given tools directly and is never wrapped.
/// * The provider must stream text as deltas, not snapshots. A snapshot
///   *replaces* the text so far, so a second round would erase what the model
///   said before calling the tool.
public struct ToolUsingProvider: AssistantProvider {

    private let wrapped: any AssistantProvider
    private let executor: any ToolExecuting
    private let maxRounds: Int

    /// - Parameter maxRounds: how many times the model may call tools in one
    ///   turn before the loop gives up. A model can otherwise call the same
    ///   tool forever, and each round is a paid request.
    public init(wrapping wrapped: any AssistantProvider,
                executor: any ToolExecuting,
                maxRounds: Int = 5) {
        self.wrapped = wrapped
        self.executor = executor
        self.maxRounds = maxRounds
    }

    public var identifier: ProviderIdentifier { wrapped.identifier }
    public var displayName: String { wrapped.displayName }
    public var models: [ModelDescriptor] { wrapped.models }
    public var requiresAPIKey: Bool { wrapped.requiresAPIKey }

    public func stream(_ request: AssistantRequest) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
        // No tools to offer: pass straight through, so a turn that cannot use
        // tools is not reshaped by this type at all.
        guard !executor.tools.isEmpty else { return wrapped.stream(request) }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var messages = request.messages
                var totalUsage: TokenUsage?
                var startedForwarded = false

                for round in 1...maxRounds {
                    var turn = request
                    turn.messages = messages
                    turn.tools = executor.tools

                    var calls: [ToolCall] = []
                    var finish: FinishReason?

                    do {
                        for try await event in wrapped.stream(turn) {
                            try Task.checkCancellation()
                            switch event {
                            case .toolCall(let call):
                                calls.append(call)
                                // Forwarded so the transcript can show the
                                // tool being used rather than hiding it.
                                continuation.yield(event)

                            case .finished(let reason):
                                // Swallowed: an intermediate round's terminal
                                // event is not this stream's terminal event,
                                // and forwarding it would make a consumer's
                                // accumulator reject everything after it.
                                finish = reason

                            case .responseStarted:
                                guard !startedForwarded else { break }
                                startedForwarded = true
                                continuation.yield(event)

                            case .usage(let usage):
                                // Summed, not forwarded: every round is a
                                // billed request, and emitting each one would
                                // leave the consumer showing only the last.
                                totalUsage = Self.add(usage, to: totalUsage)

                            case .textDelta, .textSnapshot, .reasoningDelta:
                                continuation.yield(event)
                            }
                        }
                    } catch is CancellationError {
                        continuation.finish()
                        return
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }

                    // No tools wanted: this round's answer is the answer.
                    guard !calls.isEmpty else {
                        if let totalUsage { continuation.yield(.usage(totalUsage)) }
                        continuation.yield(.finished(finish ?? .stop))
                        continuation.finish()
                        return
                    }

                    guard round < maxRounds else { break }

                    // The model's own calls go back verbatim, then the results,
                    // so the next round sees the history it produced.
                    messages.append(ChatMessage(role: .assistant,
                                                parts: calls.map { .toolCall($0) }))

                    var results: [ContentPart] = []
                    for call in calls {
                        results.append(.toolResult(await executor.execute(call)))
                    }
                    messages.append(ChatMessage(role: .user, parts: results))
                }

                // Round limit hit with the model still asking for tools.
                // Reported rather than passed off as a normal finish: the
                // answer is incomplete and the transcript should say so.
                if let totalUsage { continuation.yield(.usage(totalUsage)) }
                continuation.yield(.finished(.other("stopped after \(maxRounds) rounds of tool calls")))
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func add(_ usage: TokenUsage, to total: TokenUsage?) -> TokenUsage {
        guard let total else { return usage }
        return TokenUsage(
            inputTokens: total.inputTokens + usage.inputTokens,
            outputTokens: total.outputTokens + usage.outputTokens,
            // Left nil when neither round reported it: nil means "not
            // reported", which is not the same claim as zero.
            cachedInputTokens: total.cachedInputTokens == nil && usage.cachedInputTokens == nil
                ? nil
                : (total.cachedInputTokens ?? 0) + (usage.cachedInputTokens ?? 0)
        )
    }
}
