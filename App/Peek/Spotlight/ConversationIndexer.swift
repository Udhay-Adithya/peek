import CoreSpotlight
import Foundation
import OSLog
import PeekCore
import UniformTypeIdentifiers

/// Publishes conversations to Spotlight so past answers are findable with
/// ⌘Space rather than only from inside Peek.
///
/// Indexing is the user's choice and reversible: turning it off purges
/// everything Peek has written, because leaving a copy of their conversations
/// in a system index after they asked for it to stop would be the wrong way
/// round.
@MainActor
final class ConversationIndexer {

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "spotlight")

    /// Groups Peek's items so they can be removed in one call.
    static let domainIdentifier = "com.udhayadithya.Peek.conversations"

    private let index: CSSearchableIndex
    private var isEnabled: Bool

    init(isEnabled: Bool, index: CSSearchableIndex = .default()) {
        self.isEnabled = isEnabled
        self.index = index
    }

    func setEnabled(_ enabled: Bool, store: ConversationStore) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        Task {
            if enabled {
                await reindexAll(from: store)
            } else {
                await purgeAll()
            }
        }
    }

    // MARK: - Writing

    func index(conversation: ConversationSummary, messages: [PersistedMessage]) async {
        guard isEnabled else { return }
        guard let content = SpotlightContent.item(title: conversation.title,
                                                  messages: messages,
                                                  sourceAppName: conversation.sourceAppName) else {
            return
        }

        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = content.title
        attributes.contentDescription = content.summary
        attributes.textContent = content.body
        attributes.contentCreationDate = conversation.createdAt
        attributes.contentModificationDate = conversation.updatedAt
        attributes.keywords = ["Peek", "conversation"]

        let item = CSSearchableItem(
            uniqueIdentifier: conversation.id.rawValue.uuidString,
            domainIdentifier: Self.domainIdentifier,
            attributeSet: attributes
        )

        do {
            try await index.indexSearchableItems([item])
        } catch {
            // Indexing is a convenience; its failure must not surface.
            Self.logger.error("indexing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func remove(_ id: ConversationID) async {
        // Runs even when indexing is switched off: a conversation deleted
        // after the setting changed must still leave no trace behind.
        do {
            try await index.deleteSearchableItems(withIdentifiers: [id.rawValue.uuidString])
        } catch {
            Self.logger.error("index removal failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func purgeAll() async {
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier])
            Self.logger.info("spotlight index purged")
        } catch {
            Self.logger.error("index purge failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Rebuilds the index from the store.
    ///
    /// Needed when the user switches indexing on: conversations that already
    /// exist are the ones they are most likely to search for.
    func reindexAll(from store: ConversationStore) async {
        guard isEnabled else { return }
        do {
            let conversations = try await store.recentConversations(limit: 500)
            for conversation in conversations {
                let messages = try await store.messages(in: conversation.id)
                await index(conversation: conversation, messages: messages)
            }
            Self.logger.info("reindexed \(conversations.count, privacy: .public) conversations")
        } catch {
            Self.logger.error("reindex failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Extracts a conversation id from a Spotlight activity.
    static func conversationID(from activity: NSUserActivity) -> ConversationID? {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let uuid = UUID(uuidString: identifier) else { return nil }
        return ConversationID(uuid)
    }
}
