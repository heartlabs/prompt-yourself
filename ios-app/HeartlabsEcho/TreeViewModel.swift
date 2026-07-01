import Foundation
import SwiftData
import SwiftUI

/// Drives the "Your Life" screen: owns the scoring service and the current state.
@MainActor
final class TreeViewModel: ObservableObject {
    @Published private(set) var state: TreeState = .loading

    /// Cosmetic month label (rolling 30-day window in v1; the dropdown is decorative).
    let monthLabel: String = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: Date())
    }()

    private var service: TreeScoreService?
    private var hasLoadedOnce = false

    /// Wires up the scoring service from the SwiftData context. Idempotent.
    func setup(modelContext: ModelContext) {
        guard service == nil else { return }
        let conversationService = ConversationService(modelContext: modelContext)
        service = TreeScoreService(conversationService: conversationService)
    }

    /// Loads the tree on first appearance (cache-aware).
    func loadIfNeeded() async {
        guard !hasLoadedOnce else { return }
        hasLoadedOnce = true
        await reload(force: false)
    }

    /// Recomputes, bypassing the cache (pull-to-refresh).
    func refresh() async {
        await reload(force: true)
    }

    private func reload(force: Bool) async {
        guard let service else {
            state = .error("Journal storage isn't ready yet.")
            return
        }
        if force { state = .loading }
        let result = await service.loadOrCompute(force: force)
        state = result
    }

    // MARK: - Derived display helpers

    /// Zone → 0…100 for the renderer (empty while loading / on error).
    var scoresForCanvas: [String: Int] {
        if case .ready(let score) = state {
            return score.scores
        }
        return [:]
    }

    /// The lowest-scoring categories, used for the encouraging focus line.
    func focusLine(for score: TreeScore) -> String {
        let ranked = LifeCategory.all
            .map { (cat: $0, value: score.score($0.zone)) }
            .sorted { $0.value < $1.value }

        guard let lowest = ranked.first else {
            return "Every reflection helps your tree grow."
        }

        // If everything is already thriving, celebrate instead of nudging.
        if lowest.value >= 70 {
            return "Beautifully balanced — keep tending every part of your life."
        }

        let names: String
        if ranked.count >= 2, ranked[1].value < 70 {
            names = "\(lowest.cat.title.lowercased()) and \(ranked[1].cat.title.lowercased())"
        } else {
            names = lowest.cat.title.lowercased()
        }
        return "A little more attention on \(names) could help your tree flourish."
    }
}
