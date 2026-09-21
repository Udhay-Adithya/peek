import Foundation
import SwiftData
import PeekCore

/// SwiftData-backed conversation storage.
///
/// `@ModelActor` gives this type its own actor-isolated `ModelContext`, so all
/// reads and writes happen off the main actor. That matters for this product
/// specifically: the panel must appear in tens of milliseconds, and a store
/// write on the main actor during streaming would stutter the transcript.
@ModelActor
public actor SwiftDataConversationStore: ConversationStore {

    // MARK: - Writes

    public func createConversation(title: String,
                                   providerID: String,
                                   modelID: String,
                                   sourceAppName: String?) throws -> ConversationID {
        let conversation = StoredConversation(title: title,
                                              providerID: providerID,
                                              modelID: modelID,
                                              sourceAppName: sourceAppName)
        modelContext.insert(conversation)
        try modelContext.save()
        return ConversationID(conversation.identifier)
    }

    public func appendMessage(_ message: PersistedMessage, to id: ConversationID) throws {
        let conversation = try require(id)
        let stored = StoredMessage(identifier: message.id,
                                   role: message.role,
                                   text: message.text,
                                   createdAt: message.createdAt,
                                   contextText: message.contextText,
                                   contextSourceApp: message.contextSourceApp,
                                   inputTokens: message.inputTokens,
                                   outputTokens: message.outputTokens)
        stored.conversation = conversation
        modelContext.insert(stored)

        for attachment in message.attachments {
            let storedAttachment = StoredAttachment(mimeType: attachment.mimeType,
                                                    data: attachment.data)
            storedAttachment.message = stored
            modelContext.insert(storedAttachment)
        }

        conversation.updatedAt = message.createdAt
        try modelContext.save()
    }

    public func updateTitle(_ title: String, for id: ConversationID) throws {
        let conversation = try require(id)
        conversation.title = title
        conversation.updatedAt = .now
        try modelContext.save()
    }

    public func deleteConversation(_ id: ConversationID) throws {
        let conversation = try require(id)
        modelContext.delete(conversation)
        try modelContext.save()
    }

    // MARK: - Reads

    public func recentConversations(limit: Int) throws -> [ConversationSummary] {
        var descriptor = FetchDescriptor<StoredConversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(Self.summary)
    }

    public func messages(in id: ConversationID) throws -> [PersistedMessage] {
        let conversation = try require(id)
        return (conversation.messages ?? [])
            .sorted { $0.createdAt < $1.createdAt }
            .map { stored in
                PersistedMessage(
                    id: stored.identifier,
                    role: stored.role,
                    text: stored.text,
                    createdAt: stored.createdAt,
                    attachments: (stored.attachments ?? []).map {
                        ImageAttachment(mimeType: $0.mimeType, data: $0.data)
                    },
                    contextText: stored.contextText,
                    contextSourceApp: stored.contextSourceApp,
                    inputTokens: stored.inputTokens,
                    outputTokens: stored.outputTokens
                )
            }
    }

    /// Substring search over titles and message bodies.
    ///
    /// SwiftData has no full-text index, so this is a `contains` scan. Fine at
    /// the scale this app produces; if it ever is not, the escape hatch is an
    /// FTS5 table through the system's own SQLite rather than a dependency.
    /// Titles and message bodies are queried separately because a predicate
    /// that reaches across the relationship is both slower and less reliable.
    public func search(_ query: String, limit: Int) throws -> [ConversationSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try recentConversations(limit: limit) }

        let titleMatches = try modelContext.fetch(
            FetchDescriptor<StoredConversation>(
                predicate: #Predicate { $0.title.localizedStandardContains(trimmed) },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        )

        let bodyMatches = try modelContext.fetch(
            FetchDescriptor<StoredMessage>(
                predicate: #Predicate { $0.text.localizedStandardContains(trimmed) }
            )
        ).compactMap(\.conversation)

        var seen = Set<UUID>()
        var results: [ConversationSummary] = []
        for conversation in titleMatches + bodyMatches {
            guard seen.insert(conversation.identifier).inserted else { continue }
            results.append(Self.summary(conversation))
            if results.count == limit { break }
        }
        return results.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func mostRecentConversation(updatedWithin interval: TimeInterval) throws -> ConversationSummary? {
        guard let latest = try recentConversations(limit: 1).first else { return nil }
        guard Date.now.timeIntervalSince(latest.updatedAt) <= interval else { return nil }
        return latest
    }

    // MARK: - Usage

    public func usageStatistics(lastDays days: Int, calendar: Calendar) throws -> UsageStatistics {
        let today = calendar.startOfDay(for: .now)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
            return .empty
        }

        // Only assistant turns carry token counts.
        let messages = try modelContext.fetch(
            FetchDescriptor<StoredMessage>(
                predicate: #Predicate { $0.createdAt >= start && $0.outputTokens != nil }
            )
        )

        var perDay: [Date: (input: Int, output: Int)] = [:]
        var perModel: [String: (provider: String, input: Int, output: Int, turns: Int)] = [:]
        var conversations = Set<UUID>()
        var totalInput = 0
        var totalOutput = 0

        for message in messages {
            let input = message.inputTokens ?? 0
            let output = message.outputTokens ?? 0
            totalInput += input
            totalOutput += output

            let day = calendar.startOfDay(for: message.createdAt)
            perDay[day, default: (0, 0)].input += input
            perDay[day, default: (0, 0)].output += output

            if let conversation = message.conversation {
                conversations.insert(conversation.identifier)
                let key = conversation.modelID
                var entry = perModel[key] ?? (conversation.providerID, 0, 0, 0)
                entry.input += input
                entry.output += output
                entry.turns += 1
                perModel[key] = entry
            }
        }

        // Fill empty days so the timeline has no invisible gaps.
        var timeline: [UsageStatistics.Day] = []
        for offset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let bucket = perDay[date] ?? (0, 0)
            timeline.append(.init(date: date, inputTokens: bucket.input, outputTokens: bucket.output))
        }

        let models = perModel
            .map { UsageStatistics.ModelBreakdown(modelID: $0.key, providerID: $0.value.provider,
                                                  inputTokens: $0.value.input,
                                                  outputTokens: $0.value.output,
                                                  turns: $0.value.turns) }
            .sorted { $0.totalTokens > $1.totalTokens }

        return UsageStatistics(
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            assistantTurns: messages.count,
            conversationCount: conversations.count,
            days: timeline,
            models: models
        )
    }

    // MARK: - Helpers

    private func require(_ id: ConversationID) throws -> StoredConversation {
        let target = id.rawValue
        var descriptor = FetchDescriptor<StoredConversation>(
            predicate: #Predicate { $0.identifier == target }
        )
        descriptor.fetchLimit = 1
        guard let found = try modelContext.fetch(descriptor).first else {
            throw ConversationStoreError.conversationNotFound(id)
        }
        return found
    }

    private static func summary(_ conversation: StoredConversation) -> ConversationSummary {
        ConversationSummary(
            id: ConversationID(conversation.identifier),
            title: conversation.title,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            messageCount: conversation.messages?.count ?? 0,
            providerID: conversation.providerID,
            modelID: conversation.modelID,
            sourceAppName: conversation.sourceAppName
        )
    }
}
