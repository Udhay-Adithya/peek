import Foundation
import Observation
import OSLog
import PeekCore
import PeekPersistence
import PeekProviders

/// One live conversation, rendered progressively.
@MainActor
@Observable
final class AssistantSession {

    struct DisplayMessage: Identifiable, Sendable {
        let id = UUID()
        let role: ChatMessage.Role
        var text: String
        /// Number of images sent with this turn, for the transcript badge.
        var attachmentCount: Int = 0
        var isStreaming: Bool = false
        var failure: String?
        var isRetryable: Bool = false
        /// Reported by the provider, where it does. Shown so cost is visible
        /// rather than something the user discovers on a bill.
        var usage: TokenUsage?
    }

    private(set) var messages: [DisplayMessage] = []
    private(set) var isStreaming = false

    /// Notifies the menu bar so the status item can reflect in-flight work.
    var onStreamingChange: ((Bool) -> Void)?

    private let engine: AssistantEngine
    private let store: ConversationStore
    private var streamTask: Task<Void, Never>?

    /// The conversation being written to. Created lazily on first send, so
    /// merely opening the panel does not litter the history with empty rows.
    private(set) var conversationID: ConversationID?

    /// Serialises persistence so two quick sends cannot each create their own
    /// conversation for what the user experiences as one thread.
    private var persistenceChain: Task<Void, Never>?
    /// Retained so a failed turn can be retried without recomposing context.
    private var lastRequest: AssistantRequest?

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "assistant")

    init(engine: AssistantEngine, store: ConversationStore) {
        self.engine = engine
        self.store = store
    }

    var isEmpty: Bool { messages.isEmpty }

    // MARK: - Sending

    func send(prompt: String,
              context: SelectionContext?,
              attachments: [ImageAttachment] = []) {
        guard PromptComposer.canSend(prompt: prompt, context: context, attachments: attachments) else { return }

        let userMessage = PromptComposer.userMessage(prompt: prompt,
                                                     context: context,
                                                     attachments: attachments)

        // History must be snapshotted BEFORE the new turn is shown, or the
        // user's message is sent twice: once from the transcript and once as
        // the freshly composed payload.
        var history = conversationHistory()
        history.append(userMessage)

        // Show the user's own turn as they typed it, not the composed payload
        // with the fenced context block — that is plumbing, not their message.
        let visible = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        messages.append(DisplayMessage(
            role: .user,
            text: visible.isEmpty ? PromptComposer.implicitPrompt : visible,
            attachmentCount: attachments.count
        ))

        let request = AssistantRequest(
            model: engine.selectedModelID,
            systemInstruction: PromptComposer.defaultSystemInstruction,
            messages: history
        )
        lastRequest = request

        persist(PersistedMessage(role: .user, text: messages.last?.text ?? visible),
                title: PromptComposer.title(fromPrompt: prompt, context: context),
                sourceAppName: context?.sourceAppName)

        startStream(request)
    }

    /// Replaces the transcript with a stored conversation.
    func load(_ id: ConversationID) async {
        cancel()
        do {
            let stored = try await store.messages(in: id)
            messages = stored.map {
                DisplayMessage(role: $0.role, text: $0.text)
            }
            conversationID = id
            lastRequest = nil
        } catch {
            Self.logger.error("failed to load conversation")
        }
    }

    func retry() {
        guard let lastRequest, !isStreaming else { return }
        // Drop the failed assistant turn before retrying so the transcript does
        // not accumulate errors.
        if let last = messages.last, last.role == .assistant, last.failure != nil {
            messages.removeLast()
        }
        startStream(lastRequest)
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        finishStreaming()
        if let index = messages.indices.last, messages[index].isStreaming {
            messages[index].isStreaming = false
            if messages[index].text.isEmpty {
                messages[index].failure = "Cancelled."
                messages[index].isRetryable = true
            }
        }
    }

    func reset() {
        cancel()
        messages.removeAll()
        lastRequest = nil
        // A fresh conversation, not a continuation of the stored one.
        conversationID = nil
    }

    // MARK: - Persistence

    /// Appends to the store without blocking the UI.
    ///
    /// Chained rather than fired in parallel: the first call may still be
    /// creating the conversation when the second arrives, and unsynchronised
    /// creation produces two conversations for one thread.
    private func persist(_ message: PersistedMessage, title: String, sourceAppName: String?) {
        let previous = persistenceChain
        let store = self.store
        let providerID = engine.currentProvider().identifier.rawValue
        let modelID = engine.selectedModelID

        persistenceChain = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            do {
                let id: ConversationID
                if let existing = self.conversationID {
                    id = existing
                } else {
                    id = try await store.createConversation(title: title,
                                                            providerID: providerID,
                                                            modelID: modelID,
                                                            sourceAppName: sourceAppName)
                    self.conversationID = id
                }
                try await store.appendMessage(message, to: id)
            } catch {
                // Persistence must never break a live conversation.
                Self.logger.error("failed to persist message")
            }
        }
    }

    // MARK: - Streaming

    private func startStream(_ request: AssistantRequest) {
        streamTask?.cancel()

        // Tracked by identity, not array index: `reset()` or a new turn can
        // reshape the transcript while a stream is still landing, and an index
        // would then silently write into the wrong message.
        let placeholder = DisplayMessage(role: .assistant, text: "", isStreaming: true)
        let streamID = placeholder.id
        messages.append(placeholder)

        isStreaming = true
        onStreamingChange?(true)

        let provider = engine.currentProvider()

        streamTask = Task { [weak self] in
            var accumulator = StreamAccumulator()
            do {
                for try await event in provider.stream(request) {
                    try Task.checkCancellation()
                    try accumulator.apply(event)

                    // Only text moves the UI; reasoning and usage are folded
                    // into the accumulator without a redraw per token. Both
                    // shapes matter: cloud providers stream deltas, the
                    // on-device model streams snapshots.
                    switch event {
                    case .textDelta, .textSnapshot:
                        self?.updateStreamingText(id: streamID, to: accumulator.text)
                    default:
                        break
                    }
                }
                self?.completeStream(id: streamID, with: accumulator)
            } catch is CancellationError {
                // cancel() has already tidied the transcript.
            } catch {
                self?.failStream(id: streamID, with: error)
            }
        }
    }

    private func index(of id: UUID) -> Int? {
        messages.firstIndex { $0.id == id }
    }

    private func updateStreamingText(id: UUID, to text: String) {
        guard let index = index(of: id) else { return }
        messages[index].text = text
    }

    private func completeStream(id: UUID, with accumulator: StreamAccumulator) {
        guard let index = index(of: id) else { return }
        messages[index].text = accumulator.text
        messages[index].isStreaming = false

        if accumulator.text.isEmpty {
            switch accumulator.finishReason {
            case .contentFilter:
                messages[index].failure = "The provider blocked this response."
            case .maxTokens:
                messages[index].failure = "Response hit the token limit before producing text."
            default:
                messages[index].failure = "The provider returned an empty response."
                messages[index].isRetryable = true
            }
        }

        if let usage = accumulator.usage {
            messages[index].usage = usage
            Self.logger.debug("turn complete in=\(usage.inputTokens, privacy: .public) out=\(usage.outputTokens, privacy: .public)")
        }

        if !accumulator.text.isEmpty {
            persist(PersistedMessage(role: .assistant, text: accumulator.text),
                    title: "Conversation", sourceAppName: nil)
        }
        finishStreaming()
    }

    private func failStream(id: UUID, with error: Error) {
        guard let index = index(of: id) else { return }
        let assistantError = error as? AssistantError
        messages[index].isStreaming = false
        messages[index].failure = assistantError?.errorDescription ?? error.localizedDescription
        messages[index].isRetryable = assistantError?.isRetryable ?? true

        // Error *kind* only. The request contents are user data.
        Self.logger.error("turn failed kind=\(String(describing: assistantError ?? .network("unknown")), privacy: .public)")
        finishStreaming()
    }

    private func finishStreaming() {
        isStreaming = false
        onStreamingChange?(false)
    }

    /// Prior turns, excluding failed and in-flight ones.
    private func conversationHistory() -> [ChatMessage] {
        messages.compactMap { message in
            guard message.failure == nil, !message.isStreaming, !message.text.isEmpty else { return nil }
            return ChatMessage(role: message.role, text: message.text)
        }
    }
}
