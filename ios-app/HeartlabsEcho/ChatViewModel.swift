import Combine
import Foundation
import SwiftData
import SwiftUI

/// The primary ViewModel that orchestrates speech recognition, LLM communication,
/// conversation persistence, and the conversation state displayed in the chat UI.
@MainActor
final class ChatViewModel: ObservableObject {
    // MARK: - Published State

    /// All messages in the current conversation (excluding the system prompt).
    @Published private(set) var messages: [ChatMessage] = []

    /// Whether the LLM is currently generating a response.
    @Published private(set) var isThinking = false

    /// A user-facing status message.
    @Published private(set) var statusMessage: String = "Tap the microphone to start"

    /// The speech recognizer — owned here so state stays consistent.
    let recognizer = SpeechRecognizer()

    // MARK: - Private State

    /// Exposed for diagnostics — shows the configuration being used.
    let configuration: LLMConfiguration

    private let llmService: LLMService
    private var systemPrompt: String = ""
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Persistence

    private var conversationService: ConversationService?
    private var currentConversation: Conversation?
    private var hasSetupPersistence = false

    // MARK: - Init

    init(llmService: LLMService = LLMService()) {
        self.llmService = llmService
        self.configuration = llmService.configuration
        loadSystemPrompt()

        // Forward change notifications from the nested SpeechRecognizer
        // so SwiftUI re-renders when recording state/transcript changes.
        recognizer.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Persistence Setup

    /// Initializes persistence with the given SwiftData model context.
    ///
    /// Call this once from the view (e.g. in `.task`) after the environment's
    /// `modelContext` is available. If a conversation already exists for today
    /// and the session is still active (within 30 min), messages are loaded.
    ///
    /// - Parameter modelContext: The SwiftData `ModelContext` from the environment.
    func setupPersistence(with modelContext: ModelContext) {
        guard !hasSetupPersistence else { return }
        hasSetupPersistence = true

        let service = ConversationService(modelContext: modelContext)
        conversationService = service

        loadPersistedConversation(service: service)
    }

    /// Attempts to restore today's conversation if the session is still active.
    private func loadPersistedConversation(service: ConversationService) {
        guard let conversation = service.loadTodayConversation() else {
            // No conversation for today → stay on start screen (messages is empty)
            return
        }

        guard service.isSessionActive(conversation) else {
            // Session timed out → stay on start screen (keep old data on disk)
            return
        }

        // Restore the conversation
        currentConversation = conversation
        messages = conversation.messages
            .sorted(by: { $0.timestamp < $1.timestamp })
            .map { ChatMessage(from: $0) }

        if !messages.isEmpty {
            statusMessage = "Reply received"
        }
    }

    // MARK: - Public API

    /// Loads a past conversation by its date key, replacing the current messages.
    ///
    /// - Parameter dateKey: The date key string (e.g. `"2026-06-13"`).
    func loadConversation(for dateKey: String) {
        guard let service = conversationService else { return }
        guard let conversation = service.loadConversation(dateKey: dateKey) else { return }

        currentConversation = conversation
        messages = conversation.messages
            .sorted(by: { $0.timestamp < $1.timestamp })
            .map { ChatMessage(from: $0) }

        if messages.isEmpty {
            statusMessage = "No entries yet"
        } else {
            statusMessage = "Viewing entry from \(dateKey)"
        }
    }

    /// Toggle recording on/off.
    /// After stopping, automatically send the new transcript to the LLM.
    func toggleRecording() {
        if recognizer.isRecording {
            statusMessage = "Finalizing..."
            Task {
                // Await the final transcript (no cancellation — reliable for long speech).
                await recognizer.stopTranscribingAsync()
                await sendTranscript()
            }
        } else {
            recognizer.startTranscribing()
        }
    }

    // MARK: - Private Helpers

    /// Loads the system prompt from the bundled resource file.
    private func loadSystemPrompt() {
        guard let url = Bundle.main.url(forResource: "system-prompt", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else {
            systemPrompt = "You are a helpful assistant."
            return
        }
        systemPrompt = content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ensures there is an active conversation for today, creating one if needed.
    ///
    /// - Returns: The `Conversation` to add messages to.
    private func ensureConversation() -> Conversation? {
        if let existing = currentConversation {
            return existing
        }
        guard let service = conversationService else { return nil }
        let new = service.createTodayConversation()
        currentConversation = new
        return new
    }

    /// Persists a message to the current conversation.
    ///
    /// - Parameters:
    ///   - role: The message role ("user" or "assistant").
    ///   - content: The message text.
    ///   - id: The message's UUID.
    ///   - timestamp: When the message was created.
    private func persistMessage(role: String, content: String, id: UUID, timestamp: Date) {
        guard let service = conversationService,
              let conversation = ensureConversation()
        else { return }
        service.addMessage(to: conversation, id: id, role: role, content: content, timestamp: timestamp)
    }

    /// Builds the full message array (system prompt + conversation history)
    /// and sends it to the LLM.
    private func sendTranscript() async {
        let transcript = recognizer.transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        // Don't send empty messages.
        guard !transcript.isEmpty else {
            statusMessage = "Tap to start"
            return
        }

        // Append the user's transcript as a message.
        let userMessage = ChatMessage(role: .user, content: transcript)
        messages.append(userMessage)

        // Persist user message
        persistMessage(role: "user", content: transcript, id: userMessage.id, timestamp: userMessage.timestamp)

        isThinking = true
        statusMessage = "..."

        do {
            // Build full history: system prompt first, then conversation.
            var fullHistory: ChatHistory = []
            if !systemPrompt.isEmpty {
                fullHistory.append(ChatMessage(role: .system, content: systemPrompt))
            }
            fullHistory.append(contentsOf: messages)

            let response = try await llmService.sendMessages(fullHistory)

            let assistantMessage = ChatMessage(role: .assistant, content: response)
            messages.append(assistantMessage)

            // Persist assistant message
            persistMessage(role: "assistant", content: response, id: assistantMessage.id, timestamp: assistantMessage.timestamp)

            statusMessage = "Reply received"
        } catch {
            let errorMessage = ChatMessage(
                role: .assistant,
                content: "⚠️ \(error.localizedDescription)\n\n\(configuration.diagnostics)"
            )
            messages.append(errorMessage)

            // Persist error message too
            persistMessage(role: "assistant", content: errorMessage.content, id: errorMessage.id, timestamp: errorMessage.timestamp)

            statusMessage = "Error — tap mic to retry"
        }

        isThinking = false
    }
}
