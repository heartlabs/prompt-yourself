import Foundation
import SwiftData
import SwiftUI

// MARK: - Preview State

/// The state of the daily preview section below the calendar grid.
enum PreviewState: Equatable {
    /// No conversation exists for the selected date.
    case empty
    /// A preview is ready to display.
    case loaded([ConversationPreview])
    /// A summary is being generated for the selected date.
    case generating
}

// MARK: - MemoryPhoto

/// A photo attached to a conversation message, used in the recent memories gallery.
struct MemoryPhoto: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let dateKey: String
    let timestamp: Date
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

    // MARK: - Statistics

    /// Total number of unique days the user has journaled with the agent.
    var conversationDaysCount: Int {
        datesWithEntries.count
    }

    /// Total number of user messages across all conversations.
    var voiceMemoriesCount: Int {
        let predicate = #Predicate<Message> { $0.role == "user" }
        let descriptor = FetchDescriptor<Message>(predicate: predicate)
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    /// Total number of image messages across all conversations.
    var photosCount: Int {
        let predicate = #Predicate<Message> { $0.contentType == "image" }
        let descriptor = FetchDescriptor<Message>(predicate: predicate)
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    /// Total number of completed goals (progress >= target).
    var goalsCompletedCount: Int {
        goalService.closedGoals().count
    }

    /// Recent photo memories, sorted newest-first.
    @Published var recentPhotos: [MemoryPhoto] = []

    /// Maximum number of recent photos to show.
    private static let maxRecentPhotos = 10

    /// Loads the most recent image messages from all conversations.
    func loadRecentPhotos() {
        let predicate = #Predicate<Message> { $0.contentType == "image" }
        var descriptor = FetchDescriptor<Message>(predicate: predicate, sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = Self.maxRecentPhotos
        let messages = (try? modelContext.fetch(descriptor)) ?? []
        recentPhotos = messages.compactMap { msg in
            guard let conv = msg.conversation else { return nil }
            return MemoryPhoto(path: msg.content, dateKey: conv.dateKey, timestamp: msg.timestamp)
        }
    }

    /// Loads all image messages from all conversations, sorted newest-first.
    func loadAllPhotos() -> [MemoryPhoto] {
        let predicate = #Predicate<Message> { $0.contentType == "image" }
        let descriptor = FetchDescriptor<Message>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let messages = (try? modelContext.fetch(descriptor)) ?? []
        return messages.compactMap { msg in
            guard let conv = msg.conversation else { return nil }
            return MemoryPhoto(path: msg.content, dateKey: conv.dateKey, timestamp: msg.timestamp)
        }
    }

    // MARK: - Services

    private let modelContext: ModelContext
    private let conversationService: ConversationService
    private let summaryService: SummaryService
    private let goalService: GoalService

    /// The in-flight preview generation task. Cancelled when the user selects
    /// a different date, so a stale result can never overwrite `previewState`.
    private var previewTask: Task<Void, Never>?

    // MARK: - Init

    init(conversationService: ConversationService,
         summaryService: SummaryService,
         goalService: GoalService,
         modelContext: ModelContext) {
        self.currentMonth = Self.startOfMonth(Date())
        self.selectedDate = nil
        self.conversationService = conversationService
        self.summaryService = summaryService
        self.goalService = goalService
        self.modelContext = modelContext

        loadDatesWithEntries()
        loadRecentPhotos()

        // Auto-select today so the preview card appears immediately.
        selectDate(Date())
    }

    /// Refreshes the set of date keys that have entries.
    func loadDatesWithEntries() {
        datesWithEntries = Set(conversationService.fetchAllDateKeys(kind: .journal))
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
    ///
    /// Cancels any in-flight preview generation for the previous date so a
    /// stale result can never overwrite `previewState` after a rapid tap.
    func selectDate(_ date: Date) {
        selectedDate = date
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            await self?.refreshPreview()
        }
    }

    // MARK: - Preview Data

    /// Refreshes the preview for the currently selected date.
    ///
    /// Sets `previewState` to `.generating` before awaiting the preview build
    /// so the view shows a loading indicator during on-the-fly summary generation
    /// for past dates. After the await, checks for cancellation so a stale
    /// result from a superseded selection can never be written.
    ///
    /// Preview content decision tree:
    /// - **Today**: shows the first sentences of the conversation.
    /// - **Has summary (current version)**: shows the first lines of the summary.
    /// - **Has summary (outdated)**: shows the old summary immediately,
    ///   regenerates in background.
    /// - **No summary**: generates on the fly (loading indicator shown);
    ///   falls back to conversation text if generation fails.
    private func refreshPreview() async {
        guard let date = selectedDate else {
            previewState = .empty
            return
        }

        let dateKey = DateKey.from(date)
        previewState = .generating

        let result = await buildPreview(for: date, dateKey: dateKey, service: conversationService)

        guard !Task.isCancelled else { return }

        if let preview = result {
            previewState = .loaded([preview])
        } else {
            previewState = .empty
        }
    }

    /// Builds a preview for the given date.
    /// Returns `nil` if no conversation exists for that date.
    private func buildPreview(
        for date: Date,
        dateKey: String,
        service: ConversationService
    ) async -> ConversationPreview? {
        guard let conversation = service.loadConversation(dateKey: dateKey, kind: .journal) else {
            return nil
        }

        let sortedMessages = conversation.messages.sorted(by: { $0.timestamp < $1.timestamp })
        let firstMessage = sortedMessages.first(where: { $0.role == "user" }) ?? sortedMessages.first
        let timestamp = firstMessage.map { Self.timeString(from: $0.timestamp) } ?? ""
        let snippetText: String = {
            guard let first = firstMessage else { return "" }
            if first.contentType == "image" {
                return "[Image]"
            }
            return first.content
        }()
        let conversationSnippet = Self.snippet(from: snippetText)
        let isToday = Calendar.current.isDateInToday(date)

        // Today or active past session — show conversation text directly.
        if isToday || conversation.hasRecentActivity {
            return ConversationPreview(
                dateKey: dateKey,
                dateLabel: Self.dateLabel(for: date),
                timestamp: timestamp,
                snippet: conversationSnippet,
                isToday: isToday
            )
        }

        if let summary = conversation.summary {
            // Regenerate outdated summary in background (fire-and-forget).
            if summaryService.isOutdated(for: dateKey) {
                Task {
                    await summaryService.regenerateIfOutdated(for: dateKey)
                }
            }
            return ConversationPreview(
                dateKey: dateKey,
                dateLabel: Self.dateLabel(for: date),
                timestamp: timestamp,
                snippet: Self.snippet(from: summary),
                isToday: false
            )
        }

        // No summary yet — generate on the fly if not already pending.
        if summaryService.isGenerationPending(for: dateKey) {
            return nil
        }

        if let generatedSummary = await summaryService.generateSummaryIfMissing(for: dateKey) {
            // After the await, bail out if the task was cancelled or the user
            // has already selected a different date.
            guard !Task.isCancelled,
                  let selected = selectedDate,
                  DateKey.from(selected) == dateKey else { return nil }

            return ConversationPreview(
                dateKey: dateKey,
                dateLabel: Self.dateLabel(for: date),
                timestamp: timestamp,
                snippet: Self.snippet(from: generatedSummary),
                isToday: false
            )
        }

        // Generation failed — fall back to raw conversation text.
        return ConversationPreview(
            dateKey: dateKey,
            dateLabel: Self.dateLabel(for: date),
            timestamp: timestamp,
            snippet: conversationSnippet,
            isToday: false
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

    /// Extracts a snippet (first 5000 characters) from content text.
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
        formatter.locale = AppLanguage.current.locale
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    /// All weekday abbreviation strings, localised (Mon–Sun / Mo–So / Пн–Вс).
    static var weekdayLabels: [String] {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        let symbols = formatter.shortStandaloneWeekdaySymbols ?? []
        // Gregorian calendar: weekday 1 = Sunday, so reorder to Monday-first.
        // symbols indices: [0]=Sun, [1]=Mon, [2]=Tue, [3]=Wed, [4]=Thu, [5]=Fri, [6]=Sat
        if symbols.count == 7 {
            return [symbols[1], symbols[2], symbols[3], symbols[4], symbols[5], symbols[6], symbols[0]]
        }
        return ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    }
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
