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

    public init(id: UUID = UUID(), role: ChatMessage.Role, text: String, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
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
}

public enum ConversationStoreError: Error, Equatable, Sendable {
    case conversationNotFound(ConversationID)
}
