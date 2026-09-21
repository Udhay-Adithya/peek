import Testing
import Foundation
import PeekCore
@testable import Peek

@Suite("AssistantSession")
@MainActor
struct AssistantSessionTests {

    private func makeSession(
        events: [AssistantStreamEvent] = [.textDelta("an answer"), .finished(.stop)],
        failure: Error? = nil,
        log: RequestLog? = nil,
        store: RecordingStore = RecordingStore()
    ) -> (AssistantSession, StubEngine, RecordingStore) {
        let provider = StubProvider(events: events, failure: failure, recorder: log)
        let engine = StubEngine(provider: provider)
        return (AssistantSession(engine: engine, store: store), engine, store)
    }

    /// Streams complete on a detached task, so tests wait for the transcript
    /// to settle rather than sleeping a fixed interval.
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Variant for conditions that must await an actor, such as the store.
    private func waitUntilAsync(_ condition: () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("shows the user's turn and streams the assistant's reply")
    func streamsATurn() async {
        let (session, _, _) = makeSession()
        session.send(prompt: "what is this", context: nil)

        await waitUntil { session.messages.count == 2 && !session.isStreaming }
        #expect(session.messages.map(\.role) == [.user, .assistant])
        #expect(session.messages[0].text == "what is this")
        #expect(session.messages[1].text == "an answer")
    }

    @Test("sends the user's turn exactly once")
    func doesNotDuplicateTheUserTurn() async {
        // Regression: history was snapshotted AFTER appending the new turn,
        // which sent every message twice.
        let log = RequestLog()
        let (session, _, _) = makeSession(log: log)
        session.send(prompt: "hello", context: nil)
        await waitUntil { !session.isStreaming }

        let request = await log.last
        #expect(request?.messages.count == 1)
        #expect(request?.messages.first?.plainText == "hello")
    }

    @Test("carries prior turns as history on the next request")
    func includesHistory() async {
        let log = RequestLog()
        let (session, _, _) = makeSession(log: log)

        session.send(prompt: "first", context: nil)
        await waitUntil { !session.isStreaming }
        session.send(prompt: "second", context: nil)
        await waitUntil { !session.isStreaming && session.messages.count == 4 }

        let request = await log.last
        #expect(request?.messages.map(\.plainText) == ["first", "an answer", "second"])
    }

    @Test("fences selected text into the request but shows the typed prompt")
    func separatesContextFromDisplay() async {
        let log = RequestLog()
        let (session, _, _) = makeSession(log: log)
        let context = SelectionContext(text: "obtund", sourceAppName: "Notes")

        session.send(prompt: "define", context: context)
        await waitUntil { !session.isStreaming }

        // The transcript shows what the user typed, not the composed payload.
        #expect(session.messages.first?.text == "define")
        let sent = await log.last?.messages.first?.plainText
        #expect(sent?.contains("obtund") == true)
        #expect(sent?.contains("Selected text from Notes") == true)
    }

    @Test("renders snapshot streaming as well as deltas")
    func handlesSnapshotProviders() async {
        // The on-device model streams cumulative snapshots.
        let (session, _, _) = makeSession(events: [
            .textSnapshot("The dog"), .textSnapshot("The cat sat"), .finished(.stop),
        ])
        session.send(prompt: "x", context: nil)
        await waitUntil { !session.isStreaming && session.messages.count == 2 }
        #expect(session.messages[1].text == "The cat sat")
    }

    @Test("surfaces a provider failure as a retryable message")
    func surfacesFailures() async {
        let (session, _, _) = makeSession(
            events: [], failure: AssistantError.serverError(status: 503, message: "busy")
        )
        session.send(prompt: "x", context: nil)
        await waitUntil { !session.isStreaming && session.messages.count == 2 }

        #expect(session.messages[1].failure?.contains("503") == true)
        #expect(session.messages[1].isRetryable)
    }

    @Test("does not offer retry for a rejected key")
    func authFailureIsNotRetryable() async {
        let (session, _, _) = makeSession(events: [], failure: AssistantError.unauthorized)
        session.send(prompt: "x", context: nil)
        await waitUntil { !session.isStreaming && session.messages.count == 2 }
        #expect(session.messages[1].isRetryable == false)
    }

    @Test("excludes a failed turn from subsequent history")
    func failedTurnsAreNotSentBack() async {
        let log = RequestLog()
        let store = RecordingStore()
        let failing = StubProvider(events: [], failure: AssistantError.unauthorized, recorder: log)
        let engine = StubEngine(provider: failing)
        let session = AssistantSession(engine: engine, store: store)

        session.send(prompt: "first", context: nil)
        await waitUntil { !session.isStreaming }

        engine.provider = StubProvider(events: [.textDelta("ok"), .finished(.stop)],
                                       failure: nil, recorder: log)
        session.send(prompt: "second", context: nil)
        await waitUntil { !session.isStreaming }

        // The error text must never be fed back to the model as context.
        let sent = await log.last?.messages.map(\.plainText) ?? []
        #expect(sent.contains { $0.contains("rejected") } == false)
    }

    @Test("records usage on the assistant turn")
    func recordsUsage() async {
        let (session, _, _) = makeSession(events: [
            .textDelta("hi"), .usage(TokenUsage(inputTokens: 11, outputTokens: 4)), .finished(.stop),
        ])
        session.send(prompt: "x", context: nil)
        await waitUntil { !session.isStreaming && session.messages.count == 2 }
        #expect(session.messages[1].usage == TokenUsage(inputTokens: 11, outputTokens: 4))
    }

    @Test("reports an empty response instead of showing a blank bubble")
    func reportsEmptyResponse() async {
        let (session, _, _) = makeSession(events: [.finished(.stop)])
        session.send(prompt: "x", context: nil)
        await waitUntil { !session.isStreaming && session.messages.count == 2 }
        #expect(session.messages[1].failure != nil)
    }

    @Test("explains a content-filtered response and does not offer retry")
    func explainsContentFilter() async {
        let (session, _, _) = makeSession(events: [.finished(.contentFilter)])
        session.send(prompt: "x", context: nil)
        await waitUntil { !session.isStreaming && session.messages.count == 2 }
        #expect(session.messages[1].failure?.contains("blocked") == true)
        #expect(session.messages[1].isRetryable == false)
    }

    @Test("refuses to send with neither prompt nor context")
    func refusesEmptySend() async {
        let (session, _, _) = makeSession()
        session.send(prompt: "   ", context: nil)
        #expect(session.messages.isEmpty)
    }

    @Test("reset clears the transcript and starts a new conversation")
    func resetStartsFresh() async {
        let (session, _, _) = makeSession()
        session.send(prompt: "x", context: nil)
        await waitUntil { !session.isStreaming }
        #expect(session.conversationID != nil)

        session.reset()
        #expect(session.messages.isEmpty)
        #expect(session.conversationID == nil)
    }

    // MARK: - Persistence

    @Test("persists both turns into one conversation")
    func persistsTurns() async {
        let store = RecordingStore()
        let (session, _, _) = makeSession(store: store)
        session.send(prompt: "a question", context: nil)
        await waitUntil { !session.isStreaming }

        await waitUntilAsync { (try? await store.messages(in: session.conversationID ?? ConversationID()).count) == 2 }
        let id = session.conversationID
        #expect(id != nil)
        let stored = try? await store.messages(in: id!)
        #expect(stored?.map(\.role) == [.user, .assistant])
        #expect(stored?.map(\.text) == ["a question", "an answer"])
    }

    @Test("two rapid sends land in one conversation, not two")
    func doesNotCreateDuplicateConversations() async {
        // Persistence is chained precisely because the first call may still be
        // creating the conversation when the second arrives.
        let store = RecordingStore()
        let (session, _, _) = makeSession(store: store)

        session.send(prompt: "first", context: nil)
        session.send(prompt: "second", context: nil)
        await waitUntil { !session.isStreaming }
        await waitUntilAsync { await store.createCount >= 1 }
        try? await Task.sleep(for: .milliseconds(120))

        #expect(await store.createCount == 1)
    }

    @Test("loads a stored conversation into the transcript")
    func loadsStoredConversation() async {
        let store = RecordingStore()
        let id = try! await store.seedRecent(title: "earlier", sourceAppName: "Notes")
        let (session, _, _) = makeSession(store: store)

        await session.load(id)
        #expect(session.messages.map(\.text) == ["earlier question", "earlier answer"])
        #expect(session.conversationID == id)
    }

    // MARK: - Cancellation

    @Test("cancelling marks the turn and stops streaming")
    func cancellationStops() async {
        let (session, _, _) = makeSession(events: [.textDelta("partial")], failure: nil)
        session.send(prompt: "x", context: nil)
        session.cancel()

        #expect(session.isStreaming == false)
        #expect(session.messages.last?.isStreaming == false)
    }

    @Test("reports streaming state so the menu bar can reflect it")
    func reportsStreamingState() async {
        let (session, _, _) = makeSession()
        var observed: [Bool] = []
        session.onStreamingChange = { observed.append($0) }

        session.send(prompt: "x", context: nil)
        await waitUntil { !session.isStreaming }

        #expect(observed.first == true)
        #expect(observed.last == false)
    }
}
