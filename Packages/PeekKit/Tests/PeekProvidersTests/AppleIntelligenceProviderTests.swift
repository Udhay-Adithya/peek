import Testing
import Foundation
import PeekCore
@testable import PeekProviders

@Suite("AppleIntelligenceProvider")
struct AppleIntelligenceProviderTests {

    private func textRequest(_ text: String = "what is this") -> AssistantRequest {
        AssistantRequest(model: "system", messages: [ChatMessage(role: .user, text: text)])
    }

    /// Always-available provider driven by scripted snapshots, so these tests
    /// pass on a Mac without Apple Intelligence enabled.
    private func provider(snapshots: [String],
                          failWith error: Error? = nil) -> AppleIntelligenceProvider {
        AppleIntelligenceProvider(
            snapshots: { _ in
                AsyncThrowingStream { continuation in
                    for snapshot in snapshots { continuation.yield(snapshot) }
                    if let error { continuation.finish(throwing: error) }
                    else { continuation.finish() }
                }
            },
            availability: { nil }
        )
    }

    private func collect(_ provider: AppleIntelligenceProvider,
                         _ request: AssistantRequest) async throws -> [AssistantStreamEvent] {
        var events: [AssistantStreamEvent] = []
        for try await event in provider.stream(request) { events.append(event) }
        return events
    }

    @Test("emits snapshots rather than deltas")
    func emitsSnapshots() async throws {
        let events = try await collect(provider(snapshots: ["Force", "Force Touch"]), textRequest())

        // Snapshots, not deltas: the framework reports cumulative text.
        #expect(events.contains(.textSnapshot("Force")))
        #expect(events.contains(.textSnapshot("Force Touch")))

        var acc = StreamAccumulator()
        for event in events { try acc.apply(event) }
        #expect(acc.text == "Force Touch")
        #expect(acc.finishReason == .stop)
    }

    @Test("a revised snapshot does not corrupt the assembled text")
    func handlesRevision() async throws {
        let events = try await collect(provider(snapshots: ["The dog sat", "The cat sat"]), textRequest())
        var acc = StreamAccumulator()
        for event in events { try acc.apply(event) }
        // Diffing into deltas would have produced a mangled string here.
        #expect(acc.text == "The cat sat")
    }

    @Test("reports no usage, because the framework provides none")
    func reportsNoUsage() async throws {
        let events = try await collect(provider(snapshots: ["hi"]), textRequest())
        #expect(events.contains { if case .usage = $0 { return true }; return false } == false)

        var acc = StreamAccumulator()
        for event in events { try acc.apply(event) }
        // Absent, not zero — zero would imply a free request was measured.
        #expect(acc.usage == nil)
    }

    @Test("needs no API key")
    func needsNoKey() {
        #expect(provider(snapshots: []).requiresAPIKey == false)
        // Contrast with the cloud provider, which does.
        #expect(GeminiProvider(apiKey: { "k" }).requiresAPIKey)
    }

    @Test("refuses a request carrying an image instead of dropping it")
    func refusesImages() async throws {
        let request = AssistantRequest(model: "system", messages: [
            ChatMessage(role: .user, parts: [
                .text("what is this"),
                .image(ImageAttachment(mimeType: "image/jpeg", data: Data([0xFF, 0xD8]))),
            ]),
        ])

        var thrown: AssistantError?
        do {
            _ = try await collect(provider(snapshots: ["ignored"]), request)
        } catch let error as AssistantError {
            thrown = error
        }
        // Silently discarding the screenshot would answer the wrong question.
        guard case .unsupportedContent = thrown else {
            Issue.record("expected unsupportedContent, got \(String(describing: thrown))")
            return
        }
    }

    @Test("surfaces unavailability before attempting to stream")
    func surfacesUnavailability() async throws {
        let unavailable = AppleIntelligenceProvider(
            snapshots: { _ in
                AsyncThrowingStream { $0.finish() }
            },
            availability: { .providerUnavailable("Apple Intelligence is turned off.") }
        )
        await #expect(throws: AssistantError.providerUnavailable("Apple Intelligence is turned off.")) {
            _ = try await collect(unavailable, textRequest())
        }
    }

    @Test("an empty response still terminates cleanly")
    func emptyResponseTerminates() async throws {
        let events = try await collect(provider(snapshots: []), textRequest())
        #expect(events == [.responseStarted(id: nil), .finished(.stop)])
    }

    // MARK: - Prompt rendering

    @Test("a single turn is sent as the bare prompt")
    func singleTurnPrompt() {
        let rendered = AppleIntelligenceProvider.renderPrompt(textRequest("define obtund"))
        #expect(rendered == "define obtund")
    }

    @Test("multi-turn history is flattened with speaker labels")
    func multiTurnPrompt() {
        let request = AssistantRequest(model: "system", messages: [
            ChatMessage(role: .user, text: "what is BFS"),
            ChatMessage(role: .assistant, text: "a traversal algorithm"),
            ChatMessage(role: .user, text: "and DFS?"),
        ])
        let rendered = AppleIntelligenceProvider.renderPrompt(request)
        #expect(rendered.contains("User: what is BFS"))
        #expect(rendered.contains("Assistant: a traversal algorithm"))
        // The latest turn is the actual instruction, not part of the history.
        #expect(rendered.hasSuffix("and DFS?"))
        #expect(rendered.contains("Assistant: and DFS?") == false)
    }

    @Test("an empty conversation renders as an empty prompt")
    func emptyPrompt() {
        let request = AssistantRequest(model: "system", messages: [])
        #expect(AppleIntelligenceProvider.renderPrompt(request).isEmpty)
    }
}
