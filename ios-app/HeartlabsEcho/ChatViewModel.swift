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

    /// Whether the LLM is retrieving a past conversation (tool call in progress).
    @Published private(set) var isRemembering = false

    /// A user-facing status message.
    @Published private(set) var statusMessage: String = "Tap the microphone to start"

    /// The speech recognizer — owned here so state stays consistent.
    let recognizer = SpeechRecognizer()

    /// Whether the currently displayed conversation belongs to a past date
    /// (and should therefore be treated as read-only).
    @Published private(set) var isShowingPastConversation = false

    /// Whether the chat should auto-scroll to the bottom on new messages.
    /// True during recording or when the agent is responding.
    /// False when browsing past conversations.
    @Published private(set) var shouldAutoScroll = false

    /// Monotonically increasing counter bumped to request a scroll-to-bottom.
    /// Used when switching back to the conversation tab or returning from background
    /// — cases where shouldAutoScroll may already be true and we need a fresh trigger.
    @Published private(set) var scrollToBottomCount = 0

    // MARK: - Private State

    private let router: ModelRouter
    private var systemPrompt: String = ""
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Persistence

    private var conversationService: ConversationService?
    private var currentConversation: Conversation?
    private var hasSetupPersistence = false

    // MARK: - Tool Definitions

    /// Tool that lets the LLM retrieve the full conversation of a past day.
    private let getConversationTool = LLMTool(
        name: "get_conversation",
        description: "Retrieve the full conversation for a specific date to get detailed context.",
        parameters: [
            "type": "object",
            "properties": [
                "dateKey": [
                    "type": "string",
                    "description": "The date in yyyy-MM-dd format, e.g. 2026-06-13",
                ],
            ],
            "required": ["dateKey"],
        ]
    )

    // MARK: - Init

    init(router: ModelRouter = ModelRouter()) {
        self.router = router
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

    // MARK: - Helpers

    /// Updates `isShowingPastConversation` based on the current conversation.
    ///
    /// A conversation is read-only (past) only when:
    /// - Its dateKey is not today, **and**
    /// - It has no recent activity (idle >30 min)
    ///
    /// Today is always mutable. An active past-day conversation (midnight boundary)
    /// is also treated as the current session.
    private func updatePastConversationFlag() {
        isShowingPastConversation = currentConversation.map { conv in
            if conv.isToday { return false }
            return !conv.hasRecentActivity
        } ?? false
    }

    // MARK: - Persistence Setup

    /// Initializes persistence with the given SwiftData model context.
    ///
    /// Call this once from the view (e.g. in `.task`) after the environment's
    /// `modelContext` is available. If a conversation already exists for today
    /// it is restored automatically.
    ///
    /// - Parameter modelContext: The SwiftData `ModelContext` from the environment.
    func setupPersistence(with modelContext: ModelContext) {
        guard !hasSetupPersistence else { return }
        hasSetupPersistence = true

        let service = ConversationService(modelContext: modelContext)
        conversationService = service

        loadPersistedConversation(service: service)

        // Fire-and-forget: generate summary for the previous day if needed.
        Task {
            await generateSummaryForPreviousDayIfNeeded()
        }
    }

    /// Restores the active conversation on app launch.
    ///
    /// Priority order:
    /// 1. Today's conversation — always resumed.
    /// 2. Yesterday's conversation — resumed only if still active (<30 min idle).
    /// 3. Nothing — moodboard shown.
    private func loadPersistedConversation(service: ConversationService) {
        // 1. Check today
        if let conversation = service.loadTodayConversation() {
            currentConversation = conversation
            updatePastConversationFlag()
            shouldAutoScroll = false
            messages = conversation.messages
                .sorted(by: { $0.timestamp < $1.timestamp })
                .map { ChatMessage(from: $0) }
            if !messages.isEmpty { statusMessage = "Reply received" }
            requestScrollToBottomIfActive()
            return
        }

        // 2. Check yesterday — only if still active (midnight boundary)
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()),
           let conversation = service.loadConversation(dateKey: Conversation.dateKey(for: yesterday)),
           conversation.hasRecentActivity {
            currentConversation = conversation
            updatePastConversationFlag()
            shouldAutoScroll = false
            messages = conversation.messages
                .sorted(by: { $0.timestamp < $1.timestamp })
                .map { ChatMessage(from: $0) }
            if !messages.isEmpty { statusMessage = "Reply received" }
            requestScrollToBottomIfActive()
            return
        }

        // 3. No active conversation — moodboard
    }

    // MARK: - Public API

    /// Resets the chat to today's conversation.
    ///
    /// Priority order:
    /// 1. Today's conversation — always opened.
    /// 2. Yesterday's conversation — opened only if still active (<30 min idle).
    /// 3. Nothing — moodboard shown.
    func resetToToday() {
        guard let service = conversationService else { return }

        // 1. Check today
        if let conversation = service.loadTodayConversation() {
            currentConversation = conversation
            updatePastConversationFlag()
            shouldAutoScroll = false
            messages = conversation.messages
                .sorted(by: { $0.timestamp < $1.timestamp })
                .map { ChatMessage(from: $0) }
            statusMessage = messages.isEmpty ? "Tap to start" : "Reply received"
            requestScrollToBottomIfActive()
            finishReset()
            return
        }

        // 2. Check yesterday — only if still active (midnight boundary)
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()),
           let conversation = service.loadConversation(dateKey: Conversation.dateKey(for: yesterday)),
           conversation.hasRecentActivity {
            currentConversation = conversation
            updatePastConversationFlag()
            shouldAutoScroll = false
            messages = conversation.messages
                .sorted(by: { $0.timestamp < $1.timestamp })
                .map { ChatMessage(from: $0) }
            statusMessage = messages.isEmpty ? "Tap to start" : "Reply received"
            requestScrollToBottomIfActive()
            finishReset()
            return
        }

        // 3. No conversation for today — show the start screen
        currentConversation = nil
        updatePastConversationFlag()
        shouldAutoScroll = false
        messages = []
        statusMessage = "Tap the microphone to start"

        finishReset()
    }

    /// Bumps `scrollToBottomCount` to ask the view to scroll to the bottom
    /// when the conversation is active (i.e. not a read-only past entry).
    ///
    /// This is called after loading an active conversation (app launch,
    /// tab switch back to Today, app returning from background).
    func requestScrollToBottomIfActive() {
        guard !isShowingPastConversation else { return }
        scrollToBottomCount += 1
    }

    /// Common tail of `resetToToday` — triggers summary generation for the previous day.
    private func finishReset() {
        Task {
            await generateSummaryForPreviousDayIfNeeded()
        }
    }

    /// Loads a past conversation by its date key, replacing the current messages.
    ///
    /// - Parameter dateKey: The date key string (e.g. `"2026-06-13"`).
    func loadConversation(for dateKey: String) {
        guard let service = conversationService else { return }
        guard let conversation = service.loadConversation(dateKey: dateKey) else { return }

        currentConversation = conversation
        updatePastConversationFlag()
        shouldAutoScroll = false
        messages = conversation.messages
            .sorted(by: { $0.timestamp < $1.timestamp })
            .map { ChatMessage(from: $0) }
        // Past conversation — deliberately NOT scrolling

        if messages.isEmpty {
            statusMessage = "No entries yet"
        } else {
            statusMessage = "Viewing entry from \(dateKey)"
        }
    }

    /// Stops recording immediately (synchronously) and sends the partial transcript.
    ///
    /// Used when the app goes to background — unlike `toggleRecording()` this doesn't
    /// await an async continuation that may never fire if the app is suspended.
    func stopRecordingOnBackground() {
        guard recognizer.isRecording else { return }
        statusMessage = "Finalizing..."
        recognizer.stopTranscribing()  // synchronous — no hanging continuation
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
                // Await the final transcript (no cancellation — reliable for long speech).
                await recognizer.stopTranscribingAsync()
                await sendTranscript()
            }
        } else {
            shouldAutoScroll = true
            recognizer.startTranscribing()
        }
    }

    // MARK: - Context Building (Step 5)

    /// Builds the context prompt by combining the system prompt with recent day summaries.
    ///
    /// The resulting string is prepended to every LLM request so the model is aware
    /// of past days' conversations via their summaries.
    private func buildContextPrompt() -> String {
        var contextParts: [String] = [systemPrompt]

        guard let service = conversationService else { return systemPrompt }

        let recentConvs = service.fetchRecentConversations(days: 7)
            .filter { $0.summary != nil }

        if !recentConvs.isEmpty {
            let summariesSection = recentConvs
                .sorted(by: { $0.dateKey < $1.dateKey })
                .map { "\($0.dateKey): \($0.summary!)" }
                .joined(separator: "\n")
            contextParts.append("\n## Recent days\n" + summariesSection)
        }

        return contextParts.joined(separator: "\n")
    }

    // MARK: - Summary Generation (Step 4)

    /// Generates summaries for all past days that are missing them.
    ///
    /// This runs as a fire-and-forget background task triggered when:
    /// - Persistence is first set up (`setupPersistence`)
    /// - The user resets to today (`resetToToday`)
    ///
    /// Days are processed from most recent to oldest. Each day uses a separate, minimal LLM
    /// call with a summarization-only system prompt. There is a small delay between calls to
    /// avoid hammering the API. Days that fail (network error, API issue) are logged and skipped
    /// — they stay nil and remain eligible for a future backfill attempt.
    ///
    /// **Skip rule:** A conversation that still has recent activity (<30 min idle) is not
    /// summarized — it may cross the midnight boundary and continue as the current session.
    private func generateSummaryForPreviousDayIfNeeded() async {
        guard let service = conversationService else { return }

        let todayKey = ConversationService.todayDateKey
        let allKeys = service.fetchAllDateKeys()
            .filter { $0 != todayKey }
            .reversed()  // most recent first

        for dateKey in allKeys {
            guard let conversation = service.loadConversation(dateKey: dateKey),
                  conversation.summary == nil,
                  !conversation.messages.isEmpty,
                  !conversation.hasRecentActivity  // skip active conversations
            else { continue }

            await generateSummary(for: dateKey, service: service)

            // Small delay between API calls to avoid rate limits.
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
        }
    }

    /// Generates and saves a summary for a single date key.
    private func generateSummary(for dateKey: String, service: ConversationService) async {
        let summarySystemPrompt = """
        You are a summarizer. Summarize the following conversation in 2-3 sentences.
        Focus on what the user talked about, how they felt, and any key events or decisions.
        Be concise and factual.
        """

        let conversationText = service.fetchFullConversationText(dateKey: dateKey) ?? ""

        let summaryRequest: ChatHistory = [
            ChatMessage(role: .system, content: summarySystemPrompt),
            ChatMessage(role: .user, content: conversationText),
        ]

        do {
            let response = try await router.sendMessages(summaryRequest, tier: .cheap)
            if case .text(let summary) = response {
                service.updateSummary(dateKey: dateKey, summary: summary)
                print("[ChatViewModel] Summary saved for \(dateKey): \(summary.prefix(80))...")
            }
        } catch {
            print("[ChatViewModel] Failed to generate summary for \(dateKey): \(error)")
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

    /// Ensures there is an active conversation, creating one if needed.
    ///
    /// Priority order:
    /// 1. `currentConversation` — already loaded in memory.
    /// 2. Today's conversation — exists in store from a previous session.
    /// 3. Yesterday's conversation — only if still active (midnight boundary).
    /// 4. New conversation for today — created by `ConversationService` (idempotent).
    ///
    /// - Returns: The `Conversation` to add messages to, or `nil` if no service.
    private func ensureConversation() -> Conversation? {
        if let existing = currentConversation {
            return existing
        }
        guard let service = conversationService else { return nil }

        // 2. Existing today conversation
        if let existing = service.loadTodayConversation() {
            currentConversation = existing
            return existing
        }

        // 3. Active yesterday conversation (midnight boundary)
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()),
           let existing = service.loadConversation(dateKey: Conversation.dateKey(for: yesterday)),
           existing.hasRecentActivity {
            currentConversation = existing
            return existing
        }

        // 4. Create new for today — idempotent, won't duplicate
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

    /// Maximum number of tool call iterations per user message.
    ///
    /// Prevents infinite loops if the LLM keeps requesting tool calls.
    private let maxToolCallIterations = 3

    /// Handles a single tool call and returns the result text.
    ///
    /// Returns the tool result content on success, or a descriptive error message on failure.
    /// Errors are returned as tool results (not thrown) so the LLM can respond gracefully.
    private func executeToolCall(_ call: ToolCallPayload) -> String {
        guard call.function.name == "get_conversation" else {
            return "Unknown tool: \(call.function.name)"
        }

        guard let data = call.function.arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dateKey = args["dateKey"] as? String
        else {
            return "Failed to parse arguments for get_conversation"
        }

        guard let text = conversationService?.fetchFullConversationText(dateKey: dateKey) else {
            return "No conversation found for date \(dateKey)"
        }

        return text
    }

    // MARK: - LLM Communication

    /// Builds the full message array (context prompt + conversation history)
    /// and sends it to the LLM, handling any tool calls in a loop.
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
        shouldAutoScroll = true

        // Persist user message
        persistMessage(role: "user", content: transcript, id: userMessage.id, timestamp: userMessage.timestamp)

        isThinking = true
        shouldAutoScroll = true
        statusMessage = "..."

        do {
            // Build LLM history: context prompt first, then user-visible conversation.
            let contextPrompt = buildContextPrompt()
            var fullHistory: ChatHistory = []
            if !contextPrompt.isEmpty {
                fullHistory.append(ChatMessage(role: .system, content: contextPrompt))
            }
            fullHistory.append(contentsOf: messages)

            let tools = [getConversationTool]
            var finalResponse: String?

            // Tool call loop — limited to prevent infinite loops (Gap 3).
        toolLoop:
            for _ in 0..<maxToolCallIterations {
                let response = try await router.sendMessages(fullHistory, tier: .performant, tools: tools)

                switch response {
                case .text(let text):
                    finalResponse = text
                    break toolLoop

                case .toolCalls(let toolCalls):
                    isRemembering = true
                    let toolCallStart = Date()

                    // Append assistant message with tool calls to LLM history (required by OpenAI spec).
                    let assistantToolMsg = ChatMessage(
                        role: .assistant,
                        content: "",
                        toolCalls: toolCalls
                    )
                    fullHistory.append(assistantToolMsg)

                    // Execute each tool call and append results (Gap 4: errors returned, not thrown).
                    for call in toolCalls {
                        let resultText = executeToolCall(call)
                        fullHistory.append(ChatMessage(
                            role: .tool,
                            content: resultText,
                            toolCallId: call.id
                        ))
                    }

                    // Guarantee minimum visibility so even millisecond-fast tool calls show the indicator.
                    let elapsed = Date().timeIntervalSince(toolCallStart)
                    let minDisplay: TimeInterval = 0.4
                    if elapsed < minDisplay {
                        try? await Task.sleep(nanoseconds: UInt64((minDisplay - elapsed) * 1_000_000_000))
                    }
                    isRemembering = false
                    // Loop continues: LLM will see tool results and respond.
                }
            }

            if let response = finalResponse {
                // Only the final text response is shown to the user (Gap 2).
                let assistantMessage = ChatMessage(role: .assistant, content: response)
                messages.append(assistantMessage)

                // Persist assistant message
                persistMessage(
                    role: "assistant",
                    content: response,
                    id: assistantMessage.id,
                    timestamp: assistantMessage.timestamp
                )

                statusMessage = "Reply received"
            } else {
                // No text response after all iterations — should be rare.
                statusMessage = "I couldn't process that — please try again"
            }
        } catch {
            let errorMessage = ChatMessage(
                role: .assistant,
                content: "⚠️ \(error.localizedDescription)\n\n\(router.diagnostics(for: .performant))"
            )
            messages.append(errorMessage)

            // Persist error message too
            persistMessage(
                role: "assistant",
                content: errorMessage.content,
                id: errorMessage.id,
                timestamp: errorMessage.timestamp
            )

            statusMessage = "Error — tap mic to retry"
        }

        isThinking = false
    }
}
