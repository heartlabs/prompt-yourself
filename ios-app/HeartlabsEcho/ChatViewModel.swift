import Combine
import Foundation
import SwiftUI

/// The primary ViewModel that orchestrates speech recognition, LLM communication,
/// and the conversation state displayed in the chat UI.
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

    // MARK: - Public API

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
            statusMessage = "Reply received"
        } catch {
            let errorMessage = ChatMessage(
                role: .assistant,
                content: "⚠️ \(error.localizedDescription)\n\n\(configuration.diagnostics)"
            )
            messages.append(errorMessage)
            statusMessage = "Error — tap mic to retry"
        }

        isThinking = false
    }
}
