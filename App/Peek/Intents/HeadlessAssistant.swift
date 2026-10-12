import Foundation
import PeekCore
import PeekPersistence
import PeekProviders

/// Answers a question without any UI.
///
/// The conversation UI accumulates turns and renders them progressively; an
/// automation wants one string back. Separating the two keeps the intent from
/// depending on a panel that will not be on screen, and makes the path
/// testable without one.
@MainActor
struct HeadlessAssistant {

    enum Failure: LocalizedError, Equatable {
        case notConfigured
        case emptyQuestion
        case emptyAnswer

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Peek is not ready yet. Open it once and try again."
            case .emptyQuestion: return "There was no question to ask."
            case .emptyAnswer:   return "The model returned nothing."
            }
        }
    }

    let engine: any ProviderResolving
    /// Optional: a question asked from Shortcuts is still a conversation, and
    /// belongs in history alongside the rest.
    let store: ConversationStore?

    init(engine: any ProviderResolving, store: ConversationStore? = nil) {
        self.engine = engine
        self.store = store
    }

    func answer(_ question: String) async throws -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyQuestion }

        let request = AssistantRequest(
            model: engine.selectedModelID,
            systemInstruction: PromptComposer.defaultSystemInstruction,
            messages: [ChatMessage(role: .user, text: trimmed)]
        )

        var accumulator = StreamAccumulator()
        for try await event in engine.currentProvider().stream(request) {
            try accumulator.apply(event)
        }

        let answer = accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw Failure.emptyAnswer }

        await persist(question: trimmed, answer: answer, usage: accumulator.usage)
        return answer
    }

    /// Recorded on a best-effort basis: an automation that got its answer
    /// should not fail because history could not be written.
    private func persist(question: String, answer: String, usage: TokenUsage?) async {
        guard let store else { return }
        do {
            let id = try await store.createConversation(
                title: PromptComposer.title(fromPrompt: question, context: nil),
                providerID: engine.currentProvider().identifier.rawValue,
                modelID: engine.selectedModelID,
                sourceAppName: "Shortcuts"
            )
            try await store.appendMessage(PersistedMessage(role: .user, text: question), to: id)
            try await store.appendMessage(
                PersistedMessage(role: .assistant,
                                 text: answer,
                                 inputTokens: usage?.inputTokens,
                                 outputTokens: usage?.outputTokens),
                to: id
            )
        } catch {
            // Intentionally silent.
        }
    }
}
