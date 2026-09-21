import Foundation

public struct ConversationID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct PersistedMessage: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var role: ChatMessage.Role
    public var text: String
    public var createdAt: Date
    /// Images sent with this turn. Persisted so reopening a conversation shows
    /// what was actually asked about, rather than a question with its subject
    /// silently missing.
    public var attachments: [ImageAttachment]
    /// The selection this turn was asked about, when there was one.
    ///
    /// Kept separate from `text` rather than folded into it: the transcript
    /// needs to show the question and its subject as distinct things, and the
    /// composed payload sent to the model is a third thing again.
    public var contextText: String?
    public var contextSourceApp: String?
    /// Token accounting for an assistant turn, where the provider reported it.
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(id: UUID = UUID(),
                role: ChatMessage.Role,
                text: String,
                createdAt: Date = .now,
                attachments: [ImageAttachment] = [],
                contextText: String? = nil,
                contextSourceApp: String? = nil,
                inputTokens: Int? = nil,
                outputTokens: Int? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.attachments = attachments
        self.contextText = contextText
        self.contextSourceApp = contextSourceApp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct ConversationSummary: Sendable, Identifiable, Equatable {
    public let id: ConversationID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messageCount: Int
    public var providerID: String
    public var modelID: String
    /// Which app the originating selection came from, where there was one.
    public var sourceAppName: String?

    public init(id: ConversationID, title: String, createdAt: Date, updatedAt: Date,
                messageCount: Int, providerID: String, modelID: String,
                sourceAppName: String? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.providerID = providerID
        self.modelID = modelID
        self.sourceAppName = sourceAppName
    }
}

/// Persistent conversation storage.
///
/// A protocol with plain value types crossing the boundary, for two concrete
/// reasons rather than architectural habit: SwiftData's `@Model` classes are
/// not `Sendable` and must not escape the actor that owns their context, and
/// keeping the persistence framework out of the UI means the storage engine
/// can be replaced without touching a view.
public protocol ConversationStore: Sendable {

    func createConversation(title: String,
                            providerID: String,
                            modelID: String,
                            sourceAppName: String?) async throws -> ConversationID

    func appendMessage(_ message: PersistedMessage, to id: ConversationID) async throws

    func updateTitle(_ title: String, for id: ConversationID) async throws

    func deleteConversation(_ id: ConversationID) async throws

    func recentConversations(limit: Int) async throws -> [ConversationSummary]

    func messages(in id: ConversationID) async throws -> [PersistedMessage]

    func search(_ query: String, limit: Int) async throws -> [ConversationSummary]

    /// The most recently updated conversation, if it was touched within
    /// `interval`. Backs "continue where I left off" without letting an
    /// unrelated conversation from yesterday absorb a new question.
    func mostRecentConversation(updatedWithin interval: TimeInterval) async throws -> ConversationSummary?

    /// Token usage aggregated over the last `days` days.
    ///
    /// Computed from stored turns rather than a running counter, so it stays
    /// correct when conversations are deleted and needs no separate bookkeeping
    /// to keep in sync.
    func usageStatistics(lastDays days: Int, calendar: Calendar) async throws -> UsageStatistics
}

public enum ConversationStoreError: Error, Equatable, Sendable {
    case conversationNotFound(ConversationID)
}
