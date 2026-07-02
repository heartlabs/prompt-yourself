import Combine
import Foundation
import SwiftUI

/// The ViewModel for the Dreams screen.
///
/// Manages speech-to-text, LLM communication (dream analysis), and the in-memory
/// message list. Unlike `ChatViewModel`, this has no persistence, no tool calls,
/// and no context-building — just the system prompt + conversation history.
@MainActor
final class DreamViewModel: ObservableObject {
    // MARK: - Published State

    /// All messages in the current dream analysis session.
    @Published private(set) var messages: [ChatMessage] = []

    /// Whether the LLM is currently generating a response.
    @Published private(set) var isThinking = false

    /// A user-facing status message.
    @Published private(set) var statusMessage: String = "Tap the microphone to share a dream"

    /// The speech recognizer — owned here so state stays consistent.
    let recognizer = SpeechRecognizer()

    /// Whether the chat should auto-scroll to the bottom on new messages.
    @Published private(set) var shouldAutoScroll = false

    /// Monotonically increasing counter bumped to request a scroll-to-bottom.
    @Published private(set) var scrollToBottomCount = 0

    // MARK: - Private State

    private let router: ModelRouter
    private var systemPrompt: String = ""
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(router: ModelRouter = ModelRouter()) {
        self.router = router
        loadSystemPrompt()

        recognizer.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // When the recognizer publishes a spontaneous transcript (error or
        // system timeout without user action), send it to the LLM immediately.
        recognizer.$pendingTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pending in
                guard let self, let pending, !pending.isEmpty else { return }
                self.recognizer.pendingTranscript = nil
                self.shouldAutoScroll = true
                Task { await self.sendTranscript() }
            }
            .store(in: &cancellables)

        // When the ~1-minute timeout fires, the recogniser publishes the
        // accumulated text as a segment. Turn it into a separate user bubble
        // so the timeout boundary is visible — no LLM call yet.
        recognizer.$accumulatedSegment
            .receive(on: DispatchQueue.main)
            .sink { [weak self] segment in
                guard let self, let segment, !segment.isEmpty else { return }
                self.recognizer.accumulatedSegment = nil
                self.shouldAutoScroll = true
                let msg = ChatMessage(role: .user, content: segment)
                self.messages.append(msg)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Stops recording immediately and sends the partial transcript.
    func stopRecordingOnBackground() {
        guard recognizer.isRecording else { return }
        statusMessage = "Finalizing..."
        recognizer.stopTranscribing()
        Task {
            await sendTranscript()
        }
    }

    /// Toggle recording on/off.
    /// After stopping, automatically send the new transcript to the LLM.
    func toggleRecording() {
        if recognizer.isRecording {
            statusMessage = "Finalizing..."
            Task {
                await recognizer.stopTranscribingAsync()
                await sendTranscript()
            }
        } else {
            shouldAutoScroll = true
            recognizer.startTranscribing()
        }
    }

    /// Requests a scroll-to-bottom (e.g. when switching back to the tab).
    func requestScrollToBottom() {
        scrollToBottomCount += 1
    }

    // MARK: - Private Helpers

    /// Loads the dream analysis system prompt from the bundled resource.
    private func loadSystemPrompt() {
        guard let url = Bundle.main.url(forResource: "dream-system-prompt", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else {
            systemPrompt = "You are a thoughtful dream analyst. Help the user understand their dreams."
            return
        }
        systemPrompt = content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - LLM Communication

    /// Sends the recorded transcript to the LLM and appends the response.
    private func sendTranscript() async {
        let transcript = recognizer.transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !transcript.isEmpty else {
            statusMessage = "Tap to speak"
            return
        }

        // Append user message
        let userMessage = ChatMessage(role: .user, content: transcript)
        messages.append(userMessage)
        shouldAutoScroll = true

        isThinking = true
        shouldAutoScroll = true
        statusMessage = "..."

        do {
            // Build full history: system prompt + conversation
            var fullHistory: ChatHistory = []
            if !systemPrompt.isEmpty {
                fullHistory.append(ChatMessage(role: .system, content: systemPrompt))
            }
            fullHistory.append(contentsOf: messages)

            let response = try await router.sendMessages(fullHistory, tier: .performant)

            if case .text(let text) = response {
                let assistantMessage = ChatMessage(role: .assistant, content: text)
                messages.append(assistantMessage)
                statusMessage = "Reply received"
            } else {
                statusMessage = "I couldn't process that — please try again"
            }
        } catch {
            let errorMessage = ChatMessage(
                role: .assistant,
                content: "⚠️ \(error.localizedDescription)\n\n\(router.diagnostics(for: .performant))"
            )
            messages.append(errorMessage)
            statusMessage = "Error — tap mic to retry"
        }

        isThinking = false
    }
}
