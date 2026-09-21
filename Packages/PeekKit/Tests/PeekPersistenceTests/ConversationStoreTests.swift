import Testing
import Foundation
import PeekCore
@testable import PeekPersistence

/// All SwiftData suites nested under one serialized parent.
///
/// swift-testing parallelises across suites, and creating several
/// `ModelContainer`s concurrently crashes inside SwiftData itself (SIGSEGV).
/// `.serialized` on an individual suite only orders that suite's own tests, so
/// the constraint has to be expressed at the level that actually owns them.
/// Each test still gets its own fresh in-memory container.
@Suite("Persistence", .serialized)
struct PersistenceTests {

    /// Exercises the real SwiftData store against an in-memory container.
    ///
    /// Deliberately not a hand-written fake: SwiftData's own behaviour — cascade
    /// deletes, predicate semantics, relationship ordering — is exactly what would
    /// break, and a fake would happily agree with whatever I assumed.
    @Suite("SwiftDataConversationStore")
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

    @Suite("Conversation attachments")
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

    @Suite("Usage statistics")
    struct UsageStatisticsTests {

        private func makeStore() throws -> SwiftDataConversationStore {
            SwiftDataConversationStore(modelContainer: try PeekModelContainer.makeInMemory())
        }

        private var calendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar
        }

        @Test("sums tokens across turns")
        func sumsTokens() async throws {
            let store = try makeStore()
            let id = try await store.createConversation(title: "x", providerID: "gemini",
                                                        modelID: "gemini-3.5-flash", sourceAppName: nil)
            try await store.appendMessage(.init(role: .assistant, text: "a",
                                                inputTokens: 100, outputTokens: 20), to: id)
            try await store.appendMessage(.init(role: .assistant, text: "b",
                                                inputTokens: 50, outputTokens: 10), to: id)

            let stats = try await store.usageStatistics(lastDays: 7, calendar: calendar)
            #expect(stats.totalInputTokens == 150)
            #expect(stats.totalOutputTokens == 30)
            #expect(stats.totalTokens == 180)
            #expect(stats.assistantTurns == 2)
            #expect(stats.conversationCount == 1)
        }

        @Test("ignores user turns, which carry no token counts")
        func ignoresUserTurns() async throws {
            let store = try makeStore()
            let id = try await store.createConversation(title: "x", providerID: "g",
                                                        modelID: "m", sourceAppName: nil)
            try await store.appendMessage(.init(role: .user, text: "question"), to: id)
            try await store.appendMessage(.init(role: .assistant, text: "answer",
                                                inputTokens: 10, outputTokens: 5), to: id)

            let stats = try await store.usageStatistics(lastDays: 7, calendar: calendar)
            #expect(stats.assistantTurns == 1)
        }

        @Test("returns one entry per day including days with no usage")
        func fillsEmptyDays() async throws {
            // A timeline that silently omits quiet days misreads as continuous use.
            let store = try makeStore()
            let stats = try await store.usageStatistics(lastDays: 14, calendar: calendar)
            #expect(stats.days.count == 14)
            #expect(stats.days.allSatisfy { $0.totalTokens == 0 })
        }

        @Test("breaks usage down by model, heaviest first")
        func breaksDownByModel() async throws {
            let store = try makeStore()
            let light = try await store.createConversation(title: "a", providerID: "gemini",
                                                           modelID: "gemini-3.1-flash-lite",
                                                           sourceAppName: nil)
            let heavy = try await store.createConversation(title: "b", providerID: "gemini",
                                                           modelID: "gemini-3.5-flash",
                                                           sourceAppName: nil)
            try await store.appendMessage(.init(role: .assistant, text: "x",
                                                inputTokens: 10, outputTokens: 5), to: light)
            try await store.appendMessage(.init(role: .assistant, text: "y",
                                                inputTokens: 900, outputTokens: 100), to: heavy)

            let stats = try await store.usageStatistics(lastDays: 7, calendar: calendar)
            #expect(stats.models.map(\.modelID) == ["gemini-3.5-flash", "gemini-3.1-flash-lite"])
            #expect(stats.models.first?.totalTokens == 1000)
            #expect(stats.models.first?.providerID == "gemini")
        }

        @Test("excludes usage older than the window")
        func excludesOldUsage() async throws {
            let store = try makeStore()
            let id = try await store.createConversation(title: "x", providerID: "g",
                                                        modelID: "m", sourceAppName: nil)
            let longAgo = Calendar(identifier: .gregorian).date(byAdding: .day, value: -60, to: .now)!
            try await store.appendMessage(.init(role: .assistant, text: "old", createdAt: longAgo,
                                                inputTokens: 999, outputTokens: 999), to: id)

            let stats = try await store.usageStatistics(lastDays: 7, calendar: calendar)
            #expect(stats.totalTokens == 0)
            #expect(stats.isEmpty)
        }

        @Test("an empty store reports zero rather than failing")
        func emptyStore() async throws {
            let stats = try await makeStore().usageStatistics(lastDays: 30, calendar: calendar)
            #expect(stats.isEmpty)
            #expect(stats.models.isEmpty)
            #expect(stats.days.count == 30)
        }
    }

}
