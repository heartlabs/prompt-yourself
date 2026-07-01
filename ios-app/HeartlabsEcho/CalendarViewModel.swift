import Foundation
import SwiftData
import SwiftUI

// MARK: - Preview State

/// The state of the daily preview section below the calendar grid.
enum PreviewState: Equatable {
    /// No conversation exists for the selected date.
    case empty
    /// A preview is ready to display.
    case loaded(ConversationPreview)
    /// A summary is being generated for the selected date.
    case generating
}

// MARK: - CalendarViewModel

/// Manages the calendar grid state: current month, selected date,
/// which dates have entries, and preview data for the selected day.
@MainActor
final class CalendarViewModel: ObservableObject {
    // MARK: - Published State

    /// The month currently displayed in the calendar grid.
    @Published var currentMonth: Date

    /// The date the user has tapped on (or `nil`).
    @Published var selectedDate: Date?

    /// The current state of the daily preview.
    @Published var previewState: PreviewState = .empty

    /// Date keys (e.g. `"2026-06-13"`) that have at least one conversation.
    @Published var datesWithEntries: Set<String> = []

    // MARK: - Private State

    private var conversationService: ConversationService?
    private var hasSetup = false
    private lazy var router = ModelRouter()

    // MARK: - Init

    init() {
        // Truncate to the start of the current month.
        self.currentMonth = Self.startOfMonth(Date())
        self.selectedDate = nil
    }

    // MARK: - Setup

    /// Initializes the view model with a conversation service.
    ///
    /// Call this once from the view when the model context is available.
    func setup(with modelContext: ModelContext) {
        guard !hasSetup else { return }
        hasSetup = true

        let service = ConversationService(modelContext: modelContext)
        conversationService = service

        loadDatesWithEntries()
    }

    /// Refreshes the set of date keys that have entries.
    func loadDatesWithEntries() {
        guard let service = conversationService else { return }
        datesWithEntries = Set(service.fetchAllDateKeys())
    }

    // MARK: - Month Navigation

    /// Advance to the next month.
    func goToNextMonth() {
        guard let next = Calendar.current.date(byAdding: .month, value: 1, to: currentMonth) else { return }
        currentMonth = Self.startOfMonth(next)
    }

    /// Go back to the previous month.
    func goToPreviousMonth() {
        guard let prev = Calendar.current.date(byAdding: .month, value: -1, to: currentMonth) else { return }
        currentMonth = Self.startOfMonth(prev)
    }

    /// Whether the next month button should be disabled (e.g. can't go past current month).
    var canGoNext: Bool {
        let now = Self.startOfMonth(Date())
        return currentMonth < now
    }

    /// Whether a given date is in the future (after today).
    static func isFuture(_ date: Date) -> Bool {
        calendar.compare(date, to: Date(), toGranularity: .day) == .orderedDescending
    }

    // MARK: - Selection

    /// Selects a specific date in the calendar and refreshes the preview.
    func selectDate(_ date: Date) {
        selectedDate = date
        Task {
            await refreshPreview()
        }
    }

    // MARK: - Preview Data

    /// Refreshes the preview for the currently selected date.
    ///
    /// Determines the right preview content:
    /// - **Today**: shows the first sentences of the conversation.
    /// - **Has summary**: shows the first lines of the summary.
    /// - **No summary**: triggers on-the-fly generation with a loading indicator;
    ///   falls back to conversation text if generation fails.
    private func refreshPreview() async {
        guard let date = selectedDate, let service = conversationService else {
            previewState = .empty
            return
        }

        let dateKey = Self.dateKey(for: date)
        guard let conversation = service.loadConversation(dateKey: dateKey) else {
            previewState = .empty
            return
        }

        let sortedMessages = conversation.messages.sorted(by: { $0.timestamp < $1.timestamp })
        let firstMessage = sortedMessages.first(where: { $0.role == "user" }) ?? sortedMessages.first
        let timestamp = firstMessage.map { Self.timeString(from: $0.timestamp) } ?? ""
        let conversationSnippet = firstMessage.map { Self.snippet(from: $0.content) } ?? ""
        let isToday = Calendar.current.isDateInToday(date)

        if isToday {
            // Today — show the conversation text itself.
            previewState = .loaded(ConversationPreview(
                dateKey: dateKey,
                dateLabel: Self.dateLabel(for: date),
                timestamp: timestamp,
                snippet: conversationSnippet,
                isToday: true
            ))
            return
        }

        if let summary = conversation.summary {
            // Summary exists — show the first lines of the summary.
            previewState = .loaded(ConversationPreview(
                dateKey: dateKey,
                dateLabel: Self.dateLabel(for: date),
                timestamp: timestamp,
                snippet: Self.snippet(from: summary),
                isToday: false
            ))
            return
        }

        // No summary yet — check if conversation is still active (midnight boundary).
        // If active, show conversation text directly instead of generating a summary.
        if conversation.hasRecentActivity {
            previewState = .loaded(ConversationPreview(
                dateKey: dateKey,
                dateLabel: Self.dateLabel(for: date),
                timestamp: timestamp,
                snippet: conversationSnippet,
                isToday: false
            ))
            return
        }

        // No summary yet and not active — generate it on the fly.
        previewState = .generating

        do {
            if let generatedSummary = try await generateSummary(for: dateKey, service: service) {
                previewState = .loaded(ConversationPreview(
                    dateKey: dateKey,
                    dateLabel: Self.dateLabel(for: date),
                    timestamp: timestamp,
                    snippet: Self.snippet(from: generatedSummary),
                    isToday: false
                ))
            } else {
                // Generation returned nothing — fall back to conversation text.
                previewState = .loaded(ConversationPreview(
                    dateKey: dateKey,
                    dateLabel: Self.dateLabel(for: date),
                    timestamp: timestamp,
                    snippet: conversationSnippet,
                    isToday: false
                ))
            }
        } catch {
            // Generation failed — fall back to conversation text.
            previewState = .loaded(ConversationPreview(
                dateKey: dateKey,
                dateLabel: Self.dateLabel(for: date),
                timestamp: timestamp,
                snippet: conversationSnippet,
                isToday: false
            ))
        }
    }

    /// Generates and saves a summary for a single date.
    private func generateSummary(for dateKey: String, service: ConversationService) async throws -> String? {
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

        let response = try await router.sendMessages(summaryRequest, tier: .cheap)
        if case .text(let summary) = response {
            service.updateSummary(dateKey: dateKey, summary: summary)
            return summary
        }
        return nil
    }

    // MARK: - Date Helpers

    private static let calendar = Calendar.current

    /// Returns the start of the month for a given date.
    static func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
    }

    /// Returns the number of days in the given month.
    static func daysInMonth(_ date: Date) -> Int {
        calendar.range(of: .day, in: .month, for: date)?.count ?? 30
    }

    /// Returns the weekday index (0 = Monday … 6 = Sunday) for the first day of the month.
    static func firstWeekdayOffset(_ date: Date) -> Int {
        // 1 = Sunday in gregorian, 2 = Monday … 7 = Saturday
        let raw = calendar.component(.weekday, from: date)
        // Convert to Mon=0 … Sun=6
        return (raw + 5) % 7
    }

    /// Formats a date as a key string, e.g. `"2026-06-13"`.
    static func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Formats a date for the preview label.
    ///     Today → `"Today, June 14"`
    ///     Other → `"Monday, June 14"`
    static func dateLabel(for date: Date) -> String {
        let monthDay: String = {
            let f = DateFormatter()
            f.dateFormat = "MMMM d"
            return f.string(from: date)
        }()

        if calendar.isDateInToday(date) {
            return "Today, \(monthDay)"
        }

        let weekday: String = {
            let f = DateFormatter()
            f.dateFormat = "EEEE"
            return f.string(from: date)
        }()

        return "\(weekday), \(monthDay)"
    }

    /// Formats a time, e.g. `"08:30"`.
    static func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// Extracts a short snippet (first ~80 characters) from content text.
    static func snippet(from text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = 80
        if cleaned.count <= maxLength {
            return cleaned
        }
        return String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Human-readable month and year string, e.g. `"April 2025"`.
    static func monthYearString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    /// All weekday abbreviation strings (Mon–Sun).
    static let weekdayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
}

// MARK: - ConversationPreview

/// Preview data for a single day's conversation, displayed below the calendar grid.
struct ConversationPreview: Equatable {
    let dateKey: String
    let dateLabel: String
    let timestamp: String
    /// The text shown in the preview — either a conversation snippet or the first lines of a summary.
    let snippet: String
    /// Whether this date is today (conversation text is shown as-is).
    let isToday: Bool
}
