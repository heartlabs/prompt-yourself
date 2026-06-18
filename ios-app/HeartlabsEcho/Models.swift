import Foundation
import SwiftData

// MARK: - Conversation

/// A single day's conversation, keyed by date.
@Model
final class Conversation {
    /// Unique identifier.
    @Attribute(.unique) var id: UUID

    /// Calendar-date key, e.g. "2026-06-13".
    var dateKey: String

    /// When this conversation was first created.
    var createdAt: Date

    /// When the last message was added — used for the 30-min timeout check.
    var lastActivityAt: Date

    /// Auto-generated summary for this day's conversation (e.g. "User talked about work stress...").
    var summary: String?

    /// All messages in this conversation, ordered by timestamp.
    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message]

    init(dateKey: String) {
        self.id = UUID()
        self.dateKey = dateKey
        self.createdAt = Date()
        self.lastActivityAt = Date()
        self.messages = []
    }

    /// Whether this conversation belongs to today.
    var isToday: Bool {
        dateKey == Self.dateKey(for: Date())
    }

    /// Returns the date key string for a given date (e.g. "2026-06-13").
    static func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Message

/// A single message in a conversation.
@Model
final class Message {
    /// Unique identifier (mirrors `ChatMessage.id`).
    @Attribute(.unique) var id: UUID

    /// One of "system", "user", "assistant".
    var role: String

    /// The message text content.
    var content: String

    /// When the message was created.
    var timestamp: Date

    /// The conversation this message belongs to.
    var conversation: Conversation?

    init(id: UUID, role: String, content: String, timestamp: Date) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}
