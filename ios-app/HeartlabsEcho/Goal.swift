import Foundation
import SwiftData

// MARK: - Goal Model

/// A goal the user set for themselves, with progress tracking.
///
/// Progress is represented as `currentProgress / targetProgress` with a
/// human-readable `unit` (e.g. "runs", "EUR", "pages").
@Model
final class Goal {
    @Attribute(.unique) var id: UUID
    var title: String
    var desc: String
    var currentProgress: Int
    var targetProgress: Int
    var unit: String
    var lastUpdatedAt: Date
    var createdAt: Date

    init(title: String, description: String, currentProgress: Int = 0, targetProgress: Int, unit: String) {
        self.id = UUID()
        self.title = title
        self.desc = description
        self.currentProgress = currentProgress
        self.targetProgress = targetProgress
        self.unit = unit
        self.lastUpdatedAt = Date()
        self.createdAt = Date()
    }

    /// Whether the goal has reached or exceeded its target.
    var isComplete: Bool { currentProgress >= targetProgress }

    /// Progress as a fraction from 0.0 to 1.0.
    var progressPercent: Double {
        guard targetProgress > 0 else { return 0 }
        return min(Double(currentProgress) / Double(targetProgress), 1.0)
    }
}

// MARK: - GoalError

enum GoalError: LocalizedError {
    case maxOpenGoalsReached
    case notFound
    case invalidTarget(String)
    case invalidProgress(String)

    var errorDescription: String? {
        switch self {
        case .maxOpenGoalsReached:
            return "You already have \(GoalService.maxOpenGoals) open goals. Close or delete one before creating a new goal."
        case .notFound:
            return "Goal not found."
        case .invalidTarget(let detail):
            return "Invalid goal target: \(detail)"
        case .invalidProgress(let detail):
            return "Invalid progress value: \(detail)"
        }
    }
}

// MARK: - GoalService

/// Manages persistence and queries for goals via SwiftData.
@MainActor
final class GoalService {
    private let modelContext: ModelContext

    /// Maximum number of open goals allowed at once.
    static let maxOpenGoals = 5

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Queries

    /// All goals where progress < target (i.e. not yet completed).
    func openGoals() -> [Goal] {
        let predicate = #Predicate<Goal> { $0.currentProgress < $0.targetProgress }
        let descriptor = FetchDescriptor<Goal>(predicate: predicate)
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            print("[GoalService] Failed to fetch open goals: \(error)")
            return []
        }
    }

    /// All goals where progress >= target (i.e. completed).
    func closedGoals() -> [Goal] {
        let predicate = #Predicate<Goal> { $0.currentProgress >= $0.targetProgress }
        let descriptor = FetchDescriptor<Goal>(predicate: predicate)
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            print("[GoalService] Failed to fetch closed goals: \(error)")
            return []
        }
    }

    /// Find a goal by UUID (any status).
    func findGoal(byId id: UUID) -> Goal? {
        let predicate = #Predicate<Goal> { $0.id == id }
        let descriptor = FetchDescriptor<Goal>(predicate: predicate)
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            print("[GoalService] Failed to find goal: \(error)")
            return nil
        }
    }

    /// Find a goal by exact case-insensitive title match (any status).
    func findGoal(byTitle title: String) -> Goal? {
        let descriptor = FetchDescriptor<Goal>()
        do {
            let goals = try modelContext.fetch(descriptor)
            return goals.first { $0.title.lowercased() == title.lowercased() }
        } catch {
            print("[GoalService] Failed to find goal: \(error)")
            return nil
        }
    }

    /// Number of currently open goals.
    func openGoalCount() -> Int {
        openGoals().count
    }

    // MARK: - Mutations

    /// Create a new goal. Enforces the 5-open-goal limit.
    /// Target must be > 0.
    @discardableResult
    func createGoal(title: String, description: String, targetProgress: Int, unit: String) throws -> Goal {
        guard openGoalCount() < Self.maxOpenGoals else {
            throw GoalError.maxOpenGoalsReached
        }
        guard targetProgress > 0 else {
            throw GoalError.invalidTarget("Target must be greater than 0.")
        }

        let goal = Goal(
            title: title,
            description: description,
            targetProgress: targetProgress,
            unit: unit
        )
        modelContext.insert(goal)
        try modelContext.save()
        return goal
    }

    /// Update any subset of fields on a goal. At least one field must be provided.
    /// Throws `.notFound` if no goal exists for the given id.
    /// Validates target > 0 and current ≥ 0 on every write.
    @discardableResult
    func updateGoal(
        id: UUID,
        title: String? = nil,
        description: String? = nil,
        currentProgress: Int? = nil,
        targetProgress: Int? = nil,
        unit: String? = nil
    ) throws -> Goal {
        guard let goal = findGoal(byId: id) else {
            throw GoalError.notFound
        }

        // Validate progress invariants on every mutation, same as createGoal.
        if let tp = targetProgress, tp <= 0 {
            throw GoalError.invalidTarget("Target must be greater than 0.")
        }
        if let cp = currentProgress, cp < 0 {
            throw GoalError.invalidProgress("Current progress cannot be negative.")
        }

        if let title = title { goal.title = title }
        if let description = description { goal.desc = description }
        if let currentProgress = currentProgress { goal.currentProgress = currentProgress }
        if let targetProgress = targetProgress { goal.targetProgress = targetProgress }
        if let unit = unit { goal.unit = unit }

        goal.lastUpdatedAt = Date()
        try modelContext.save()
        return goal
    }

    /// Permanently remove a goal.
    func deleteGoal(id: UUID) throws {
        guard let goal = findGoal(byId: id) else {
            throw GoalError.notFound
        }
        modelContext.delete(goal)
        try modelContext.save()
    }

    // MARK: - Context Injection

    /// Returns a formatted string describing all active (open) goals,
    /// suitable for injecting into the LLM system context.
    func openGoalsContextString() -> String {
        let goals = openGoals()
        guard !goals.isEmpty else { return "" }

        var lines = ["\n## Active Goals"]
        for goal in goals {
            let pct = Int(goal.progressPercent * 100)
            lines.append("- \"\(goal.title)\": \(goal.currentProgress)/\(goal.targetProgress) \(goal.unit) (\(pct)%) — \(goal.desc)")
        }
        lines.append("The user is tracking these goals. Reference them naturally in conversation, offer encouragement, and connect them to the user's reflections when relevant.")
        return lines.joined(separator: "\n")
    }
}
