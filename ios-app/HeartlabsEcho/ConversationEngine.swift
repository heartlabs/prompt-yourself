import Combine
import Foundation
import SwiftData

// MARK: - ConversationKind

/// Identifies which feature a conversation belongs to. Currently only journal
/// is supported.
enum ConversationKind: String {
    case journal
}

// MARK: - AppTab

/// The four root-level tabs. Owned by the engine so tab transitions and
/// their side effects are a single decision, not two coordinated calls.
enum AppTab: Hashable {
    case today
    case goals
    case calendar
    case tree
}

// MARK: - ChatCompleting

/// Abstraction over the chat-completion backend, so the send pipeline can be
/// driven by a fake in tests. `ModelRouter` is the production implementation.
protocol ChatCompleting {
    func sendMessages(
        _ messages: ChatHistory,
        tier: ModelTier,
        tools: [LLMTool]?,
        jsonMode: Bool,
        imageData: [UUID: Data]
    ) async throws -> LLMResponse
}

extension ModelRouter: ChatCompleting {}

// MARK: - ConversationConfiguration

/// Inert, per-feature configuration for a `ConversationEngine`.
///
/// Everything that differs between conversation features is expressed here as
/// data + explicit strategy closures (system prompt, model tier, tool registry,
/// context builder) — never as behaviour flags buried in the engine. A feature
/// that doesn't use tools simply passes `.none` as the tool registry.
struct ConversationConfiguration {
    let kind: ConversationKind
    /// Bundled markdown resource name (without extension) for the system prompt.
    let systemPromptResource: String
    /// Which model tier to send with.
    let tier: ModelTier
    /// Registry of tools the LLM may call. Empty ⇒ no tool loop.
    let toolRegistry: ToolRegistry
    /// Builds the full context prompt (system prompt + any extra context such as
    /// recent-day summaries) given the current store.
    /// Runs on the main actor because it reads the (main-actor-isolated) store.
    let makeContext: @MainActor (_ systemPrompt: String, _ store: ConversationService?) -> String
    /// System prompt used when the bundled `systemPromptResource` cannot be
    /// loaded. Each feature keeps its own sensible default so behaviour matches
    /// the pre-composition view models exactly.
    let fallbackSystemPrompt: String

    init(kind: ConversationKind,
         systemPromptResource: String,
         tier: ModelTier,
         toolRegistry: ToolRegistry,
         makeContext: @escaping @MainActor (_ systemPrompt: String, _ store: ConversationService?) -> String,
         fallbackSystemPrompt: String = "You are a helpful assistant.") {
        self.kind = kind
        self.systemPromptResource = systemPromptResource
        self.tier = tier
        self.toolRegistry = toolRegistry
        self.makeContext = makeContext
        self.fallbackSystemPrompt = fallbackSystemPrompt
    }

    // MARK: Journal configuration

    /// The daily journaling conversation: recent-day summary context +
    /// the get_conversation tool.
    static let journal = ConversationConfiguration(
        kind: .journal,
        systemPromptResource: "system-prompt",
        tier: .performant,
        toolRegistry: ToolRegistry(tools: [
            ConversationLookupTool(
                targetKind: .journal,
                toolName: "get_conversation",
                toolDescription: "Retrieve a past JOURNAL entry for a specific date for detailed context."
            ),
            CreateGoalTool(),
            ListOpenGoalsTool(),
            FindGoalTool(),
            UpdateGoalTool(),
            DeleteGoalTool(),
        ]),
        makeContext: { systemPrompt, store in
            var parts: [String] = [systemPrompt]
            guard let store else { return systemPrompt }

            let recent = store.fetchRecentConversations(kind: .journal, days: 7)
                .filter { $0.summary != nil }
            if !recent.isEmpty {
                let section = recent
                    .sorted(by: { $0.dateKey < $1.dateKey })
                    .map { "\($0.dateKey): \($0.summary!)" }
                    .joined(separator: "\n")
                parts.append("\n## Recent days\n" + section)
            }

            return parts.joined(separator: "\n")
        },
        fallbackSystemPrompt: "You are a helpful assistant."
    )
}

// MARK: - ConversationEngine

/// The pipeline behind a conversation screen: LLM communication (with a
/// bounded tool-call loop), per-day persistence, summary context,
/// conversation resolution (today / active-yesterday / new) and the
/// scroll/UI state the view binds to.
///
/// Speech capture is NOT handled here: it lives entirely inside
/// `VoiceComposerSession` (see `beginComposition()`). This engine only
/// consumes the finished `Composition` value — it never reads live
/// recording state.
///
/// Feature-specific behaviour comes entirely from the injected
/// `ConversationConfiguration`.
@MainActor
class ConversationEngine: ObservableObject {
    // MARK: - Phase

    /// Where the engine is in its lifecycle — the single source of truth.
    /// Every intent method performs a total switch over this enum; adding a
    /// case refuses to compile until every intent decides what it means.
    enum Phase: Equatable {
        /// No composition in progress, no LLM call in flight — ready.
        case idle
        /// The voice composer overlay is open; the associated session owns the
        /// entire recording lifecycle (mic, photo, exits).
        case composing(VoiceComposerSession)
        /// The LLM is generating a text response. The captured conversation ID
        /// pins the response to the conversation that triggered it (P0.1).
        case thinking(conversationID: UUID)
        /// A tool call is being executed ("remembering…" indicator). Same
        /// conversation-ID pin as `.thinking`.
        case callingTool(conversationID: UUID)
    }

    /// The engine's current phase. Views derive their booleans from this;
    /// they never read internal flags directly.
    @Published private(set) var phase: Phase = .idle

    // MARK: - Published State (derived / independent)

    /// The currently selected root tab. Owned by the engine so tab transitions
    /// are a single decision, not two coordinated view calls.
    @Published var displayedTab: AppTab = .today

    /// All messages in the current conversation (excluding the system prompt).
    @Published private(set) var messages: [ChatMessage] = []

    /// `true` while the LLM is generating a response or executing a tool call.
    /// Derived from `phase` — views read this, not the enum directly.
    var isThinking: Bool {
        switch phase {
        case .thinking, .callingTool: return true
        default: return false
        }
    }

    /// `true` only during tool-call execution ("remembering…" indicator).
    /// Derived from `phase`.
    var isRemembering: Bool {
        if case .callingTool = phase { return true }
        return false
    }

    /// The live voice-composer session, if one is open. The overlay is
    /// presented exactly while this is non-nil, and the session terminates
    /// only via `compositionDidFinish` — there is no other dismissal path.
    var activeComposition: VoiceComposerSession? {
        if case .composing(let session) = phase { return session }
        return nil
    }

    /// Alert text for a composition that failed before capturing anything
    /// (e.g. permission denied). Presented by the chat screen after the
    /// composer closes; cleared by the alert binding.
    @Published var compositionError: String?

    /// Whether the currently displayed conversation belongs to a past date
    /// (and should therefore be treated as read-only).
    @Published private(set) var isShowingPastConversation = false

    // MARK: - Scroll

    /// A single published scroll intent — the view observes this with ONE
    /// `onChange` handler. Setting a new value always replaces the old one,
    /// so duplicate intents (same case) are still delivered as change events.
    enum ScrollIntent: Equatable {
        case bottom   // scroll to the bottom anchor
        case typing   // scroll to the typing indicator
    }

    /// The current scroll request. The view consumes it via `onChange`.
    @Published private(set) var scrollIntent: ScrollIntent?

    /// Posts a scroll intent, bumping the value so duplicate intents still fire.
    private func requestScroll(_ intent: ScrollIntent) {
        scrollIntent = nil
        scrollIntent = intent
    }

    /// Whether the user has sent a message — auto-scroll is active from first
    /// composition until a past conversation is loaded.
    private var conversationIsActive = false

    // MARK: - Configuration & Dependencies

    let configuration: ConversationConfiguration
    private let router: ModelRouter
    private let chat: ChatCompleting
    private var systemPrompt: String = ""

    // MARK: - Persistence

    private let conversationService: ConversationService
    private let summaryService: SummaryService
    private let goalService: GoalService
    private var currentConversation: Conversation?

    /// Maximum number of tool call iterations per user message (prevents loops).
    private let maxToolCallIterations = 3

    // MARK: - Init

    init(configuration: ConversationConfiguration,
         conversationService: ConversationService,
         summaryService: SummaryService,
         goalService: GoalService,
         router: ModelRouter,
         chat: ChatCompleting? = nil) {
        self.configuration = configuration
        self.conversationService = conversationService
        self.summaryService = summaryService
        self.goalService = goalService
        self.router = router
        self.chat = chat ?? router
        loadSystemPrompt()

        loadPersistedConversation()
        Task { await summaryService.backfillOldVersions() }
    }

    // MARK: - Helpers

    /// Updates `isShowingPastConversation` based on the current conversation.
    /// Today is always mutable; an active past-day conversation (midnight
    /// boundary) is also treated as the current session.
    private func updatePastConversationFlag() {
        isShowingPastConversation = currentConversation.map { conv in
            if conv.isToday { return false }
            return !conv.hasRecentActivity
        } ?? false
    }

    /// Restores the active conversation on launch (today, else active
    /// yesterday, else nothing).
    private func loadPersistedConversation() {
        if let conversation = conversationService.loadTodayConversation(kind: configuration.kind) {
            adopt(conversation)
            return
        }
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()),
           let conversation = conversationService.loadConversation(dateKey: DateKey.from(yesterday), kind: configuration.kind),
           conversation.hasRecentActivity {
            adopt(conversation)
            return
        }
        // No active conversation — moodboard.
    }

    /// Adopts a conversation as the current one and loads its messages.
    private func adopt(_ conversation: Conversation) {
        currentConversation = conversation
        updatePastConversationFlag()
        conversationIsActive = false
        messages = conversation.messages
            .sorted(by: { $0.timestamp < $1.timestamp })
            .map { ChatMessage(from: $0) }
        if !isShowingPastConversation { requestScroll(.bottom) }
    }

    // MARK: - Public API

    /// Resets the chat to today's conversation (today, else active yesterday,
    /// else the empty start screen). No-op while the engine is busy.
    func resetToToday() {
        guard phase == .idle else { return }
        if let conversation = conversationService.loadTodayConversation(kind: configuration.kind) {
            adopt(conversation)
            finishReset()
            return
        }
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()),
           let conversation = conversationService.loadConversation(dateKey: DateKey.from(yesterday), kind: configuration.kind),
           conversation.hasRecentActivity {
            adopt(conversation)
            finishReset()
            return
        }

        // No conversation for today — show the start screen.
        currentConversation = nil
        updatePastConversationFlag()
        conversationIsActive = false
        messages = []
        finishReset()
    }

    /// Called when the Today tab is tapped. Resets to today if showing a past
    /// conversation; otherwise requests a scroll to bottom.
    func todayTabTapped() {
        guard phase == .idle else { return }
        if isShowingPastConversation {
            resetToToday()
        } else {
            requestScroll(.bottom)
        }
    }

    /// Loads a past conversation from the calendar and switches to the Today
    /// tab. The engine owns the tab decision — no view-side coordination needed.
    func navigateFromCalendar(to dateKey: String) {
        loadConversation(for: dateKey)
        displayedTab = .today
    }

    private func finishReset() {
        Task { await summaryService.backfillOldVersions() }
    }

    /// Loads a past conversation by its date key (read-only; no auto-scroll).
    /// No-op while the engine is busy (composing, thinking, or calling a tool).
    private func loadConversation(for dateKey: String) {
        guard phase == .idle else { return }
        guard let conversation = conversationService.loadConversation(dateKey: dateKey, kind: configuration.kind) else { return }

        currentConversation = conversation
        updatePastConversationFlag()
        conversationIsActive = false
        messages = conversation.messages
            .sorted(by: { $0.timestamp < $1.timestamp })
            .map { ChatMessage(from: $0) }
        // Past conversation — deliberately NOT scrolling.
    }

    // MARK: - Voice Composition

    /// Opens the voice composer. The returned session owns the ENTIRE
    /// recording lifecycle (mic, photo, exits); this engine only consumes
    /// the outcome in `compositionDidFinish`.
    ///
    /// No-op while the engine is not idle or a past conversation is shown.
    func beginComposition() {
        guard phase == .idle, !isShowingPastConversation else { return }
        conversationIsActive = true
        let session = VoiceComposerSession { [weak self] outcome in
            self?.compositionDidFinish(outcome)
        }
        phase = .composing(session)
    }

    /// Forwards backgrounding to the live session, which applies the
    /// send-what-exists policy. No-op when no composer is open.
    func handleAppBackground() {
        if case .composing(let session) = phase {
            session.appDidEnterBackground()
        }
    }

    /// The single exit funnel: consumes the session's outcome, transitions
    /// the phase, and — for `.sent` — starts the LLM pipeline pinned to
    /// the current conversation's identity.
    private func compositionDidFinish(_ outcome: VoiceComposerSession.Outcome) {
        guard case .composing = phase else { return }
        switch outcome {
        case .sent(let composition):
            guard let conversation = ensureConversation(),
                  sendUserMessages(from: composition) else {
                phase = .idle
                return
            }
            // A real composition went out — the orb is being learned.
            OrbCoachmark.recordCompositionSent()
            let targetID = conversation.id
            phase = .thinking(conversationID: targetID)
            requestScroll(.typing)
            Task { await sendToLLM(on: conversation, targetID: targetID) }
        case .cancelled:
            phase = .idle
        case .failed(let message):
            compositionError = message
            phase = .idle
        }
    }

    // MARK: - Private Helpers

    private func loadSystemPrompt() {
        guard let url = Bundle.main.url(forResource: configuration.systemPromptResource, withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else {
            systemPrompt = configuration.fallbackSystemPrompt
            return
        }
        var prompt = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Prepend the language instruction so the LLM responds in the right language.
        let langInstruction = AppLanguage.current.languageInstruction
        if !langInstruction.isEmpty {
            prompt = langInstruction + prompt
        }

        // Prepend the user's name so the LLM can address them personally.
        if let name = UserName.current, !name.isEmpty {
            prompt = "The user's name is \(name). Always address them by name.\n\n" + prompt
        }

        systemPrompt = prompt
    }

    /// Ensures there is an active conversation, creating one for today if needed.
    private func ensureConversation() -> Conversation? {
        if let existing = currentConversation { return existing }

        if let existing = conversationService.loadTodayConversation(kind: configuration.kind) {
            currentConversation = existing
            return existing
        }
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()),
           let existing = conversationService.loadConversation(dateKey: DateKey.from(yesterday), kind: configuration.kind),
           existing.hasRecentActivity {
            currentConversation = existing
            return existing
        }
        let new = conversationService.createTodayConversation(kind: configuration.kind)
        currentConversation = new
        return new
    }

    // MARK: - Persistence

    /// Persists a message with typed content.
    /// `MessageContent` is split into `(contentType, content)` for SwiftData.
    private func persistMessage(role: ChatMessage.Role, content: MessageContent, id: UUID, timestamp: Date) {
        guard let conversation = ensureConversation() else { return }
        let (type, value) = content.persistable
        conversationService.addMessage(to: conversation, id: id, role: role.rawValue, contentType: type, content: value, timestamp: timestamp)
    }

    /// Convenience overload for text-only messages.
    private func persistMessage(role: ChatMessage.Role, content: String, id: UUID, timestamp: Date) {
        persistMessage(role: role, content: .text(content), id: id, timestamp: timestamp)
    }

    // MARK: - Send Composition

    /// Appends the user messages from a composition to the conversation.
    /// Returns `false` if the composition contains no messages (should not
    /// happen — a terminating session always has content).
    private func sendUserMessages(from composition: Composition) -> Bool {
        var userMessages: [ChatMessage] = []
        if !composition.transcript.isEmpty {
            userMessages.append(ChatMessage(role: .user, content: composition.transcript))
        }
        if let photoPath = composition.photoPath {
            userMessages.append(ChatMessage(role: .user, content: .image(relativePath: photoPath)))
        }
        guard !userMessages.isEmpty else { return false }

        for message in userMessages {
            messages.append(message)
            persistMessage(role: .user, content: message.content, id: message.id, timestamp: message.timestamp)
        }
        requestScroll(.bottom)
        conversationIsActive = true
        return true
    }

    // MARK: - LLM Communication

    /// Shared send loop: builds context, calls the LLM (with tool loop),
    /// appends the assistant response, and persists it to the conversation
    /// whose identity was captured at send time.
    ///
    /// After every `await`, re-validates that the phase still matches the
    /// captured identity — a stale result from a superseded conversation
    /// can never write messages or phase transitions (P0.1).
    private func sendToLLM(on conversation: Conversation, targetID: UUID) async {
        conversationIsActive = true

        // Pre-load image data for any image messages in the history.
        var imageData: [UUID: Data] = [:]
        for msg in messages {
            if case .image(let path) = msg.content, let data = ImageUtils.loadImageData(relativePath: path) {
                imageData[msg.id] = data
            }
        }

        do {
            let contextPrompt = configuration.makeContext(systemPrompt, conversationService)
            var fullHistory: ChatHistory = []
            if !contextPrompt.isEmpty {
                fullHistory.append(ChatMessage(role: .system, content: contextPrompt))
            }
            // Inject open goals context
            let goalsContext = goalService.openGoalsContextString()
            if !goalsContext.isEmpty {
                fullHistory.append(ChatMessage(role: .system, content: goalsContext))
            }

            fullHistory.append(contentsOf: messages)

            let tools = configuration.toolRegistry.definitions
            var finalResponse: String?
            var didAttemptToolCall = false

        toolLoop:
            for _ in 0..<maxToolCallIterations {
                // Re-validate phase before every LLM call.
                guard case .thinking(let id) = phase, id == targetID else { return }

                let response = try await chat.sendMessages(
                    fullHistory,
                    tier: configuration.tier,
                    tools: tools.isEmpty ? nil : tools,
                    jsonMode: false,
                    imageData: imageData
                )

                // Re-validate after the await — the world changes.
                guard case .thinking(let id) = phase, id == targetID else { return }

                switch response {
                case .text(let text):
                    finalResponse = text
                    break toolLoop

                case .toolCalls(let toolCalls):
                    didAttemptToolCall = true
                    phase = .callingTool(conversationID: targetID)
                    requestScroll(.typing)
                    let toolCallStart = Date()

                    // Append assistant tool-call message to LLM history (OpenAI spec).
                    fullHistory.append(ChatMessage(role: .assistant, content: "", toolCalls: toolCalls))

                    let toolContext = ToolContext(
                        conversationService: conversationService,
                        goalService: goalService
                    )

                    for call in toolCalls {
                        let resultText = configuration.toolRegistry.execute(call, context: toolContext)
                        fullHistory.append(ChatMessage(role: .tool, content: resultText, toolCallId: call.id))
                    }

                    // Guarantee minimum visibility of the "remembering" indicator.
                    let elapsed = Date().timeIntervalSince(toolCallStart)
                    let minDisplay: TimeInterval = 0.4
                    if elapsed < minDisplay {
                        try? await Task.sleep(nanoseconds: UInt64((minDisplay - elapsed) * 1_000_000_000))
                    }

                    // Re-validate after tool execution — the world changes.
                    guard case .callingTool(let id) = phase, id == targetID else { return }
                    phase = .thinking(conversationID: targetID)
                    requestScroll(.typing)
                }
            }

            // Re-validate before persisting the final result.
            guard case .thinking(let id) = phase, id == targetID else { return }

            let assistantContent: String
            if let response = finalResponse {
                assistantContent = response
            } else if didAttemptToolCall {
                // P0.6 — tool-loop exhaustion: the LLM returned only
                // tool calls across all iterations without ever producing
                // a text response. Append an explicit fallback so the
                // conversation doesn't dead-end silently.
                assistantContent = "I've gathered the relevant information. How can I help you further?"
            } else {
                // No tool calls and no text — shouldn't happen, but don't
                // leave the conversation hanging.
                assistantContent = "I'm here to help. What would you like to talk about?"
            }

            let assistantMessage = ChatMessage(role: .assistant, content: assistantContent)
            messages.append(assistantMessage)
            requestScroll(.bottom)
            conversationService.addMessage(
                to: conversation,
                id: assistantMessage.id,
                role: ChatMessage.Role.assistant.rawValue,
                contentType: Message.contentTypeText,
                content: assistantContent,
                timestamp: assistantMessage.timestamp
            )
        } catch {
            // Re-validate before showing the error.
            guard case .thinking(let id) = phase, id == targetID else { return }

            #if DEBUG
            print("[ConversationEngine] LLM error: \(error.localizedDescription) \(router.diagnostics(for: configuration.tier))")
            #endif
            let errorMessage = ChatMessage(role: .assistant, content: "⚠️ \(error.localizedDescription)")
            messages.append(errorMessage)
            requestScroll(.bottom)
            conversationService.addMessage(
                to: conversation,
                id: errorMessage.id,
                role: ChatMessage.Role.assistant.rawValue,
                contentType: Message.contentTypeText,
                content: errorMessage.content.persistable.1,
                timestamp: errorMessage.timestamp
            )
        }

        // Only clear the phase if it still belongs to this conversation.
        if case .thinking(let id) = phase, id == targetID {
            phase = .idle
        }
    }
}
