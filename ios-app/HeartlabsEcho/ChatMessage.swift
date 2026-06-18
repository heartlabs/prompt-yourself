import Foundation

/// A single message in the conversation.
struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date
    let toolCallId: String?
    let toolCalls: [ToolCallPayload]?

    enum Role: String, Codable {
        case system
        case user
        case assistant
        case tool
    }

    init(role: Role, content: String, toolCallId: String? = nil, toolCalls: [ToolCallPayload]? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.toolCallId = toolCallId
        self.toolCalls = toolCalls
    }
}

/// A tool call payload as returned by the LLM API (OpenAI-compatible format).
///
/// Stored in `ChatMessage.toolCalls` for assistant messages that requested tool calls.
struct ToolCallPayload: Codable, Equatable {
    let id: String
    let type: String
    let function: Function

    struct Function: Codable, Equatable {
        let name: String
        /// JSON string with the function arguments.
        let arguments: String
    }

    init(id: String, name: String, arguments: String) {
        self.id = id
        self.type = "function"
        self.function = Function(name: name, arguments: arguments)
    }
}

/// The full conversation history sent with every LLM request.
typealias ChatHistory = [ChatMessage]

// MARK: - SwiftData Conversion

#if canImport(SwiftData)
import SwiftData

extension ChatMessage {

    /// Creates a `ChatMessage` from a SwiftData `Message` model.
    init(from model: Message) {
        self.id = model.id
        self.role = Role(rawValue: model.role) ?? .user
        self.content = model.content
        self.timestamp = model.timestamp
        self.toolCallId = nil
        self.toolCalls = nil
    }

    /// The `role` string value used in the SwiftData `Message.role` property.
    var roleRawValue: String {
        role.rawValue
    }
}
#endif
