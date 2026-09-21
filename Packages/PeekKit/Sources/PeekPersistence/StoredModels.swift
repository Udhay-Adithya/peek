import Foundation
import SwiftData
import PeekCore

/// SwiftData representation of a conversation.
///
/// Internal to this module on purpose: these are reference types tied to a
/// `ModelContext` and are not `Sendable`, so they must never reach the UI.
/// ``SwiftDataConversationStore`` converts them to value types at the boundary.
@Model
final class StoredConversation {

    /// The stable identity used by the rest of the app. Not SwiftData's
    /// `persistentModelID`, which is an implementation detail and changes
    /// across stores.
    #Unique<StoredConversation>([\.identifier])
    var identifier: UUID = UUID()

    var title: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var providerID: String = ""
    var modelID: String = ""
    var sourceAppName: String?

    /// Cascade: deleting a conversation must not orphan its messages.
    @Relationship(deleteRule: .cascade, inverse: \StoredMessage.conversation)
    var messages: [StoredMessage]? = []

    init(identifier: UUID = UUID(),
         title: String,
         createdAt: Date = .now,
         updatedAt: Date = .now,
         providerID: String,
         modelID: String,
         sourceAppName: String? = nil) {
        self.identifier = identifier
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerID = providerID
        self.modelID = modelID
        self.sourceAppName = sourceAppName
        self.messages = []
    }
}

@Model
final class StoredMessage {

    var identifier: UUID = UUID()
    /// Stored as its raw string so an unknown future role cannot fail to load
    /// the whole store.
    var roleRaw: String = ChatMessage.Role.user.rawValue
    var text: String = ""
    var createdAt: Date = Date.now
    var conversation: StoredConversation?

    @Relationship(deleteRule: .cascade, inverse: \StoredAttachment.message)
    var attachments: [StoredAttachment]? = []

    init(identifier: UUID = UUID(),
         role: ChatMessage.Role,
         text: String,
         createdAt: Date = .now) {
        self.identifier = identifier
        self.roleRaw = role.rawValue
        self.text = text
        self.createdAt = createdAt
    }

    var role: ChatMessage.Role {
        ChatMessage.Role(rawValue: roleRaw) ?? .assistant
    }
}

/// An image sent with a message.
///
/// The bytes use `.externalStorage`, so SwiftData spills them to files beside
/// the store instead of inflating the database with hundreds of kilobytes per
/// screenshot — and a conversation list query never has to read them.
@Model
final class StoredAttachment {

    var identifier: UUID = UUID()
    var mimeType: String = "image/jpeg"

    @Attribute(.externalStorage)
    var data: Data = Data()

    var message: StoredMessage?

    init(identifier: UUID = UUID(), mimeType: String, data: Data) {
        self.identifier = identifier
        self.mimeType = mimeType
        self.data = data
    }
}
