import Foundation
import Observation
import OSLog
import PeekCore
import PeekPersistence

/// Backs the conversation history list.
@MainActor
@Observable
final class HistoryViewModel {

    private(set) var conversations: [ConversationSummary] = []
    private(set) var isLoading = false
    var query: String = "" {
        didSet { guard query != oldValue else { return }; scheduleSearch() }
    }

    private let store: ConversationStore
    private var searchTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "history")
    private static let pageSize = 50

    init(store: ConversationStore) {
        self.store = store
    }

    func refresh() {
        scheduleSearch(debounce: false)
    }

    /// Debounced so typing in the search field does not issue a query per
    /// keystroke against a growing store.
    private func scheduleSearch(debounce: Bool = true) {
        searchTask?.cancel()
        let query = self.query
        let store = self.store
        isLoading = true

        searchTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            do {
                let results = query.isEmpty
                    ? try await store.recentConversations(limit: Self.pageSize)
                    : try await store.search(query, limit: Self.pageSize)
                guard !Task.isCancelled else { return }
                self?.conversations = results
            } catch {
                Self.logger.error("history query failed")
            }
            self?.isLoading = false
        }
    }

    func delete(_ id: ConversationID) {
        let store = self.store
        // Optimistic removal: the list should not lag behind the click.
        conversations.removeAll { $0.id == id }
        Task {
            do { try await store.deleteConversation(id) }
            catch { Self.logger.error("delete failed") }
        }
    }

    func rename(_ id: ConversationID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let store = self.store
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations[index].title = trimmed
        }
        Task {
            do { try await store.updateTitle(trimmed, for: id) }
            catch { Self.logger.error("rename failed") }
        }
    }
}
