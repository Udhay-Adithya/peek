import Testing
import Foundation
import PeekCore
import PeekProviders
import PeekSecurity
@testable import Peek

/// A secret store holding one key in memory, for the live test only.
private struct FixedSecretStore: SecretStore {
    let key: String
    func store(_ secret: String, for key: SecretKey) throws {}
    func secret(for key: SecretKey) throws -> String? { self.key }
    func remove(_ key: SecretKey) throws {}
}

/// The whole chain, live: settings → engine → tool wrapper → executor → store.
///
/// The unit tests cover each piece, and the provider-level live test covers the
/// wire format. This covers the wiring between them — that the engine actually
/// attaches the tool loop, that the executor reaches the real conversation
/// store, and that the answer comes back through the session's transcript with
/// the tool use recorded.
///
/// Opt-in: runs only when `PEEK_LIVE_GEMINI_KEY` is set, so CI is unaffected.
@Suite("Tool calling (live)", .serialized)
@MainActor
struct ToolCallingLiveTests {

    nonisolated private static var liveKey: String? {
        ProcessInfo.processInfo.environment["PEEK_LIVE_GEMINI_KEY"]
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    @Test("the assistant searches real conversation history and answers from it",
          .enabled(if: ToolCallingLiveTests.liveKey != nil),
          .timeLimit(.minutes(1)))
    func searchesHistoryEndToEnd() async throws {
        let key = try #require(Self.liveKey)
        let settings = makeTestSettings()
        settings.providerID = .gemini
        settings.modelID = "gemini-2.5-flash"
        settings.toolsEnabled = true

        let store = RecordingStore()
        // A title the model cannot know except by calling the tool.
        _ = try await store.createConversation(title: "Zarbleflex calibration notes",
                                               providerID: "gemini", modelID: "m",
                                               sourceAppName: nil)

        let engine = AssistantEngine(settings: settings,
                                     secrets: FixedSecretStore(key: key),
                                     store: store)
        let session = AssistantSession(engine: engine, store: store)

        session.send(prompt: """
            Search my past conversations for "zarbleflex" and tell me the exact \
            title of what you find.
            """, context: nil, attachments: [])

        // The turn runs on a detached task; wait for it to settle.
        for _ in 0..<600 {
            if !session.isStreaming, session.messages.last?.role == .assistant,
               session.messages.last?.isStreaming == false {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        let answer = try #require(session.messages.last)
        #expect(answer.failure == nil, "turn failed: \(answer.failure ?? "")")

        // The tool was used, and the transcript says so.
        #expect(answer.toolUses.map(\.name) == ["search_conversations"])
        #expect(answer.toolUses.first?.summary.contains("Searched your conversations") == true)
        // And the answer contains what only the tool could have supplied.
        #expect(answer.text.localizedCaseInsensitiveContains("Zarbleflex"))
    }

    @Test("with tools switched off the model is offered none",
          .enabled(if: ToolCallingLiveTests.liveKey != nil),
          .timeLimit(.minutes(1)))
    func respectsToolsDisabled() async throws {
        let key = try #require(Self.liveKey)
        let settings = makeTestSettings()
        settings.providerID = .gemini
        settings.toolsEnabled = false

        let engine = AssistantEngine(settings: settings,
                                     secrets: FixedSecretStore(key: key),
                                     store: RecordingStore())

        // The provider must not be the tool wrapper at all, so there is no
        // path by which a disabled tool could run.
        #expect(!(engine.currentProvider() is ToolUsingProvider))
    }

    @Test("with tools on the provider is wrapped")
    func wrapsWhenEnabled() {
        let settings = makeTestSettings()
        settings.providerID = .gemini
        settings.toolsEnabled = true

        let engine = AssistantEngine(settings: settings,
                                     secrets: FixedSecretStore(key: "k"),
                                     store: RecordingStore())

        #expect(engine.currentProvider() is ToolUsingProvider)
    }

    @Test("apple intelligence is never wrapped, since it cannot use this loop")
    func neverWrapsOnDevice() {
        let settings = makeTestSettings()
        settings.providerID = .appleIntelligence
        settings.toolsEnabled = true

        let engine = AssistantEngine(settings: settings,
                                     secrets: FixedSecretStore(key: "k"),
                                     store: RecordingStore())

        #expect(!(engine.currentProvider() is ToolUsingProvider))
    }
}
