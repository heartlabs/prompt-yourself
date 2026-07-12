import Combine
import Foundation
import SwiftData

// MARK: - ConversationKind

/// Identifies which feature a conversation belongs to. Currently only journal
/// is supported.
enum ConversationKind: String {
    case journal
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
    // MARK: - Published State

    /// All messages in the current conversation (excluding the system prompt).
    @Published private(set) var messages: [ChatMessage] = []

    /// Whether the LLM is currently generating a response.
    @Published private(set) var isThinking = false

    /// Whether the LLM is retrieving a past conversation (tool call in progress).
    @Published private(set) var isRemembering = false

    /// The live voice-composer session, if one is open. The overlay is
    /// presented exactly while this is non-nil, and it is cleared ONLY by
    /// `compositionDidFinish` — there is no other dismissal path.
    @Published private(set) var activeComposition: VoiceComposerSession?

    /// Alert text for a composition that failed before capturing anything
    /// (e.g. permission denied). Presented by the chat screen after the
    /// composer closes; cleared by the alert binding.
    @Published var compositionError: String?

    /// Whether the currently displayed conversation belongs to a past date
    /// (and should therefore be treated as read-only).
    @Published private(set) var isShowingPastConversation = false

    /// Whether the chat should auto-scroll to the bottom on new messages.
    @Published private(set) var shouldAutoScroll = false

    /// Monotonically increasing counter bumped to request a scroll-to-bottom.
    @Published private(set) var scrollToBottomCount = 0

    // MARK: - Configuration & Dependencies

    let configuration: ConversationConfiguration
    private let router: ModelRouter
    private let chat: ChatCompleting
    private var systemPrompt: String = ""

    // MARK: - Persistence

    private var conversationService: ConversationService?
    private var summaryService: SummaryService?
    private var goalService: GoalService?
    private var currentConversation: Conversation?
    private var hasSetupPersistence = false

    /// Maximum number of tool call iterations per user message (prevents loops).
    private let maxToolCallIterations = 3

    // MARK: - Init

    init(configuration: ConversationConfiguration,
         router: ModelRouter = ModelRouter(),
         chat: ChatCompleting? = nil) {
        self.configuration = configuration
        self.router = router
        self.chat = chat ?? router
        loadSystemPrompt()
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

    // MARK: - Persistence Setup

    /// Initializes persistence with the given SwiftData model context. Call once
    /// from the view (e.g. in `.task`) after the environment `modelContext` is
    /// available. Restores today's (or an active yesterday's) conversation.
    func setupPersistence(with modelContext: ModelContext) {
        guard !hasSetupPersistence else { return }
        hasSetupPersistence = true

        let service = ConversationService(modelContext: modelContext)
        conversationService = service

        let summ = SummaryService(conversationService: service, kind: configuration.kind, router: router)
        summaryService = summ

        goalService = GoalService(modelContext: modelContext)

        loadPersistedConversation(service: service)

        Task { await summ.backfillOldVersions() }
    }

    /// Restores the active conversation on app launch (today, else active
    /// yesterday, else nothing).
    private func loadPersistedConversation(service: ConversationService) {
        if let conversation = service.loadTodayConversation(kind: configuration.kind) {
            adopt(conversation)
            return
        }
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()),
           let conversation = service.loadConversation(dateKey: Conversation.dateKey(for: yesterday), kind: configuration.kind),
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
        shouldAutoScroll = false
        messages = conversation.messages
            .sorted(by: { $0.timestamp < $1.timestamp })
            .map { ChatMessage(from: $0) }
        requestScrollToBottomIfActive()
    }

    // MARK: - Public API

    /// Resets the chat to today's conversation (today, else active yesterday,
    /// else the empty start screen).
    func resetToToday() {
        guard let service = conversationService else { return }

        if let conversation = service.loadTodayConversation(kind: configuration.kind) {
            adopt(conversation)
            finishReset()
            return
        }
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()),
           let conversation = service.loadConversation(dateKey: Conversation.dateKey(for: yesterday), kind: configuration.kind),
           conversation.hasRecentActivity {
            adopt(conversation)
            finishReset()
            return
        }

        // No conversation for today — show the start screen.
        currentConversation = nil
        updatePastConversationFlag()
        shouldAutoScroll = false
        messages = []
        finishReset()
    }

    /// Bumps `scrollToBottomCount` when the conversation is active (not a
    /// read-only past entry).
    func requestScrollToBottomIfActive() {
        guard !isShowingPastConversation else { return }
        scrollToBottomCount += 1
    }

    private func finishReset() {
        guard let summ = summaryService else { return }
        Task { await summ.backfillOldVersions() }
    }

    /// Loads a past conversation by its date key (read-only; no auto-scroll).
    func loadConversation(for dateKey: String) {
        guard let service = conversationService else { return }
        guard let conversation = service.loadConversation(dateKey: dateKey, kind: configuration.kind) else { return }

        currentConversation = conversation
        updatePastConversationFlag()
        shouldAutoScroll = false
        messages = conversation.messages
            .sorted(by: { $0.timestamp < $1.timestamp })
            .map { ChatMessage(from: $0) }
        // Past conversation — deliberately NOT scrolling.
    }

    // MARK: - Voice Composition

    /// Opens the voice composer. The returned session owns the ENTIRE
    /// recording lifecycle (mic, photo, exits); this engine only consumes
    /// the outcome in `compositionDidFinish`.
    func beginComposition() {
        guard activeComposition == nil, !isShowingPastConversation else { return }
        shouldAutoScroll = true
        activeComposition = VoiceComposerSession { [weak self] outcome in
            self?.compositionDidFinish(outcome)
        }
    }

    /// Forwards backgrounding to the live session, which applies the
    /// send-what-exists policy. No-op when no composer is open.
    func handleAppBackground() {
        activeComposition?.appDidEnterBackground()
    }

    /// The single exit funnel: consumes the session's outcome and unmounts
    /// the overlay by clearing `activeComposition` — nothing else may.
    private func compositionDidFinish(_ outcome: VoiceComposerSession.Outcome) {
        switch outcome {
        case .sent(let composition):
            send(composition)
        case .cancelled:
            break
        case .failed(let message):
            compositionError = message
        }
        activeComposition = nil
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
        guard let service = conversationService else { return nil }

        if let existing = service.loadTodayConversation(kind: configuration.kind) {
            currentConversation = existing
            return existing
        }
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()),
           let existing = service.loadConversation(dateKey: Conversation.dateKey(for: yesterday), kind: configuration.kind),
           existing.hasRecentActivity {
            currentConversation = existing
            return existing
        }
        let new = service.createTodayConversation(kind: configuration.kind)
        currentConversation = new
        return new
    }

    // MARK: - Persistence

    /// Persists a message with typed content.
    /// `MessageContent` is split into `(contentType, content)` for SwiftData.
    private func persistMessage(role: String, content: MessageContent, id: UUID, timestamp: Date) {
        guard let service = conversationService,
              let conversation = ensureConversation()
        else { return }
        let (type, value) = content.persistable
        service.addMessage(to: conversation, id: id, role: role, contentType: type, content: value, timestamp: timestamp)
    }

    /// Convenience overload for text-only messages.
    private func persistMessage(role: String, content: String, id: UUID, timestamp: Date) {
        persistMessage(role: role, content: .text(content), id: id, timestamp: timestamp)
    }

    // MARK: - Send Composition

    /// Sends a finished composition: the transcript (if any) as a text
    /// bubble, then the photo (if any) as an image bubble — followed by
    /// exactly ONE LLM exchange for the whole composition. Do not "fix"
    /// this into one exchange per bubble.
    ///
    /// A `Composition` can only be produced by a terminating
    /// `VoiceComposerSession`, so the transcript here is final by
    /// construction and is never empty together with a nil photo.
    private func send(_ composition: Composition) {
        var userMessages: [ChatMessage] = []
        if !composition.transcript.isEmpty {
            userMessages.append(ChatMessage(role: .user, content: composition.transcript))
        }
        if let photoPath = composition.photoPath {
            userMessages.append(ChatMessage(role: .user, content: .image(relativePath: photoPath)))
        }
        guard !userMessages.isEmpty else { return }

        for message in userMessages {
            messages.append(message)
            persistMessage(role: "user", content: message.content, id: message.id, timestamp: message.timestamp)
        }
        shouldAutoScroll = true

        // A real composition went out — the orb is being learned.
        OrbCoachmark.recordCompositionSent()

        Task { await sendToLLM() }
    }

    // MARK: - LLM Communication

    /// Shared send loop: builds context, calls the LLM (with tool loop),
    /// appends the assistant response, and persists it.
    ///
    /// The caller is responsible for appending the user message to `messages`
    /// and persisting it before calling this method.
    private func sendToLLM() async {
        isThinking = true
        shouldAutoScroll = true

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
            if let goalService = goalService {
                let goalsContext = goalService.openGoalsContextString()
                if !goalsContext.isEmpty {
                    fullHistory.append(ChatMessage(role: .system, content: goalsContext))
                }
            }

            fullHistory.append(contentsOf: messages)

            let tools = configuration.toolRegistry.definitions
            var finalResponse: String?

        toolLoop:
            for _ in 0..<maxToolCallIterations {
                let response = try await chat.sendMessages(
                    fullHistory,
                    tier: configuration.tier,
                    tools: tools.isEmpty ? nil : tools,
                    jsonMode: false,
                    imageData: imageData
                )

                switch response {
                case .text(let text):
                    finalResponse = text
                    break toolLoop

                case .toolCalls(let toolCalls):
                    isRemembering = true
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
                    isRemembering = false
                }
            }

            if let response = finalResponse {
                let assistantMessage = ChatMessage(role: .assistant, content: response)
                messages.append(assistantMessage)
                persistMessage(
                    role: "assistant",
                    content: .text(response),
                    id: assistantMessage.id,
                    timestamp: assistantMessage.timestamp
                )
            }
        } catch {
            #if DEBUG
            print("[ConversationEngine] LLM error: \(error.localizedDescription) \(router.diagnostics(for: configuration.tier))")
            #endif
            let errorMessage = ChatMessage(role: .assistant, content: "⚠️ \(error.localizedDescription)")
            messages.append(errorMessage)
            persistMessage(
                role: "assistant",
                content: errorMessage.content,
                id: errorMessage.id,
                timestamp: errorMessage.timestamp
            )
        }

        isThinking = false
    }
}
