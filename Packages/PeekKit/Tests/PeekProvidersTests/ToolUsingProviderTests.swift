import Testing
import Foundation
import PeekCore
@testable import PeekProviders

/// A provider that replays a scripted round per request and records what it
/// was asked, so the loop's follow-up request can be inspected.
private struct RoundScriptedProvider: AssistantProvider {
    let identifier = ProviderIdentifier(rawValue: "rounds")
    let displayName = "Rounds"
    let models: [ModelDescriptor] = []

    let rounds: [[AssistantStreamEvent]]
    let recorder: ToolRoundRecorder

    func stream(_ request: AssistantRequest) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let index = await recorder.record(request)
                for event in rounds[min(index, rounds.count - 1)] {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}

private actor ToolRoundRecorder {
    private(set) var requests: [AssistantRequest] = []
    func record(_ request: AssistantRequest) -> Int {
        requests.append(request)
        return requests.count - 1
    }
    var count: Int { requests.count }
}

/// An executor with a fixed answer that records the calls it ran.
private final class StubExecutor: ToolExecuting, @unchecked Sendable {
    let tools: [ToolDefinition]
    let answer: String
    let isError: Bool
    private(set) var executed: [ToolCall] = []

    init(tools: [ToolDefinition] = [StubExecutor.weather],
         answer: String = "17C and raining",
         isError: Bool = false) {
        self.tools = tools
        self.answer = answer
        self.isError = isError
    }

    static let weather = ToolDefinition(
        name: "get_weather",
        description: "Current weather for a city.",
        parameters: [ToolParameter(name: "city", description: "City name",
                                   kind: .string, isRequired: true)],
        leavesTheMachine: false
    )

    func execute(_ call: ToolCall) async -> ToolResult {
        executed.append(call)
        return ToolResult(callID: call.id, name: call.name, content: answer, isError: isError)
    }
}

private func call(_ name: String = "get_weather", id: String = "c1") -> ToolCall {
    ToolCall(id: id, name: name, arguments: Data(#"{"city":"Paris"}"#.utf8))
}

private func collect(
    _ provider: some AssistantProvider,
    _ request: AssistantRequest = AssistantRequest(model: "m", messages: [
        ChatMessage(role: .user, text: "weather in paris?")
    ])
) async throws -> [AssistantStreamEvent] {
    var events: [AssistantStreamEvent] = []
    for try await event in provider.stream(request) { events.append(event) }
    return events
}

@Suite("ToolUsingProvider")
struct ToolUsingProviderTests {

    @Test("a tool call round-trips and the answer continues the same stream")
    func roundTrips() async throws {
        let recorder = ToolRoundRecorder()
        let executor = StubExecutor()
        let inner = RoundScriptedProvider(rounds: [
            [.responseStarted(id: "r1"), .toolCall(call()), .finished(.toolCalls)],
            [.responseStarted(id: "r2"), .textDelta("It is 17C and raining."), .finished(.stop)],
        ], recorder: recorder)

        let events = try await collect(ToolUsingProvider(wrapping: inner, executor: executor))

        // One terminal event only: the intermediate .finished(.toolCalls) must
        // not reach the consumer, whose accumulator would reject the rest.
        #expect(events.filter { if case .finished = $0 { return true }; return false }.count == 1)
        #expect(events.last == .finished(.stop))
        // The tool call is visible rather than hidden.
        #expect(events.contains(.toolCall(call())))
        #expect(events.contains(.textDelta("It is 17C and raining.")))
        // And only one responseStarted, from the first round.
        #expect(events.filter { if case .responseStarted = $0 { return true }; return false }.count == 1)
        #expect(executor.executed.map(\.name) == ["get_weather"])
    }

    @Test("the follow-up request carries the model's call and the tool's result")
    func sendsResultBack() async throws {
        let recorder = ToolRoundRecorder()
        let inner = RoundScriptedProvider(rounds: [
            [.toolCall(call()), .finished(.toolCalls)],
            [.textDelta("done"), .finished(.stop)],
        ], recorder: recorder)

        _ = try await collect(ToolUsingProvider(wrapping: inner, executor: StubExecutor()))

        #expect(await recorder.count == 2)
        let follow = await recorder.requests[1]
        // Original turn, then the assistant's call, then the result.
        #expect(follow.messages.count == 3)
        #expect(follow.messages[1].role == .assistant)
        #expect(follow.messages[1].parts == [.toolCall(call())])
        #expect(follow.messages[2].role == .user)
        #expect(follow.messages[2].parts == [
            .toolResult(ToolResult(callID: "c1", name: "get_weather", content: "17C and raining"))
        ])
    }

    @Test("tools are declared on every request")
    func declaresTools() async throws {
        let recorder = ToolRoundRecorder()
        let inner = RoundScriptedProvider(rounds: [
            [.toolCall(call()), .finished(.toolCalls)],
            [.textDelta("done"), .finished(.stop)],
        ], recorder: recorder)

        _ = try await collect(ToolUsingProvider(wrapping: inner, executor: StubExecutor()))

        for request in await recorder.requests {
            #expect(request.tools.map(\.name) == ["get_weather"])
        }
    }

    @Test("usage is summed across rounds, not reported per round")
    func sumsUsage() async throws {
        let inner = RoundScriptedProvider(rounds: [
            [.toolCall(call()), .usage(TokenUsage(inputTokens: 10, outputTokens: 5)), .finished(.toolCalls)],
            [.textDelta("ok"), .usage(TokenUsage(inputTokens: 20, outputTokens: 7)), .finished(.stop)],
        ], recorder: ToolRoundRecorder())

        let events = try await collect(ToolUsingProvider(wrapping: inner, executor: StubExecutor()))
        let usages = events.compactMap { event -> TokenUsage? in
            if case .usage(let u) = event { return u }
            return nil
        }

        // Each round is a billed request; reporting only the last would
        // undercount the turn in the user's statistics.
        #expect(usages.count == 1)
        #expect(usages.first?.inputTokens == 30)
        #expect(usages.first?.outputTokens == 12)
    }

    @Test("an unreported cache count stays unreported rather than becoming zero")
    func keepsCacheCountNil() async throws {
        let inner = RoundScriptedProvider(rounds: [
            [.toolCall(call()), .usage(TokenUsage(inputTokens: 1, outputTokens: 1)), .finished(.toolCalls)],
            [.usage(TokenUsage(inputTokens: 1, outputTokens: 1)), .finished(.stop)],
        ], recorder: ToolRoundRecorder())

        let events = try await collect(ToolUsingProvider(wrapping: inner, executor: StubExecutor()))
        let usage = events.compactMap { event -> TokenUsage? in
            if case .usage(let u) = event { return u }
            return nil
        }.first

        #expect(usage?.cachedInputTokens == nil)
    }

    @Test("a tool failure is reported to the model, not thrown")
    func reportsToolFailure() async throws {
        let recorder = ToolRoundRecorder()
        let executor = StubExecutor(answer: "the tool broke", isError: true)
        let inner = RoundScriptedProvider(rounds: [
            [.toolCall(call()), .finished(.toolCalls)],
            [.textDelta("I could not check."), .finished(.stop)],
        ], recorder: recorder)

        let events = try await collect(ToolUsingProvider(wrapping: inner, executor: executor))

        // The turn completes: a model told the tool failed can say so, while a
        // thrown error would lose the conversation.
        #expect(events.last == .finished(.stop))
        let follow = await recorder.requests[1]
        #expect(follow.messages[2].parts == [
            .toolResult(ToolResult(callID: "c1", name: "get_weather",
                                   content: "the tool broke", isError: true))
        ])
    }

    @Test("a model that keeps calling tools is stopped and the stream says so")
    func capsRounds() async throws {
        let recorder = ToolRoundRecorder()
        // Always asks for another tool call.
        let inner = RoundScriptedProvider(rounds: [
            [.toolCall(call()), .finished(.toolCalls)],
        ], recorder: recorder)

        let events = try await collect(
            ToolUsingProvider(wrapping: inner, executor: StubExecutor(), maxRounds: 3)
        )

        #expect(await recorder.count == 3)
        #expect(events.last == .finished(.other("stopped after 3 rounds of tool calls")))
        #expect(events.filter { if case .finished = $0 { return true }; return false }.count == 1)
    }

    @Test("with no tools to offer the provider is left untouched")
    func passesThroughWithoutTools() async throws {
        let recorder = ToolRoundRecorder()
        let inner = RoundScriptedProvider(rounds: [
            [.textDelta("plain"), .finished(.stop)],
        ], recorder: recorder)

        let events = try await collect(
            ToolUsingProvider(wrapping: inner, executor: StubExecutor(tools: []))
        )

        #expect(events == [.textDelta("plain"), .finished(.stop)])
        #expect(await recorder.requests[0].tools.isEmpty)
    }

    @Test("a turn needing no tools finishes in one round")
    func singleRound() async throws {
        let recorder = ToolRoundRecorder()
        let inner = RoundScriptedProvider(rounds: [
            [.textDelta("no tools needed"), .finished(.stop)],
        ], recorder: recorder)

        let events = try await collect(ToolUsingProvider(wrapping: inner, executor: StubExecutor()))

        #expect(await recorder.count == 1)
        #expect(events.last == .finished(.stop))
    }
}
