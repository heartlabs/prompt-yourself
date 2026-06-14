import Foundation
import SwiftData

/// Threshold for considering a session "active" after backgrounding.
private let sessionTimeout: TimeInterval = 30 * 60  // 30 minutes

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

    /// Attempts to load today's conversation.
    ///
    /// - Returns: The `Conversation` if one exists for today, or `nil`.
    func loadTodayConversation() -> Conversation? {
        let key = Self.todayDateKey
        let predicate = #Predicate<Conversation> { $0.dateKey == key }
        let descriptor = FetchDescriptor<Conversation>(predicate: predicate)

        do {
            let results = try modelContext.fetch(descriptor)
            return results.first
        } catch {
            print("[ConversationService] Failed to fetch today's conversation: \(error)")
            return nil
        }
    }

    /// Checks whether there is an active session (within the 30-minute timeout).
    ///
    /// - Parameter conversation: The conversation to check.
    /// - Returns: `true` if the conversation's last activity is within the timeout window.
    func isSessionActive(_ conversation: Conversation) -> Bool {
        let elapsed = Date().timeIntervalSince(conversation.lastActivityAt)
        return elapsed < sessionTimeout
    }

    /// Creates a new conversation for today and inserts it into the context.
    ///
    /// - Returns: The newly created `Conversation`.
    func createTodayConversation() -> Conversation {
        let conversation = Conversation(dateKey: Self.todayDateKey)
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

    /// Persists any pending changes to the store.
    func saveChanges() {
        do {
            try modelContext.save()
        } catch {
            print("[ConversationService] Failed to save: \(error)")
        }
    }
}
