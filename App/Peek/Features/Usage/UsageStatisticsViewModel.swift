import Foundation
import Observation
import OSLog
import PeekCore

@MainActor
@Observable
final class UsageStatisticsViewModel {

    enum Range: Int, CaseIterable, Identifiable {
        case week = 7
        case month = 30
        case quarter = 90

        var id: Int { rawValue }
        var label: String {
            switch self {
            case .week:    return "7 days"
            case .month:   return "30 days"
            case .quarter: return "90 days"
            }
        }
    }

    private(set) var statistics: UsageStatistics = .empty
    private(set) var isLoading = false

    var range: Range = .month {
        didSet { guard range != oldValue else { return }; reload() }
    }

    private let store: ConversationStore
    private var task: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "usage")

    init(store: ConversationStore) {
        self.store = store
    }

    func reload() {
        task?.cancel()
        isLoading = true
        let store = self.store
        let days = range.rawValue
        let calendar = Calendar.current

        task = Task { [weak self] in
            do {
                let result = try await store.usageStatistics(lastDays: days, calendar: calendar)
                guard !Task.isCancelled else { return }
                self?.statistics = result
            } catch {
                Self.logger.error("usage query failed")
            }
            self?.isLoading = false
        }
    }
}
