import Testing
import Foundation
import PeekCore
@testable import PeekProviders

/// A provider whose per-attempt behaviour is scripted.
struct ScriptedProvider: AssistantProvider {
    let identifier = ProviderIdentifier(rawValue: "scripted")
    let displayName = "Scripted"
    let models: [ModelDescriptor] = []

    enum Attempt: Sendable {
        case fail(AssistantError)
        /// Emits the given deltas, then fails.
        case emitThenFail([String], AssistantError)
        case succeed(String)
    }

    let attempts: [Attempt]
    let counter: AttemptCounter

    func stream(_ request: AssistantRequest) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let index = await counter.next()
                let behaviour = attempts[min(index, attempts.count - 1)]
                switch behaviour {
                case .fail(let error):
                    continuation.finish(throwing: error)
                case .emitThenFail(let deltas, let error):
                    for delta in deltas { continuation.yield(.textDelta(delta)) }
                    continuation.finish(throwing: error)
                case .succeed(let text):
                    continuation.yield(.textDelta(text))
                    continuation.yield(.finished(.stop))
                    continuation.finish()
                }
            }
        }
    }
}

actor AttemptCounter {
    private var count = 0
    func next() -> Int { defer { count += 1 }; return count }
    var total: Int { count }
}

@Suite("RetryingProvider")
struct RetryingProviderTests {

    private let request = AssistantRequest(model: "m", messages: [ChatMessage(role: .user, text: "hi")])
    /// No real waiting in tests.
    private let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

    private func collect(_ provider: some AssistantProvider) async throws -> [AssistantStreamEvent] {
        var events: [AssistantStreamEvent] = []
        for try await event in provider.stream(request) { events.append(event) }
        return events
    }

    @Test("retries a transient 503 and succeeds")
    func retriesTransientFailure() async throws {
        let counter = AttemptCounter()
        let base = ScriptedProvider(attempts: [
            .fail(.serverError(status: 503, message: "high demand")),
            .succeed("recovered"),
        ], counter: counter)

        let events = try await collect(RetryingProvider(wrapping: base, sleep: noSleep))
        #expect(events.contains(.textDelta("recovered")))
        #expect(await counter.total == 2)
    }

    @Test("gives up after the attempt budget and reports the last error")
    func respectsAttemptBudget() async throws {
        let counter = AttemptCounter()
        let base = ScriptedProvider(attempts: [
            .fail(.serverError(status: 503, message: "busy")),
        ], counter: counter)

        await #expect(throws: AssistantError.serverError(status: 503, message: "busy")) {
            _ = try await collect(RetryingProvider(wrapping: base, maxAttempts: 3, sleep: noSleep))
        }
        #expect(await counter.total == 3)
    }

    @Test("does not retry a non-retryable error")
    func doesNotRetryAuthFailure() async throws {
        let counter = AttemptCounter()
        let base = ScriptedProvider(attempts: [.fail(.unauthorized)], counter: counter)

        await #expect(throws: AssistantError.unauthorized) {
            _ = try await collect(RetryingProvider(wrapping: base, sleep: noSleep))
        }
        // A bad key will not fix itself; retrying only wastes the user's time.
        #expect(await counter.total == 1)
    }

    @Test("never retries once output has reached the user")
    func doesNotRetryMidStream() async throws {
        let counter = AttemptCounter()
        let base = ScriptedProvider(attempts: [
            .emitThenFail(["partial answer"], .serverError(status: 503, message: "dropped")),
            .succeed("a different answer"),
        ], counter: counter)

        var received: [AssistantStreamEvent] = []
        await #expect(throws: AssistantError.serverError(status: 503, message: "dropped")) {
            for try await event in RetryingProvider(wrapping: base, sleep: noSleep).stream(request) {
                received.append(event)
            }
        }
        // Retrying here would contradict text the user has already read.
        #expect(received == [.textDelta("partial answer")])
        #expect(await counter.total == 1)
    }

    @Test("honours the provider's Retry-After over the default backoff")
    func honoursRetryAfter() async throws {
        let counter = AttemptCounter()
        let recorded = SleepRecorder()
        let base = ScriptedProvider(attempts: [
            .fail(.rateLimited(retryAfter: 2)),
            .succeed("ok"),
        ], counter: counter)

        let provider = RetryingProvider(wrapping: base, sleep: { duration in
            await recorded.record(duration)
        })
        _ = try await collect(provider)
        #expect(await recorded.durations == [.milliseconds(2000)])
    }

    @Test("passes through provider metadata")
    func passesThroughMetadata() {
        let base = ScriptedProvider(attempts: [.succeed("x")], counter: AttemptCounter())
        let wrapped = RetryingProvider(wrapping: base)
        #expect(wrapped.identifier == base.identifier)
        #expect(wrapped.displayName == base.displayName)
    }
}

actor SleepRecorder {
    private(set) var durations: [Duration] = []
    func record(_ duration: Duration) { durations.append(duration) }
}
