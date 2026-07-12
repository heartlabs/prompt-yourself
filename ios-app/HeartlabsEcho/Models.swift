import Foundation
import SwiftData

// MARK: - DateKey

/// A locale-safe, Gregorian-calendar date key (e.g. "2026-06-13").
/// Pinning the calendar prevents silent forking on non-Gregorian devices.
enum DateKey {
    /// Returns the date key string for today.
    static var today: String {
        from(Date())
    }

    /// Returns the date key string for a given date.
    static func from(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Conversation

/// A single day's conversation, keyed by date.
@Model
final class Conversation {
    /// Unique identifier.
    @Attribute(.unique) var id: UUID

    /// Calendar-date key, e.g. "2026-06-13".
    var dateKey: String

    /// Which feature this conversation belongs to, stored as the raw value of `ConversationKind`.
    ///
    /// Defaulted so SwiftData performs an automatic lightweight migration:
    /// existing rows created before this property are preserved and tagged
    /// `"journal"`. Do NOT remove the default literal.
    var kind: String = ConversationKind.journal.rawValue

    /// When this conversation was first created.
    var createdAt: Date

    /// When the last message was added — used for the 30-min timeout check.
    var lastActivityAt: Date

    /// Auto-generated summary for this day's conversation (e.g. "User talked about work stress...").
    var summary: String?

    /// Version of the summarizer that generated `summary`. `nil` means version 0.
    /// Increment `SummaryService.currentVersion` when the summarizer prompt changes
    /// to trigger regeneration of outdated summaries.
    var summaryVersion: Int?

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

    /// Time window (in seconds) before a conversation is considered inactive.
    static let activityTimeout: TimeInterval = 30 * 60

    /// Whether the last message was within the activity window (30 minutes).
    var hasRecentActivity: Bool {
        Date().timeIntervalSince(lastActivityAt) < Self.activityTimeout
    }

    /// Whether this conversation belongs to today.
    var isToday: Bool {
        dateKey == DateKey.today
    }

    /// The typed conversation kind, decoded from the stored raw value.
    /// Falls back to `.journal` for any unrecognised stored value (e.g. a row
    /// written by an older build that lacked the column).
    var conversationKind: ConversationKind {
        ConversationKind(rawValue: kind) ?? .journal
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

    /// The type of content — "text" or "image".
    /// Old messages without this field get "text" automatically.
    var contentType: String = "text"

    /// The message content:
    /// - For text messages: the text itself.
    /// - For image messages: relative path in the app sandbox (e.g. "attachments/uuid.jpg").
    var content: String

    /// When the message was created.
    var timestamp: Date

    /// The conversation this message belongs to.
    var conversation: Conversation?

    init(id: UUID, role: String, contentType: String = "text", content: String, timestamp: Date) {
        self.id = id
        self.role = role
        self.contentType = contentType
        self.content = content
        self.timestamp = timestamp
    }
}
