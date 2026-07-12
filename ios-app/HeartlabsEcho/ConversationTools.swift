import Foundation

// MARK: - ToolContext

/// Services available to tool implementations during execution.
struct ToolContext {
    let conversationService: ConversationService
    let goalService: GoalService
}

// MARK: - ConversationTool

/// One callable tool: its LLM-facing definition + how to run it.
protocol ConversationTool {
    var definition: LLMTool { get }
    @MainActor func run(arguments: String, context: ToolContext) -> String
}

// MARK: - ToolRegistry

/// The set of tools available to a conversation; exposes definitions to the
/// LLM and dispatches an incoming tool call by name.
struct ToolRegistry {
    let tools: [ConversationTool]

    var definitions: [LLMTool] { tools.map(\.definition) }

    @MainActor func execute(_ call: ToolCallPayload, context: ToolContext) -> String {
        guard let tool = tools.first(where: { $0.definition.name == call.function.name }) else {
            return "Unknown tool: \(call.function.name)"
        }
        return tool.run(arguments: call.function.arguments, context: context)
    }

    static let none = ToolRegistry(tools: [])
}

// MARK: - ConversationLookupTool

/// Fetches a past conversation of a specific `kind` by dateKey (yyyy-MM-dd).
/// Reused for same-kind lookups and cross-kind lookups.
struct ConversationLookupTool: ConversationTool {
    let targetKind: ConversationKind
    let toolName: String
    let toolDescription: String

    var definition: LLMTool {
        LLMTool(
            name: toolName,
            description: toolDescription,
            parameters: [
                "type": "object",
                "properties": [
                    "dateKey": [
                        "type": "string",
                        "description": "The date in yyyy-MM-dd format, e.g. 2026-06-13",
                    ],
                ],
                "required": ["dateKey"],
            ]
        )
    }

    @MainActor func run(arguments: String, context: ToolContext) -> String {
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dateKey = args["dateKey"] as? String
        else {
            return "Failed to parse arguments for \(toolName)"
        }
        guard let text = context.conversationService.fetchFullConversationText(kind: targetKind, dateKey: dateKey) else {
            return "No \(targetKind.rawValue) entry found for date \(dateKey)"
        }
        return text
    }
}
