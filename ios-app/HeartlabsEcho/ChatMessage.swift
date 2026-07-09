import Foundation

// MARK: - MessageContent

/// The content of a single message — either text or an image from the user.
///
/// A message is strictly **either/or**: an image message contains no text,
/// a text message contains no image. Assistant messages are always text.
enum MessageContent: Codable, Equatable {
    case text(String)
    case image(relativePath: String)

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case path
    }

    private enum ContentType: String, Codable {
        case text
        case image
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(ContentType.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let path):
            try container.encode(ContentType.image, forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ContentType.self, forKey: .type)
        switch type {
        case .text:
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case .image:
            let path = try container.decode(String.self, forKey: .path)
            self = .image(relativePath: path)
        }
    }

    /// Splits this content into a `(type, value)` pair for SwiftData storage.
    var persistable: (type: String, value: String) {
        switch self {
        case .text(let text):    return ("text", text)
        case .image(let path):  return ("image", path)
        }
    }
}

// MARK: - ChatMessage

/// A single message in the conversation.
struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: Role
    let content: MessageContent
    let timestamp: Date
    let toolCallId: String?
    let toolCalls: [ToolCallPayload]?

    enum Role: String, Codable {
        case system
        case user
        case assistant
        case tool
    }

    // MARK: Primary init — takes a MessageContent

    init(role: Role, content: MessageContent, toolCallId: String? = nil, toolCalls: [ToolCallPayload]? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.toolCallId = toolCallId
        self.toolCalls = toolCalls
    }

    // MARK: Convenience init — wraps a plain string in .text(...)
    // Keeps all existing call sites working without changes.

    init(role: Role, content: String, toolCallId: String? = nil, toolCalls: [ToolCallPayload]? = nil) {
        self.init(role: role, content: .text(content), toolCallId: toolCallId, toolCalls: toolCalls)
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
        self.content = model.contentType == "image"
            ? .image(relativePath: model.content)
            : .text(model.content)
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
