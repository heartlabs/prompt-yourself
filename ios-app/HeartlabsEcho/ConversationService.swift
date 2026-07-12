import Foundation
import os
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
            Logger.storage.error("Failed to fetch all date keys: \(error)")
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
            Logger.storage.error("Failed to load conversation for \(dateKey): \(error)")
            return nil
        }
    }

    /// Attempts to load today's conversation for the given kind.
    ///
    /// - Parameter kind: The conversation kind to scope to (e.g. `.journal`).
    /// - Returns: The `Conversation` if one exists for today+kind, or `nil`.
    func loadTodayConversation(kind: ConversationKind) -> Conversation? {
        let key = DateKey.today
        let kindRaw = kind.rawValue
        let predicate = #Predicate<Conversation> { $0.dateKey == key && $0.kind == kindRaw }
        let descriptor = FetchDescriptor<Conversation>(predicate: predicate)

        do {
            let results = try modelContext.fetch(descriptor)
            return results.first
        } catch {
            Logger.storage.error("Failed to fetch today's conversation: \(error)")
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
        let conversation = Conversation(dateKey: DateKey.today)
        conversation.kind = kind.rawValue
        modelContext.insert(conversation)
        saveChanges()
        return conversation
    }

    // MARK: - Message queries

    /// All messages across all conversations of the given kind, newest first.
    private func allMessages(kind: ConversationKind) -> [Message] {
        let conversations = fetchAllConversations(kind: kind)
        return conversations
            .flatMap { $0.messages }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// Counts all user messages across all conversations of the given kind.
    func countUserMessages(kind: ConversationKind) -> Int {
        allMessages(kind: kind).filter { $0.role == Message.roleUser }.count
    }

    /// Counts all image messages across all conversations of the given kind.
    func countImageMessages(kind: ConversationKind) -> Int {
        allMessages(kind: kind).filter { $0.contentType == Message.contentTypeImage }.count
    }

    /// Loads the most recent image messages across all conversations of the given kind.
    func fetchRecentPhotos(kind: ConversationKind, limit: Int) -> [Message] {
        Array(allMessages(kind: kind).filter { $0.contentType == Message.contentTypeImage }.prefix(limit))
    }

    /// Loads all image messages across all conversations of the given kind, sorted newest-first.
    func fetchAllPhotos(kind: ConversationKind) -> [Message] {
        allMessages(kind: kind).filter { $0.contentType == Message.contentTypeImage }
    }

    /// Fetches all conversations of the given kind, sorted by date key descending.
    private func fetchAllConversations(kind: ConversationKind) -> [Conversation] {
        let kindRaw = kind.rawValue
        let descriptor = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.dateKey, order: .reverse)])
        return ((try? modelContext.fetch(descriptor)) ?? []).filter { $0.kind == kindRaw }
    }

    /// Adds a message to the given conversation.
    ///
    /// - Parameters:
    ///   - conversation: The conversation to add to.
    ///   - id: The message's UUID.
    ///   - role: The role — "user" or "assistant".
    ///   - contentType: The type of content — "text" or "image".
    ///   - content: The message text or relative image path.
    ///   - timestamp: When the message was created.
    func addMessage(to conversation: Conversation, id: UUID, role: String, contentType: String = "text", content: String, timestamp: Date) {
        let message = Message(id: id, role: role, contentType: contentType, content: content, timestamp: timestamp)
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
        let todayKey = DateKey.today
        return (1 ... days)
            .compactMap { offset in
                guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
                let key = DateKey.from(date)
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
        let lines = sortedMessages.map { msg in
            let prefix = msg.role.capitalized
            if msg.contentType == "image" {
                return "[\(prefix)]: (photo)"
            }
            return "[\(prefix)]: \(msg.content)"
        }
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
            Logger.storage.error("Failed to save: \(error)")
            #if DEBUG
            assertionFailure("ConversationService save failed — journal data may be lost: \(error)")
            #endif
        }
    }
}
