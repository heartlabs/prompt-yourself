import Foundation
import SwiftData
import SwiftUI

/// Drives the "Your Life" screen: owns the scoring service and the current state.
@MainActor
final class TreeViewModel: ObservableObject {
    @Published private(set) var state: TreeState = .loading

    private let service: TreeScoreService
    private var reloadTask: Task<Void, Never>?

    init(treeScoreService: TreeScoreService) {
        self.service = treeScoreService
    }

    /// Loads the tree on first appearance (cache-aware).
    /// Skips if already loaded or currently loading.
    func loadIfNeeded() {
        if case .ready = state { return }
        if case .error = state { return }
        reload(force: false)
    }

    /// Recomputes, bypassing the cache (pull-to-refresh).
    func refresh() {
        reload(force: true)
    }

    private func reload(force: Bool) {
        reloadTask?.cancel()
        if force { state = .loading }
        reloadTask = Task { [weak self] in
            guard let self else { return }
            let result = await service.loadOrCompute(force: force)
            guard !Task.isCancelled else { return }
            state = result
        }
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
            return LocalizationService.shared.localized("focus_line_fallback")
        }

        // If everything is already thriving, celebrate instead of nudging.
        if lowest.value >= 70 {
            return LocalizationService.shared.localized("focus_line_balanced")
        }

        let names: String
        if ranked.count >= 2, ranked[1].value < 70 {
            let a = lowest.cat.title.lowercased()
            let b = ranked[1].cat.title.lowercased()
            names = String(format: LocalizationService.shared.localized("focus_line_and"), a, b)
        } else {
            names = lowest.cat.title.lowercased()
        }
        return String(format: LocalizationService.shared.localized("focus_line_format"), names)
    }
}
