import Foundation
import PeekCore
import PeekProviders
@testable import Peek

/// A provider whose stream is scripted.
struct StubProvider: AssistantProvider {
    let identifier = ProviderIdentifier(rawValue: "stub")
    let displayName = "Stub"
    let models: [ModelDescriptor] = []

    var events: [AssistantStreamEvent] = []
    var failure: Error?
    /// Records what the session actually asked for.
    let recorder: RequestLog?

    func stream(_ request: AssistantRequest) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
        let events = self.events
        let failure = self.failure
        let recorder = self.recorder
        return AsyncThrowingStream { continuation in
            Task {
                await recorder?.record(request)
                for event in events { continuation.yield(event) }
                if let failure { continuation.finish(throwing: failure) }
                else { continuation.finish() }
            }
        }
    }
}

actor RequestLog {
    private(set) var requests: [AssistantRequest] = []
    func record(_ request: AssistantRequest) { requests.append(request) }
    var count: Int { requests.count }
    var last: AssistantRequest? { requests.last }
}

@MainActor
final class StubEngine: ProviderResolving {
    var selectedModelID = "stub-model"
    var hasCredentials = true
    var provider: AssistantProvider

    init(provider: AssistantProvider) {
        self.provider = provider
    }

    func currentProvider() -> AssistantProvider { provider }
}

/// In-memory ``ConversationStore`` that also records calls.
actor RecordingStore: ConversationStore {
    private var conversations: [ConversationID: ConversationSummary] = [:]
    private var messages: [ConversationID: [PersistedMessage]] = [:]
    private(set) var createCount = 0

    func createConversation(title: String, providerID: String,
                            modelID: String, sourceAppName: String?) throws -> ConversationID {
        createCount += 1
        let id = ConversationID()
        conversations[id] = ConversationSummary(
            id: id, title: title, createdAt: .now, updatedAt: .now,
            messageCount: 0, providerID: providerID, modelID: modelID,
            sourceAppName: sourceAppName
        )
        messages[id] = []
        return id
    }

    func appendMessage(_ message: PersistedMessage, to id: ConversationID) throws {
        guard conversations[id] != nil else { throw ConversationStoreError.conversationNotFound(id) }
        messages[id, default: []].append(message)
        conversations[id]?.messageCount = messages[id]?.count ?? 0
        conversations[id]?.updatedAt = message.createdAt
    }

    func updateTitle(_ title: String, for id: ConversationID) throws {
        conversations[id]?.title = title
    }

    func deleteConversation(_ id: ConversationID) throws {
        conversations[id] = nil
        messages[id] = nil
    }

    func recentConversations(limit: Int) throws -> [ConversationSummary] {
        Array(conversations.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    func messages(in id: ConversationID) throws -> [PersistedMessage] {
        messages[id] ?? []
    }

    func search(_ query: String, limit: Int) throws -> [ConversationSummary] {
        try recentConversations(limit: limit).filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    func mostRecentConversation(updatedWithin interval: TimeInterval) throws -> ConversationSummary? {
        try recentConversations(limit: 1).first {
            Date.now.timeIntervalSince($0.updatedAt) <= interval
        }
    }

    func usageStatistics(lastDays days: Int, calendar: Calendar) throws -> UsageStatistics {
        let turns = messages.values.flatMap { $0 }.filter { $0.outputTokens != nil }
        return UsageStatistics(
            totalInputTokens: turns.reduce(0) { $0 + ($1.inputTokens ?? 0) },
            totalOutputTokens: turns.reduce(0) { $0 + ($1.outputTokens ?? 0) },
            assistantTurns: turns.count,
            conversationCount: conversations.count,
            days: [],
            models: []
        )
    }

    /// Seeds a conversation that looks recent and came from `app`.
    func seedRecent(title: String, sourceAppName: String?) throws -> ConversationID {
        let id = try createConversation(title: title, providerID: "stub",
                                        modelID: "stub-model", sourceAppName: sourceAppName)
        try appendMessage(PersistedMessage(role: .user, text: "earlier question"), to: id)
        try appendMessage(PersistedMessage(role: .assistant, text: "earlier answer"), to: id)
        return id
    }
}

struct StubSelectionCapture: SelectionCapturing {
    let outcome: SelectionOutcome
    func capture(frontApp: FrontmostApp?, primaryScreenMaxY: CGFloat) async -> SelectionOutcome {
        outcome
    }
}

@MainActor
final class StubClipboardCapture: ClipboardCapturing {
    var outcome: SelectionOutcome
    private(set) var callCount = 0

    init(outcome: SelectionOutcome) {
        self.outcome = outcome
    }

    func capture(frontApp: FrontmostApp?) async -> SelectionOutcome {
        callCount += 1
        return outcome
    }
}

extension FrontmostApp {
    static func stub(name: String = "Notes", bundleID: String = "com.apple.Notes") -> FrontmostApp {
        FrontmostApp(name: name, bundleID: bundleID, processID: 1234)
    }
}

/// Isolated defaults, so tests never touch the real preferences.
@MainActor
func makeTestSettings() -> AppSettings {
    let suite = UserDefaults(suiteName: "com.udhayadithya.Peek.tests.\(UUID().uuidString)")!
    return AppSettings(defaults: suite)
}
