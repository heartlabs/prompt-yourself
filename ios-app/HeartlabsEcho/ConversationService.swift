import Foundation
import SwiftData

// MARK: - ConversationService

/// Manages persistence of conversations via SwiftData.
///
/// Provides high-level operations for loading/resuming today's conversation,
/// adding messages, and checking whether the previous session is still active.
@MainActor
final class ConversationService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Public API

    /// The date key for today, e.g. `"2026-06-13"`.
    static var todayDateKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Fetches all date keys that have at least one conversation of the given kind.
    ///
    /// - Parameter kind: The conversation kind to scope to (e.g. `.journal`).
    /// - Returns: A sorted array of date key strings (e.g. `["2026-06-01", "2026-06-13"]`).
    func fetchAllDateKeys(kind: ConversationKind) -> [String] {
        // #Predicate can only compare stored primitives, so compare against the
        // raw String value captured locally — never the enum itself.
        let kindRaw = kind.rawValue
        let predicate = #Predicate<Conversation> { $0.kind == kindRaw }
        let descriptor = FetchDescriptor<Conversation>(predicate: predicate)
        do {
            let conversations = try modelContext.fetch(descriptor)
            let keys = Set(conversations.map(\.dateKey))
            return keys.sorted()
        } catch {
            print("[ConversationService] Failed to fetch all date keys: \(error)")
            return []
        }
    }

    /// Loads a conversation for a specific date key and kind.
    ///
    /// - Parameters:
    ///   - dateKey: The date key string (e.g. `"2026-06-13"`).
    ///   - kind: The conversation kind to scope to (e.g. `.journal`).
    /// - Returns: The `Conversation` if one exists for that date+kind, or `nil`.
    func loadConversation(dateKey: String, kind: ConversationKind) -> Conversation? {
        let kindRaw = kind.rawValue
        let predicate = #Predicate<Conversation> { $0.dateKey == dateKey && $0.kind == kindRaw }
        let descriptor = FetchDescriptor<Conversation>(predicate: predicate)
        do {
            let results = try modelContext.fetch(descriptor)
            return results.first
        } catch {
            print("[ConversationService] Failed to load conversation for \(dateKey): \(error)")
            return nil
        }
    }

    /// Attempts to load today's conversation for the given kind.
    ///
    /// - Parameter kind: The conversation kind to scope to (e.g. `.journal`).
    /// - Returns: The `Conversation` if one exists for today+kind, or `nil`.
    func loadTodayConversation(kind: ConversationKind) -> Conversation? {
        let key = Self.todayDateKey
        let kindRaw = kind.rawValue
        let predicate = #Predicate<Conversation> { $0.dateKey == key && $0.kind == kindRaw }
        let descriptor = FetchDescriptor<Conversation>(predicate: predicate)

        do {
            let results = try modelContext.fetch(descriptor)
            return results.first
        } catch {
            print("[ConversationService] Failed to fetch today's conversation: \(error)")
            return nil
        }
    }

    /// Returns or creates a conversation for today of the given kind.
    ///
    /// If a conversation already exists for today+kind (e.g. from a previous
    /// load), it is returned instead of creating a duplicate. This guarantees
    /// there is never more than one conversation per (day, kind).
    ///
    /// - Parameter kind: The conversation kind to create/scope to (e.g. `.journal`).
    /// - Returns: The existing or newly created `Conversation`.
    func createTodayConversation(kind: ConversationKind) -> Conversation {
        if let existing = loadTodayConversation(kind: kind) {
            return existing
        }
        let conversation = Conversation(dateKey: Self.todayDateKey)
        conversation.kind = kind.rawValue
        modelContext.insert(conversation)
        saveChanges()
        return conversation
    }

    /// Adds a message to the given conversation.
    ///
    /// - Parameters:
    ///   - conversation: The conversation to add to.
    ///   - id: The message's UUID.
    ///   - role: The role — "user" or "assistant".
    ///   - content: The message text.
    ///   - timestamp: When the message was created.
    func addMessage(to conversation: Conversation, id: UUID, role: String, content: String, timestamp: Date) {
        let message = Message(id: id, role: role, content: content, timestamp: timestamp)
        message.conversation = conversation
        conversation.messages.append(message)
        conversation.lastActivityAt = Date()
        saveChanges()
    }

    /// Fetches conversations of the given kind from the last N days (excluding today).
    ///
    /// - Parameters:
    ///   - kind: The conversation kind to scope to (e.g. `.journal`).
    ///   - days: Number of days to look back.
    /// - Returns: An array of `Conversation` objects (only days with a saved conversation of that kind).
    func fetchRecentConversations(kind: ConversationKind, days: Int) -> [Conversation] {
        let todayKey = Self.todayDateKey
        return (1 ... days)
            .compactMap { offset in
                guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
                let key = Conversation.dateKey(for: date)
                guard key != todayKey else { return nil }
                return loadConversation(dateKey: key, kind: kind)
            }
    }

    /// Loads a conversation of the given kind and formats all messages into a plain text block.
    ///
    /// - Parameters:
    ///   - kind: The conversation kind to scope to (e.g. `.journal`).
    ///   - dateKey: The date key string (e.g. `"2026-06-13"`).
    /// - Returns: A formatted text block, or `nil` if no conversation exists for that date+kind.
    func fetchFullConversationText(kind: ConversationKind, dateKey: String) -> String? {
        guard let conversation = loadConversation(dateKey: dateKey, kind: kind) else { return nil }
        let sortedMessages = conversation.messages.sorted { $0.timestamp < $1.timestamp }
        let lines = sortedMessages.map { "[\($0.role.capitalized)]: \($0.content)" }
        return "\(dateKey) conversation:\n" + lines.joined(separator: "\n")
    }

    /// Saves a summary to an existing conversation of the given kind.
    ///
    /// - Parameters:
    ///   - kind: The conversation kind to scope to (e.g. `.journal`).
    ///   - dateKey: The date key string (e.g. `"2026-06-13"`).
    ///   - summary: The summary text to store.
    ///   - version: The summarizer version that produced this summary.
    func updateSummary(kind: ConversationKind, dateKey: String, summary: String, version: Int? = nil) {
        guard let conversation = loadConversation(dateKey: dateKey, kind: kind) else { return }
        conversation.summary = summary
        conversation.summaryVersion = version
        saveChanges()
    }

    /// Persists any pending changes to the store.
    func saveChanges() {
        do {
            try modelContext.save()
        } catch {
            print("[ConversationService] Failed to save: \(error)")
        }
    }
}
