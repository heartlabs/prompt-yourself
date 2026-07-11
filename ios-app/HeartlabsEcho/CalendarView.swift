import SwiftData
import SwiftUI

// MARK: - CalendarView

/// The calendar tab view containing the month grid and daily preview section.
struct CalendarView: View {
    @ObservedObject private var loc = LocalizationService.shared
    @StateObject private var viewModel = CalendarViewModel()
    @Environment(\.modelContext) private var modelContext

    /// Called when the user taps a daily preview card to switch to the
    /// appropriate conversation view and load the selected day's entries.
    var onSelectConversation: ((_ dateKey: String, _ kind: ConversationKind) -> Void)?
    @State private var showEditProfile = false
    @State private var selectedMemoryPath: String?
    @State private var showGallery = false
    @State private var scrollProxy: ScrollViewProxy?

    var body: some View {
        ZStack {
            Color.warmIvory.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        headerSection
                        .padding(.horizontal, 16)
                        .padding(.top, 32)
                        .padding(.bottom, 20)

                    statisticsSection
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)

                    calendarGrid
                        .padding(.horizontal, 16)

                    dailyPreviewSection
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                        .padding(.bottom, 12)

                    recentMemoriesSection
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                        .id("recent_memories")
                }
            }
            .onAppear { scrollProxy = proxy }
        }
        }
        .preferredColorScheme(.light)
        .task {
            viewModel.setup(with: modelContext)
        }
        .sheet(isPresented: $showEditProfile) {
            EditProfileView()
        }
        .fullScreenCover(isPresented: Binding(
            get: { selectedMemoryPath != nil },
            set: { if !$0 { selectedMemoryPath = nil } }
        )) {
            if let path = selectedMemoryPath {
                FullScreenPhotoView(path: path)
            }
        }
        .fullScreenCover(isPresented: $showGallery) {
            RecentMemoriesGalleryView()
        }
    }

    // MARK: - Header Section

    /// Shows the user's name left-aligned with a circular profile picture on
    /// the left. Tapping the circle (or pencil-in-circle if no photo is set)
    /// opens the profile editor. The name alone also opens the editor.
    @ViewBuilder
    private var headerSection: some View {
        if let name = UserName.current, !name.isEmpty {
            HStack(spacing: Theme.Spacing.m) {
                Button {
                    showEditProfile = true
                } label: {
                    ProfileCircleView(diameter: 56)
                }
                .buttonStyle(.plain)

                ScreenTitle(text: name, centered: false)

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Statistics Section

    private var statisticsSection: some View {
        HStack(spacing: 0) {
            statisticCell(
                icon: "leaf.fill",
                value: viewModel.conversationDaysCount,
                label: viewModel.conversationDaysCount == 1 ? loc.localized("journal_day") : loc.localized("journal_days")
            )

            divider

            statisticCell(
                icon: "waveform",
                value: viewModel.voiceMemoriesCount,
                label: viewModel.voiceMemoriesCount == 1 ? loc.localized("voice_memo") : loc.localized("voice_memos")
            )

            divider

            statisticCell(
                icon: "photo.fill",
                value: viewModel.photosCount,
                label: viewModel.photosCount == 1 ? loc.localized("photo") : loc.localized("photos"),
                onTap: {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        scrollProxy?.scrollTo("recent_memories", anchor: .top)
                    }
                }
            )

            divider

            statisticCell(
                icon: "target",
                value: viewModel.goalsCompletedCount,
                label: viewModel.goalsCompletedCount == 1 ? loc.localized("goal_done") : loc.localized("goals_done")
            )
        }
        .echoCard(padding: Theme.Spacing.l)
    }

    /// A single statistic cell inside the statistics row.
    /// Uses fixed heights for icon, number, and label so all cells stay aligned.
    /// Pass `onTap` to make the cell tappable (e.g. photos → scroll to memories).
    private func statisticCell(icon: String, value: Int, label: String, onTap: (() -> Void)? = nil) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundColor(.sageGreen.opacity(0.6))
                .frame(height: 34)
                .padding(.bottom, 6)

            Text("\(value)")
                .font(.echoNumber)
                .foregroundColor(.sageGreen)
                .frame(height: 36)

            Text(label)
                .font(.echoMicroLabel)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 34)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }

    /// A thin vertical separator between statistic cells.
    private var divider: some View {
        Rectangle()
            .fill(Color.softTaupe.opacity(0.3))
            .frame(width: 1, height: 44)
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
                .font(.echoTitle)
                .foregroundColor(.textPrimary)

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
            let labels = CalendarViewModel.weekdayLabels
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.echoCaption)
                    .foregroundColor(.textTertiary)
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
        case .loaded(let previews):
            if let preview = previews.first {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    SectionTitle(text: preview.dateLabel)

                    Button(action: {
                        onSelectConversation?(preview.dateKey, .journal)
                    }) {
                        previewCard(preview: preview)
                    }
                    .buttonStyle(.plain)
                }
            }

        case .generating:
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                SectionTitle(text: previewDateLabel)

                // Loading card with animated circles
                HStack {
                    Spacer()
                    LoadingCirclesIndicator()
                        .padding(.vertical, Theme.Spacing.l)
                    Spacer()
                }
                .echoCard()
            }

        case .empty:
            // Muted empty state when no day is selected or no entry exists
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                SectionTitle(text: emptyDateLabel)

                HStack {
                    Spacer()
                    Text(loc.localized("tap_day_to_view"))
                        .font(.echoSubheadline)
                        .foregroundColor(.textTertiary)
                        .padding(.vertical, Theme.Spacing.l)
                    Spacer()
                }
                .echoCard()
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
        HStack(spacing: Theme.Spacing.l) {
            // Left side: Text content.
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(preview.timestamp)
                    .font(.echoCaption)
                    .foregroundColor(.textSecondary)

                Text(preview.isToday ? loc.localized("todays_journal") : loc.localized("journal_entry"))
                    .font(.echoCardTitle)
                    .foregroundColor(.textPrimary)

                // Scrollable summary — uses fixedSize so the ScrollView reports its
                // content's natural height for short summaries, with a max cap so
                // long summaries get a scroll bar instead of expanding the card.
                ScrollView(.vertical) {
                    Text(preview.snippet)
                        .font(.echoSubheadline)
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: 250)
            }

            Spacer(minLength: Theme.Spacing.m)

            // Right side: Journal icon
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Color.sageGreen.opacity(0.15))
                .frame(width: 64, height: 80)
                .overlay(
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.sageGreen.opacity(0.5))
                )
        }
        .echoCard()
    }

    // MARK: - Recent Memories

    /// A horizontal gallery of the most recent photos shared in conversations.
    /// Tapping the title opens the full gallery; tapping a thumbnail opens
    /// that photo fullscreen.
    @ViewBuilder
    private var recentMemoriesSection: some View {
        if !viewModel.recentPhotos.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Button {
                    showGallery = true
                } label: {
                    HStack(spacing: Theme.Spacing.s) {
                        SectionTitle(text: loc.localized("recent_memories"))
                        Spacer(minLength: 0)
                        HStack(spacing: 4) {
                            Text(loc.localized("see_all"))
                                .font(.echoSubheadline)
                                .foregroundColor(.sageGreen)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.sageGreen)
                        }
                    }
                }
                .buttonStyle(.plain)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.s) {
                        ForEach(viewModel.recentPhotos) { photo in
                            Button {
                                selectedMemoryPath = photo.path
                            } label: {
                                if let uiImage = ImageUtils.loadImage(relativePath: photo.path) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 100, height: 100)
                                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 108)
            }
        }
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

            // Entry indicator — always occupies the same height so rows with and
            // without a leaf stay perfectly aligned.
            Group {
                if hasEntry {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.sageGreen.opacity(isSelected ? 1.0 : 0.55))
                } else {
                    Color.clear
                }
            }
            .frame(height: 12)
            .offset(y: -2)
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

// MARK: - Recent Memories Gallery

/// A full-screen gallery showing all photo memories in a vertical grid with
/// lazy loading. Tapping a thumbnail opens it fullscreen.
struct RecentMemoriesGalleryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var allPhotos: [MemoryPhoto] = []
    @State private var selectedPhotoPath: String?

    /// Three columns for the grid.
    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(allPhotos) { photo in
                        Button {
                            selectedPhotoPath = photo.path
                        } label: {
                            if let uiImage = ImageUtils.loadImage(relativePath: photo.path) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(height: 130)
                                    .clipped()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .background(Color.warmIvory)
            .navigationTitle("All Memories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.taupeText)
                    }
                }
            }
        }
        .preferredColorScheme(.light)
        .task {
            loadPhotos()
        }
        .fullScreenCover(isPresented: Binding(
            get: { selectedPhotoPath != nil },
            set: { if !$0 { selectedPhotoPath = nil } }
        )) {
            if let path = selectedPhotoPath {
                FullScreenPhotoView(path: path)
            }
        }
    }

    private func loadPhotos() {
        let predicate = #Predicate<Message> { $0.contentType == "image" }
        let descriptor = FetchDescriptor<Message>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let messages = (try? modelContext.fetch(descriptor)) ?? []
        allPhotos = messages.compactMap { msg in
            guard let conv = msg.conversation else { return nil }
            return MemoryPhoto(path: msg.content, dateKey: conv.dateKey, timestamp: msg.timestamp)
        }
    }
}

// MARK: - Preview

#Preview {
    CalendarView()
}
