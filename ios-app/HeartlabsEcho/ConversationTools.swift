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

/// Fetches a past journal conversation by dateKey (yyyy-MM-dd).
struct ConversationLookupTool: ConversationTool {
    var definition: LLMTool {
        LLMTool(
            name: "get_conversation",
            description: "Retrieve a past journal entry for a specific date for detailed context.",
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
        guard let args: DateKeyArgs = decodeToolArgs(arguments),
              let dateKey = args.dateKey
        else {
            return "Failed to parse arguments for get_conversation"
        }
        guard let text = context.conversationService.fetchFullConversationText(kind: .journal, dateKey: dateKey) else {
            return "No journal entry found for date \(dateKey)"
        }
        return text
    }
}

/// Shared argument struct for tools that accept a dateKey string.
private struct DateKeyArgs: Decodable {
    let dateKey: String?
}

/// Shared helper: decodes a tool's JSON argument string into a `Decodable` type.
/// Returns `nil` if parsing fails.
func decodeToolArgs<T: Decodable>(_ arguments: String) -> T? {
    guard let data = arguments.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}
