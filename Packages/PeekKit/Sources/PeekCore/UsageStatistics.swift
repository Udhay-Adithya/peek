import Foundation

/// Aggregated token usage, for the statistics pane.
public struct UsageStatistics: Sendable, Equatable {

    public struct Day: Sendable, Equatable, Identifiable {
        public var id: Date { date }
        public let date: Date
        public let inputTokens: Int
        public let outputTokens: Int

        public init(date: Date, inputTokens: Int, outputTokens: Int) {
            self.date = date
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }

        public var totalTokens: Int { inputTokens + outputTokens }
    }

    public struct ModelBreakdown: Sendable, Equatable, Identifiable {
        public var id: String { modelID }
        public let modelID: String
        public let providerID: String
        public let inputTokens: Int
        public let outputTokens: Int
        public let turns: Int

        public init(modelID: String, providerID: String,
                    inputTokens: Int, outputTokens: Int, turns: Int) {
            self.modelID = modelID
            self.providerID = providerID
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.turns = turns
        }

        public var totalTokens: Int { inputTokens + outputTokens }
    }

    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let assistantTurns: Int
    public let conversationCount: Int
    /// One entry per day in the range, including days with no usage, so the
    /// chart shows a continuous timeline rather than silently collapsing gaps.
    public let days: [Day]
    public let models: [ModelBreakdown]

    public init(totalInputTokens: Int, totalOutputTokens: Int, assistantTurns: Int,
                conversationCount: Int, days: [Day], models: [ModelBreakdown]) {
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.assistantTurns = assistantTurns
        self.conversationCount = conversationCount
        self.days = days
        self.models = models
    }

    public var totalTokens: Int { totalInputTokens + totalOutputTokens }

    public var isEmpty: Bool { assistantTurns == 0 }

    public static let empty = UsageStatistics(
        totalInputTokens: 0, totalOutputTokens: 0, assistantTurns: 0,
        conversationCount: 0, days: [], models: []
    )
}
