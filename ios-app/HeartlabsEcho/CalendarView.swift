import SwiftData
import SwiftUI

// MARK: - CalendarView

/// The calendar tab view containing the month grid and daily preview section.
struct CalendarView: View {
    @StateObject private var viewModel = CalendarViewModel()
    @Environment(\.modelContext) private var modelContext

    /// Called when the user taps the daily preview card to switch back to
    /// the conversation view and load the selected day's entries.
    var onSelectConversation: ((String) -> Void)?

    var body: some View {
        ZStack {
            Color.warmIvory.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    calendarGrid
                        .padding(.horizontal, 16)
                        .padding(.top, 20)

                    Spacer().frame(height: 20)

                    dailyPreviewSection
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                }
            }
            .scrollDisabled(true)
        }
        .preferredColorScheme(.light)
        .task {
            viewModel.setup(with: modelContext)
        }
    }

    // MARK: - Calendar Grid

    private var calendarGrid: some View {
        VStack(spacing: 0) {
            monthHeader
                .padding(.bottom, 24)

            weekdayRow
                .padding(.bottom, 14)

            daysGrid
        }
    }

    // MARK: Month Header

    private var monthHeader: some View {
        HStack {
            Button(action: { viewModel.goToPreviousMonth() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.taupeText.opacity(0.6))
            }

            Spacer()

            Text(CalendarViewModel.monthYearString(for: viewModel.currentMonth))
                .font(.system(size: 26, weight: .medium, design: .serif))
                .foregroundColor(.taupeText)

            Spacer()

            Button(action: { viewModel.goToNextMonth() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(viewModel.canGoNext ? .taupeText.opacity(0.6) : .taupeText.opacity(0.2))
            }
            .disabled(!viewModel.canGoNext)
        }
    }

    // MARK: Weekday Row

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(CalendarViewModel.weekdayLabels, id: \.self) { label in
                Text(label)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundColor(.taupeText.opacity(0.45))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Days Grid

    private var daysGrid: some View {
        let days = buildCalendarDays()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(days) { day in
                if day.isPlaceholder {
                    Color.clear
                        .aspectRatio(1.0, contentMode: .fit)
                } else {
                    CalendarDayCell(
                        day: day.day,
                        isSelected: day.isSelected,
                        hasEntry: day.hasEntry,
                        isToday: day.isToday
                    )
                    .aspectRatio(1.0, contentMode: .fit)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let date = day.date, !CalendarViewModel.isFuture(date) {
                            viewModel.selectDate(date)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Daily Preview Section

    @ViewBuilder
    private var dailyPreviewSection: some View {
        switch viewModel.previewState {
        case .loaded(let preview):
            VStack(alignment: .leading, spacing: 10) {
                // Section label
                Text(preview.dateLabel)
                    .font(.system(size: 20, weight: .semibold, design: .default))
                    .foregroundColor(.taupeText)

                // Preview card (tappable → load conversation)
                Button(action: {
                    onSelectConversation?(preview.dateKey)
                }) {
                    previewCard(preview: preview)
                }
                .buttonStyle(.plain)
            }

        case .generating:
            VStack(alignment: .leading, spacing: 10) {
                Text(previewDateLabel)
                    .font(.system(size: 20, weight: .semibold, design: .default))
                    .foregroundColor(.taupeText)

                // Loading card with animated circles
                HStack {
                    Spacer()
                    LoadingCirclesIndicator()
                        .padding(.vertical, 32)
                    Spacer()
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.softTaupe.opacity(0.3), lineWidth: 1)
                )
            }

        case .empty:
            // Muted empty state when no day is selected or no entry exists
            VStack(alignment: .leading, spacing: 10) {
                Text(emptyDateLabel)
                    .font(.system(size: 20, weight: .semibold, design: .default))
                    .foregroundColor(.taupeText)

                HStack {
                    Spacer()
                    Text("Tap a day to view its entry")
                        .font(.system(size: 14, weight: .regular, design: .default))
                        .foregroundColor(.taupeText.opacity(0.35))
                        .padding(.vertical, 32)
                    Spacer()
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.softTaupe.opacity(0.25))
                )
            }
        }
    }

    /// The date label shown while a summary is being generated.
    private var previewDateLabel: String {
        if let selected = viewModel.selectedDate {
            return CalendarViewModel.dateLabel(for: selected)
        }
        return CalendarViewModel.dateLabel(for: Date())
    }

    /// The date label for the empty state — shows the selected date's label
    /// if one is selected, otherwise today's.
    private var emptyDateLabel: String {
        if let selected = viewModel.selectedDate {
            return CalendarViewModel.dateLabel(for: selected)
        }
        return CalendarViewModel.dateLabel(for: Date())
    }

    // MARK: Preview Card

    private func previewCard(preview: ConversationPreview) -> some View {
        HStack(spacing: 16) {
            // Left side: Text content
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.timestamp)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundColor(.taupeText.opacity(0.5))

                Text(preview.isToday ? "Today's Entry" : "Journal Entry")
                    .font(.system(size: 16, weight: .semibold, design: .default))
                    .foregroundColor(.taupeText)

                Text(preview.snippet)
                    .font(.system(size: 14, weight: .regular, design: .default))
                    .foregroundColor(.taupeText.opacity(0.65))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 12)

            // Right side: Image placeholder
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.softTaupe.opacity(0.35))
                .frame(width: 64, height: 80)
                .overlay(
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.sageGreen.opacity(0.35))
                )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.softTaupe.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Calendar Day Model

    /// A single cell in the calendar grid.
    private struct CalendarDay: Identifiable {
        let id: Int
        let day: Int
        let date: Date?
        let isPlaceholder: Bool
        let isSelected: Bool
        let hasEntry: Bool
        let isToday: Bool
    }

    /// Builds the array of calendar days (including leading placeholders).
    private func buildCalendarDays() -> [CalendarDay] {
        let month = viewModel.currentMonth
        let daysInMonth = CalendarViewModel.daysInMonth(month)
        let offset = CalendarViewModel.firstWeekdayOffset(month)
        let today = Date()
        let todayKey = CalendarViewModel.dateKey(for: today)
        let selectedKey = viewModel.selectedDate.map { CalendarViewModel.dateKey(for: $0) }

        var days: [CalendarDay] = []
        var idCounter = 0

        // Leading empty cells
        for _ in 0..<offset {
            days.append(CalendarDay(
                id: idCounter,
                day: 0,
                date: nil,
                isPlaceholder: true,
                isSelected: false,
                hasEntry: false,
                isToday: false
            ))
            idCounter += 1
        }

        // Actual day cells
        for day in 1...daysInMonth {
            let date = Calendar.current.date(from: DateComponents(
                year: Calendar.current.component(.year, from: month),
                month: Calendar.current.component(.month, from: month),
                day: day
            ))!

            let dateKey = CalendarViewModel.dateKey(for: date)
            let isSelected = selectedKey == dateKey
            let hasEntry = viewModel.datesWithEntries.contains(dateKey)
            let isToday = dateKey == todayKey

            days.append(CalendarDay(
                id: idCounter,
                day: day,
                date: date,
                isPlaceholder: false,
                isSelected: isSelected,
                hasEntry: hasEntry,
                isToday: isToday
            ))
            idCounter += 1
        }

        return days
    }
}

// MARK: - CalendarDayCell

/// A single day cell in the calendar grid.
private struct CalendarDayCell: View {
    let day: Int
    let isSelected: Bool
    let hasEntry: Bool
    let isToday: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Today outline (unselected) — subtle ring around the number
                if isToday && !isSelected {
                    Circle()
                        .stroke(Color.sageGreen.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 44, height: 44)
                }

                // Selected circle background (takes precedence)
                if isSelected {
                    Circle()
                        .fill(Color.sageGreen)
                        .frame(width: 44, height: 44)
                }

                // Day number
                Text("\(day)")
                    .font(.system(size: 20, weight: isSelected || isToday ? .semibold : .regular, design: .default))
                    .foregroundColor(textColor)
            }
            .frame(height: 44)

            // Leaf indicator for days with entries
            if hasEntry {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.sageGreen.opacity(isSelected ? 1.0 : 0.55))
                    .frame(height: 10)
                    .offset(y: -2)
            } else {
                // Spacer to maintain alignment
                Color.clear
                    .frame(height: 10)
            }
        }
    }

    private var textColor: Color {
        if isSelected {
            return .white
        }
        if isToday {
            return .sageGreen
        }
        return .taupeText.opacity(0.7)
    }
}

// MARK: - LoadingCirclesIndicator

/// A compact pulsing-circles animation shown while a summary is being generated.
private struct LoadingCirclesIndicator: View {
    @State private var activeIndex = 0
    let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< 3) { i in
                Circle()
                    .fill(Color.sageGreen)
                    .frame(width: 10, height: 10)
                    .opacity(activeIndex == i ? 1.0 : 0.25)
                    .scaleEffect(activeIndex == i ? 1.0 : 0.7)
                    .animation(.easeInOut(duration: 0.25), value: activeIndex)
            }
        }
        .onReceive(timer) { _ in
            activeIndex = (activeIndex + 1) % 3
        }
    }
}

// MARK: - Preview

#Preview {
    CalendarView()
}
