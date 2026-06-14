import Foundation

/// A single message in the conversation.
struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date

    enum Role: String, Codable {
        case system
        case user
        case assistant
    }

    init(role: Role, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
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
    }

    /// The `role` string value used in the SwiftData `Message.role` property.
    var roleRawValue: String {
        role.rawValue
    }
}
#endif
