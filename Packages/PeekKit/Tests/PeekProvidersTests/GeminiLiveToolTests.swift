import Testing
import Foundation
import PeekCore
@testable import PeekProviders

/// A real round trip against Gemini, through the real adapter and tool loop.
///
/// Exists because the unit tests above assert on *our* encoder's output, which
/// proves it matches what we believe the wire format to be — not that Google
/// agrees. This test is what catches a wrong field name, a rejected schema, or
/// a role the API will not accept.
///
/// Opt-in: runs only when `PEEK_LIVE_GEMINI_KEY` is set, so CI and
/// contributors without a key are unaffected. It makes two billed requests.
@Suite("Gemini live tool calling", .serialized)
struct GeminiLiveToolTests {

    private static var liveKey: String? {
        ProcessInfo.processInfo.environment["PEEK_LIVE_GEMINI_KEY"]
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Answers with a fixed, unguessable fact, so a passing test cannot be the
    /// model reciting background knowledge about the weather.
    private struct CanaryExecutor: ToolExecuting {
        let tools = [ToolDefinition(
            name: "get_weather",
            description: "Get the current weather for a city.",
            parameters: [ToolParameter(name: "city", description: "The city name.",
                                       kind: .string, isRequired: true)],
            leavesTheMachine: false
        )]

        func execute(_ call: ToolCall) async -> ToolResult {
            ToolResult(callID: call.id.isEmpty ? nil : call.id,
                       name: call.name,
                       content: "41 degrees and hailing")
        }
    }

    @Test("the model calls the tool and answers from its result",
          .enabled(if: GeminiLiveToolTests.liveKey != nil),
          .timeLimit(.minutes(1)))
    func liveRoundTrip() async throws {
        let key = try #require(Self.liveKey)
        let provider = ToolUsingProvider(
            wrapping: GeminiProvider(apiKey: { key }),
            executor: CanaryExecutor()
        )

        var events: [AssistantStreamEvent] = []
        for try await event in provider.stream(AssistantRequest(
            // Pinned rather than using the default: this test is about the
            // wire format, and a default that is busy would fail it for an
            // unrelated reason.
            model: "gemini-2.5-flash",
            messages: [ChatMessage(role: .user,
                                   text: "What is the weather in Paris right now? Use the tool.")]
        )) {
            events.append(event)
        }

        var accumulator = StreamAccumulator()
        for event in events { try accumulator.apply(event) }

        #expect(accumulator.toolCalls.map(\.name) == ["get_weather"])
        // The canary proves the answer came from the tool result rather than
        // from the model's own notion of the weather.
        #expect(accumulator.text.contains("41"))
        #expect(accumulator.finishReason == .stop)
    }
}
