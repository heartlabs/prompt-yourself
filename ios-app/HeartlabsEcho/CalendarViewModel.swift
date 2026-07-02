import Foundation
import SwiftData
import SwiftUI

// MARK: - Preview State

/// The state of the daily preview section below the calendar grid.
enum PreviewState: Equatable {
    /// No conversation exists for the selected date.
    case empty
    /// One or more previews are ready to display (journal, dream, or both).
    case loaded([ConversationPreview])
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

    /// Date keys (e.g. `"2026-06-13"`) that have at least one journal conversation.
    @Published var datesWithEntries: Set<String> = []
    /// Date keys that have at least one dream conversation.
    @Published var dreamDatesWithEntries: Set<String> = []

    // MARK: - Private State

    private var conversationService: ConversationService?
    private var summaryService: SummaryService?
    private var dreamSummaryService: SummaryService?
    private var hasSetup = false

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

        let summ = SummaryService(conversationService: service, kind: .journal)
        summaryService = summ

        let dreamSumm = SummaryService(conversationService: service, kind: .dream)
        dreamSummaryService = dreamSumm

        loadDatesWithEntries()

        // Auto-select today so the preview card appears immediately.
        selectDate(Date())
    }

    /// Refreshes the set of date keys that have entries (both journal and dream).
    func loadDatesWithEntries() {
        guard let service = conversationService else { return }
        datesWithEntries = Set(service.fetchAllDateKeys(kind: .journal))
        dreamDatesWithEntries = Set(service.fetchAllDateKeys(kind: .dream))
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
    /// - **Has summary (current version)**: shows the first lines of the summary.
    /// - **Has summary (outdated)**: shows the old summary immediately, regenerates in background.
    /// - **No summary**: triggers on-the-fly generation with a loading indicator;
    ///   falls back to conversation text if generation fails.
    private func refreshPreview() async {
        guard let date = selectedDate, let service = conversationService else {
            previewState = .empty
            return
        }

        let dateKey = Self.dateKey(for: date)

        // Collect previews for both kinds in parallel.
        async let journalPreview = self.preview(
            for: .journal, date: date, dateKey: dateKey,
            service: service, summ: summaryService
        )
        async let dreamPreview = self.preview(
            for: .dream, date: date, dateKey: dateKey,
            service: service, summ: dreamSummaryService
        )

        let previews = await [journalPreview, dreamPreview].compactMap { $0 }

        if previews.isEmpty {
            previewState = .empty
        } else {
            previewState = .loaded(previews)
        }
    }

    /// Builds a preview for a single conversation kind on the given date.
    /// Returns `nil` if no conversation exists for that kind on that date.
    private func preview(
        for kind: ConversationKind,
        date: Date,
        dateKey: String,
        service: ConversationService,
        summ: SummaryService?
    ) async -> ConversationPreview? {
        guard let conversation = service.loadConversation(dateKey: dateKey, kind: kind) else {
            return nil
        }

        let sortedMessages = conversation.messages.sorted(by: { $0.timestamp < $1.timestamp })
        let firstMessage = sortedMessages.first(where: { $0.role == "user" }) ?? sortedMessages.first
        let timestamp = firstMessage.map { Self.timeString(from: $0.timestamp) } ?? ""
        let conversationSnippet = firstMessage.map { Self.snippet(from: $0.content) } ?? ""
        let isToday = Calendar.current.isDateInToday(date)

        // Today or active past session — show conversation text directly.
        if isToday || conversation.hasRecentActivity {
            return ConversationPreview(
                dateKey: dateKey,
                dateLabel: Self.dateLabel(for: date),
                timestamp: timestamp,
                snippet: conversationSnippet,
                isToday: isToday,
                kind: kind
            )
        }

        guard let summ else { return nil }

        if let summary = conversation.summary {
            // Regenerate outdated summary in background (fire-and-forget).
            if summ.isOutdated(for: dateKey) {
                Task {
                    await summ.regenerateIfOutdated(for: dateKey)
                }
            }
            return ConversationPreview(
                dateKey: dateKey,
                dateLabel: Self.dateLabel(for: date),
                timestamp: timestamp,
                snippet: Self.snippet(from: summary),
                isToday: false,
                kind: kind
            )
        }

        // No summary yet — generate on the fly if not already pending.
        if summ.isGenerationPending(for: dateKey) {
            return nil
        }

        if let generatedSummary = await summ.generateSummaryIfMissing(for: dateKey) {
            return ConversationPreview(
                dateKey: dateKey,
                dateLabel: Self.dateLabel(for: date),
                timestamp: timestamp,
                snippet: Self.snippet(from: generatedSummary),
                isToday: false,
                kind: kind
            )
        }

        // Generation failed — fall back to raw conversation text.
        return ConversationPreview(
            dateKey: dateKey,
            dateLabel: Self.dateLabel(for: date),
            timestamp: timestamp,
            snippet: conversationSnippet,
            isToday: false,
            kind: kind
        )
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
        let maxLength = 5000
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
    /// Which kind of conversation this preview belongs to.
    let kind: ConversationKind
}
