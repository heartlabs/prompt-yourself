import Foundation

// MARK: - Shared Date Formatter

/// One formatter for consistent goal timestamps across all goal tools.
private func formatGoalDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

// MARK: - Goal Tools

/// Tools for managing user goals via LLM tool calls.
///
/// Each tool implements the `ConversationTool` protocol and operates on
/// a `GoalService` obtained from the `ToolContext`.

// MARK: - Create Goal

struct CreateGoalTool: ConversationTool {
    var definition: LLMTool {
        LLMTool(
            name: "create_goal",
            description: "Create a new goal for the user to track progress toward. "
                + "Max 5 open goals at a time. Progress starts at 0.",
            parameters: [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "A short, descriptive title for the goal (e.g. 'Run 10 times this month')",
                    ],
                    "description": [
                        "type": "string",
                        "description": "What the user wants to achieve and why and how success is defined",
                    ],
                    "targetProgress": [
                        "type": "integer",
                        "description": "The target value to reach (e.g. 10 for '10 runs', 1000 for '1000 EUR')",
                    ],
                    "unit": [
                        "type": "string",
                        "description": "The unit of measurement (e.g. 'runs', 'EUR', 'pages', 'sessions')",
                    ],
                ],
                "required": ["title", "description", "targetProgress", "unit"],
            ]
        )
    }

    @MainActor func run(arguments: String, context: ToolContext) -> String {

        struct Args: Decodable {
            let title: String
            let description: String
            let targetProgress: Int
            let unit: String
        }

        guard let args: Args = decodeToolArgs(arguments) else {
            return "⚠️ Could not parse goal arguments."
        }

        do {
            let goal = try context.goalService.createGoal(
                title: args.title,
                description: args.description,
                targetProgress: args.targetProgress,
                unit: args.unit
            )
            return "✅ Goal created: \"\(goal.title)\" — 0/\(args.targetProgress) \(args.unit). You have \(context.goalService.openGoalCount()) open goal(s) remaining."
        } catch let error as GoalError {
            return "⚠️ \(error.localizedDescription)"
        } catch {
            return "⚠️ Failed to create goal: \(error.localizedDescription)"
        }
    }
}

// MARK: - List Open Goals

struct ListOpenGoalsTool: ConversationTool {
    var definition: LLMTool {
        LLMTool(
            name: "list_open_goals",
            description: "List all active goals (progress less than 100%) with their current progress, target, unit, and description.",
            parameters: [
                "type": "object",
                "properties": [:],
                "additionalProperties": false,
            ]
        )
    }

    @MainActor func run(arguments: String, context: ToolContext) -> String {

        let goals = context.goalService.openGoals()
        guard !goals.isEmpty else {
            return "📋 No open goals."
        }

        var lines = ["📋 \(goals.count) open goal(s):"]
        for goal in goals {
            let pct = Int(goal.progressPercent * 100)
            lines.append("- id: \(goal.id.uuidString), title: \"\(goal.title)\", progress: \(goal.currentProgress)/\(goal.targetProgress) \(goal.unit) (\(pct)%), description: \"\(goal.desc)\", last updated: \(formatGoalDate(goal.lastUpdatedAt))")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Find Goal

struct FindGoalTool: ConversationTool {
    var definition: LLMTool {
        LLMTool(
            name: "find_goal",
            description: "Find a goal by its UUID or exact title (case insensitive). "
                + "Returns the goal regardless of completion status.",
            parameters: [
                "type": "object",
                "properties": [
                    "goalId": [
                        "type": "string",
                        "description": "UUID of the goal (from list_open_goals). If provided, title is ignored.",
                    ],
                    "title": [
                        "type": "string",
                        "description": "Exact title to search for (case insensitive). Only used if goalId is not provided.",
                    ],
                ],
                "oneOf": [
                    ["required": ["goalId"]],
                    ["required": ["title"]],
                ],
            ]
        )
    }

    @MainActor func run(arguments: String, context: ToolContext) -> String {

        struct Args: Decodable {
            let goalId: String?
            let title: String?
        }

        guard let args: Args = decodeToolArgs(arguments) else {
            return "⚠️ Could not parse search arguments."
        }

        let goal: Goal?

        if let goalId = args.goalId {
            guard let id = UUID(uuidString: goalId) else {
                return "⚠️ Invalid goal ID format: \(goalId)."
            }
            goal = context.goalService.findGoal(byId: id)
        } else if let title = args.title {
            goal = context.goalService.findGoal(byTitle: title)
        } else {
            return "⚠️ Provide either goalId or title to search."
        }

        guard let found = goal else {
            let identifier = args.goalId.map { "id \($0)" } ?? args.title.map { "title \"\($0)\"" } ?? ""
            return "📭 No goal found with \(identifier)."
        }

        let status = found.isComplete ? "completed" : "open"
        let pct = Int(found.progressPercent * 100)
        return "📭 Goal: \"\(found.title)\" (\(status)) — \(found.currentProgress)/\(found.targetProgress) \(found.unit) (\(pct)%), description: \"\(found.desc)\", last updated: \(formatGoalDate(found.lastUpdatedAt))"
    }
}

// MARK: - Update Goal

struct UpdateGoalTool: ConversationTool {
    var definition: LLMTool {
        LLMTool(
            name: "update_goal",
            description: "Update a goal's fields. Provide the goal ID (from list_open_goals) and any fields to change. "
                + "Use this to update progress, title, description, target, or unit. All values are absolute.",
            parameters: [
                "type": "object",
                "properties": [
                    "goalId": [
                        "type": "string",
                        "description": "UUID of the goal to update",
                    ],
                    "title": [
                        "type": "string",
                        "description": "New title (omit to keep current)",
                    ],
                    "description": [
                        "type": "string",
                        "description": "New description (omit to keep current)",
                    ],
                    "currentProgress": [
                        "type": "integer",
                        "description": "New current progress value (absolute, e.g. 7 for 7 runs). Omit to keep current.",
                    ],
                    "targetProgress": [
                        "type": "integer",
                        "description": "New target value (omit to keep current)",
                    ],
                    "unit": [
                        "type": "string",
                        "description": "New unit (omit to keep current)",
                    ],
                ],
                "required": ["goalId"],
            ]
        )
    }

    @MainActor func run(arguments: String, context: ToolContext) -> String {

        struct Args: Decodable {
            let goalId: String
            let title: String?
            let description: String?
            let currentProgress: Int?
            let targetProgress: Int?
            let unit: String?
        }

        guard let args: Args = decodeToolArgs(arguments) else {
            return "⚠️ Could not parse update arguments."
        }

        guard let id = UUID(uuidString: args.goalId) else {
            return "⚠️ Invalid goal ID format: \(args.goalId). Use the UUID from list_open_goals."
        }

        guard args.title != nil || args.description != nil || args.currentProgress != nil
                || args.targetProgress != nil || args.unit != nil else {
            return "⚠️ No fields provided to update. Specify at least one field."
        }

        do {
            let goal = try context.goalService.updateGoal(
                id: id,
                title: args.title,
                description: args.description,
                currentProgress: args.currentProgress,
                targetProgress: args.targetProgress,
                unit: args.unit
            )
            let pct = Int(goal.progressPercent * 100)
            return "✅ Goal updated: \"\(goal.title)\" — \(goal.currentProgress)/\(goal.targetProgress) \(goal.unit) (\(pct)%)"
        } catch let error as GoalError {
            return "⚠️ \(error.localizedDescription)"
        } catch {
            return "⚠️ Failed to update goal: \(error.localizedDescription)"
        }
    }
}

// MARK: - Delete Goal

struct DeleteGoalTool: ConversationTool {
    var definition: LLMTool {
        LLMTool(
            name: "delete_goal",
            description: "Permanently delete a goal by its UUID (from list_open_goals). Use this when the user wants to remove a goal entirely.",
            parameters: [
                "type": "object",
                "properties": [
                    "goalId": [
                        "type": "string",
                        "description": "UUID of the goal to delete",
                    ],
                ],
                "required": ["goalId"],
            ]
        )
    }

    @MainActor func run(arguments: String, context: ToolContext) -> String {

        struct Args: Decodable {
            let goalId: String
        }

        guard let args: Args = decodeToolArgs(arguments) else {
            return "⚠️ Could not parse delete arguments."
        }

        guard let id = UUID(uuidString: args.goalId) else {
            return "⚠️ Invalid goal ID format: \(args.goalId). Use the UUID from list_open_goals."
        }

        do {
            try context.goalService.deleteGoal(id: id)
            return "✅ Goal deleted."
        } catch let error as GoalError {
            return "⚠️ \(error.localizedDescription)"
        } catch {
            return "⚠️ Failed to delete goal: \(error.localizedDescription)"
        }
    }
}
