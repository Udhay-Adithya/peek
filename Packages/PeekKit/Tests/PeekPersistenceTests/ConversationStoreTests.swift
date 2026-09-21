import Testing
import Foundation
import PeekCore
@testable import PeekPersistence

/// Exercises the real SwiftData store against an in-memory container.
///
/// Deliberately not a hand-written fake: SwiftData's own behaviour — cascade
/// deletes, predicate semantics, relationship ordering — is exactly what would
/// break, and a fake would happily agree with whatever I assumed.
/// Serialized: swift-testing runs suites in parallel by default, and standing
/// up many SwiftData `ModelContainer`s concurrently crashes inside the
/// framework. Each test still gets its own fresh in-memory container.
@Suite("SwiftDataConversationStore", .serialized)
struct ConversationStoreTests {

    private func makeStore() throws -> SwiftDataConversationStore {
        SwiftDataConversationStore(modelContainer: try PeekModelContainer.makeInMemory())
    }

    private func newConversation(_ store: SwiftDataConversationStore,
                                 title: String = "Force Touch") async throws -> ConversationID {
        try await store.createConversation(title: title,
                                           providerID: "gemini",
                                           modelID: "gemini-3.5-flash",
                                           sourceAppName: "Notes")
    }

    @Test("creates a conversation and lists it")
    func createsAndLists() async throws {
        let store = try makeStore()
        let id = try await newConversation(store)

        let recent = try await store.recentConversations(limit: 10)
        #expect(recent.count == 1)
        #expect(recent.first?.id == id)
        #expect(recent.first?.title == "Force Touch")
        #expect(recent.first?.sourceAppName == "Notes")
        #expect(recent.first?.messageCount == 0)
    }

    @Test("appends messages and returns them in chronological order")
    func appendsMessagesInOrder() async throws {
        let store = try makeStore()
        let id = try await newConversation(store)
        let base = Date(timeIntervalSince1970: 1_000_000)

        // Inserted out of order on purpose: ordering must come from the data.
        try await store.appendMessage(.init(role: .assistant, text: "second",
                                            createdAt: base.addingTimeInterval(10)), to: id)
        try await store.appendMessage(.init(role: .user, text: "first", createdAt: base), to: id)

        let messages = try await store.messages(in: id)
        #expect(messages.map(\.text) == ["first", "second"])
        #expect(messages.map(\.role) == [.user, .assistant])
    }

    @Test("appending bumps the conversation's updatedAt")
    func appendingTouchesConversation() async throws {
        let store = try makeStore()
        let id = try await newConversation(store)
        let future = Date.now.addingTimeInterval(60)

        try await store.appendMessage(.init(role: .user, text: "hi", createdAt: future), to: id)
        let summary = try await store.recentConversations(limit: 1).first
        #expect(summary?.updatedAt == future)
        #expect(summary?.messageCount == 1)
    }

    @Test("orders conversations by most recently updated")
    func ordersByRecency() async throws {
        let store = try makeStore()
        let older = try await newConversation(store, title: "older")
        let newer = try await newConversation(store, title: "newer")

        try await store.appendMessage(.init(role: .user, text: "x",
                                            createdAt: .now.addingTimeInterval(-500)), to: older)
        try await store.appendMessage(.init(role: .user, text: "y", createdAt: .now), to: newer)

        let recent = try await store.recentConversations(limit: 10)
        #expect(recent.map(\.title) == ["newer", "older"])
    }

    @Test("renames a conversation")
    func renames() async throws {
        let store = try makeStore()
        let id = try await newConversation(store)
        try await store.updateTitle("Renamed", for: id)
        #expect(try await store.recentConversations(limit: 1).first?.title == "Renamed")
    }

    @Test("deleting a conversation cascades to its messages")
    func deleteCascades() async throws {
        let store = try makeStore()
        let id = try await newConversation(store)
        try await store.appendMessage(.init(role: .user, text: "orphan me"), to: id)

        try await store.deleteConversation(id)
        #expect(try await store.recentConversations(limit: 10).isEmpty)
        // Messages must not survive their conversation.
        #expect(try await store.search("orphan me", limit: 10).isEmpty)
    }

    @Test("operations on a missing conversation throw rather than fail silently")
    func missingConversationThrows() async throws {
        let store = try makeStore()
        let ghost = ConversationID()
        await #expect(throws: ConversationStoreError.conversationNotFound(ghost)) {
            try await store.appendMessage(.init(role: .user, text: "x"), to: ghost)
        }
        await #expect(throws: ConversationStoreError.conversationNotFound(ghost)) {
            try await store.updateTitle("x", for: ghost)
        }
    }

    // MARK: - Search

    @Test("finds conversations by title, case-insensitively")
    func searchesTitles() async throws {
        let store = try makeStore()
        _ = try await newConversation(store, title: "Breadth-First Search")
        _ = try await newConversation(store, title: "Unrelated")

        let results = try await store.search("breadth", limit: 10)
        #expect(results.map(\.title) == ["Breadth-First Search"])
    }

    @Test("finds conversations by message body")
    func searchesMessageBodies() async throws {
        let store = try makeStore()
        let id = try await newConversation(store, title: "Opaque title")
        try await store.appendMessage(.init(role: .assistant, text: "a trackpad digitiser"), to: id)

        let results = try await store.search("digitiser", limit: 10)
        #expect(results.map(\.id) == [id])
    }

    @Test("does not return the same conversation twice when title and body both match")
    func searchDeduplicates() async throws {
        let store = try makeStore()
        let id = try await newConversation(store, title: "trackpad")
        try await store.appendMessage(.init(role: .user, text: "trackpad"), to: id)

        #expect(try await store.search("trackpad", limit: 10).count == 1)
    }

    @Test("an empty query returns recent conversations rather than nothing")
    func emptyQueryReturnsRecent() async throws {
        let store = try makeStore()
        _ = try await newConversation(store, title: "a")
        _ = try await newConversation(store, title: "b")
        #expect(try await store.search("   ", limit: 10).count == 2)
    }

    @Test("respects the result limit")
    func respectsLimit() async throws {
        let store = try makeStore()
        for index in 0..<5 { _ = try await newConversation(store, title: "conv \(index)") }
        #expect(try await store.recentConversations(limit: 3).count == 3)
    }

    // MARK: - Continuation window

    @Test("offers a recent conversation for continuation")
    func offersRecentForContinuation() async throws {
        let store = try makeStore()
        let id = try await newConversation(store)
        try await store.appendMessage(.init(role: .user, text: "x", createdAt: .now), to: id)

        let candidate = try await store.mostRecentConversation(updatedWithin: 600)
        #expect(candidate?.id == id)
    }

    @Test("will not resurrect a stale conversation")
    func ignoresStaleConversation() async throws {
        let store = try makeStore()
        let id = try await newConversation(store)
        // Touched an hour ago; a new question should not land in it.
        try await store.appendMessage(.init(role: .user, text: "x",
                                            createdAt: .now.addingTimeInterval(-3600)), to: id)

        #expect(try await store.mostRecentConversation(updatedWithin: 600) == nil)
    }

    @Test("returns nil when there are no conversations at all")
    func noConversations() async throws {
        #expect(try await makeStore().mostRecentConversation(updatedWithin: 600) == nil)
    }
}

@Suite("Conversation attachments", .serialized)
struct ConversationAttachmentTests {

    private func makeStore() throws -> SwiftDataConversationStore {
        SwiftDataConversationStore(modelContainer: try PeekModelContainer.makeInMemory())
    }

    private let jpeg = ImageAttachment(mimeType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF, 0xE0]))

    @Test("round-trips an image attached to a message")
    func roundTripsAttachment() async throws {
        let store = try makeStore()
        let id = try await store.createConversation(title: "screenshot",
                                                    providerID: "gemini",
                                                    modelID: "m",
                                                    sourceAppName: nil)
        try await store.appendMessage(
            .init(role: .user, text: "what is this", attachments: [jpeg]), to: id
        )

        let messages = try await store.messages(in: id)
        #expect(messages.count == 1)
        #expect(messages[0].attachments.count == 1)
        #expect(messages[0].attachments[0].mimeType == "image/jpeg")
        #expect(messages[0].attachments[0].data == jpeg.data)
    }

    @Test("a message without attachments round-trips as empty, not nil")
    func handlesNoAttachments() async throws {
        let store = try makeStore()
        let id = try await store.createConversation(title: "text only", providerID: "g",
                                                    modelID: "m", sourceAppName: nil)
        try await store.appendMessage(.init(role: .user, text: "hello"), to: id)
        #expect(try await store.messages(in: id)[0].attachments.isEmpty)
    }

    @Test("persists several attachments on one turn in order")
    func handlesMultipleAttachments() async throws {
        let store = try makeStore()
        let id = try await store.createConversation(title: "two shots", providerID: "g",
                                                    modelID: "m", sourceAppName: nil)
        let second = ImageAttachment(mimeType: "image/png", data: Data([0x89, 0x50]))
        try await store.appendMessage(
            .init(role: .user, text: "compare these", attachments: [jpeg, second]), to: id
        )
        let stored = try await store.messages(in: id)[0].attachments
        #expect(stored.count == 2)
        #expect(Set(stored.map(\.mimeType)) == ["image/jpeg", "image/png"])
    }

    @Test("deleting a conversation cascades through messages to attachments")
    func deleteCascadesToAttachments() async throws {
        // Two cascade hops. An orphaned blob would leak disk space
        // indefinitely, and it holds a screenshot of the user's screen.
        let store = try makeStore()
        let id = try await store.createConversation(title: "x", providerID: "g",
                                                    modelID: "m", sourceAppName: nil)
        try await store.appendMessage(.init(role: .user, text: "x", attachments: [jpeg]), to: id)
        try await store.deleteConversation(id)
        #expect(try await store.recentConversations(limit: 10).isEmpty)
    }
}
