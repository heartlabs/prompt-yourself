import SwiftData
import SwiftUI

// MARK: - Root View

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: ConversationEngine
    @ObservedObject private var loc = LocalizationService.shared
    /// Whether to show the onboarding sheet (first launch).
    @State private var showOnboarding = !UserName.isSet

    /// Shared visual style for the daily conversation screen.
    private let style = ConversationStyle.journal

    // Services passed to sub-views.
    private let conversationService: ConversationService
    private let summaryService: SummaryService
    private let goalService: GoalService
    private let treeScoreService: TreeScoreService
    private let router: ModelRouter

    init(conversationService: ConversationService,
         summaryService: SummaryService,
         goalService: GoalService,
         treeScoreService: TreeScoreService,
         router: ModelRouter) {
        self.conversationService = conversationService
        self.summaryService = summaryService
        self.goalService = goalService
        self.treeScoreService = treeScoreService
        self.router = router

        _viewModel = StateObject(wrappedValue: ConversationEngine(
            configuration: .journal,
            conversationService: conversationService,
            summaryService: summaryService,
            goalService: goalService,
            router: router
        ))
    }

    /// Custom binding that detects re-taps on the same tab (TabView
    /// doesn't fire onChange for the currently-selected tab). The engine
    /// owns the selected tab; the binding forwards user taps as intents.
    private var tabSelection: Binding<AppTab> {
        Binding {
            viewModel.displayedTab
        } set: { newValue in
            if newValue == viewModel.displayedTab, newValue == .today {
                viewModel.todayTabTapped()
            }
            viewModel.displayedTab = newValue
        }
    }

    var body: some View {
        ZStack {
            tabs

            if let session = viewModel.activeComposition {
                ConversationModeView(session: session, style: style)
                    .transition(.opacity.combined(with: .scale(scale: 1.03)))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.phase)
    }

    private var tabs: some View {
        TabView(selection: tabSelection) {
            conversationTab
                .tabItem {
                    Label(loc.localized("today_tab"), systemImage: "leaf.fill")
                }
                .tag(AppTab.today)

            GoalsView()
                .tabItem {
                    Label(loc.localized("goals_tab"), systemImage: "target")
                }
                .tag(AppTab.goals)

            CalendarView(
                conversationService: conversationService,
                summaryService: summaryService,
                goalService: goalService,
                onSelectConversation: { dateKey in
                    viewModel.navigateFromCalendar(to: dateKey)
                }
            )
            .tabItem {
                Label(loc.localized("profile_tab"), systemImage: "person")
            }
            .tag(AppTab.calendar)

            TreeView(treeScoreService: treeScoreService)
                .tabItem {
                    Label(loc.localized("tree_tab"), image: "TreeGlyph")
                }
                .tag(AppTab.tree)
        }
        .tint(.sageGreen)
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(onComplete: {
                showOnboarding = false
            })
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                if viewModel.displayedTab == .today { viewModel.todayTabTapped() }
            case .background:
                viewModel.handleAppBackground()
            default:
                break
            }
        }
    }

    // MARK: - Conversation AppTab

    private var conversationTab: some View {
        ZStack {
            Color.warmIvory.ignoresSafeArea()

            if viewModel.messages.isEmpty {
                moodboardView
            } else {
                chatView
            }
        }
        .preferredColorScheme(.light)

        .alert(loc.localized("speech_recognition_alert"), isPresented: Binding(
            get: { viewModel.compositionError != nil },
            set: { presented in if !presented { viewModel.compositionError = nil } }
        )) {
            Button(loc.localized("ok_button"), role: .cancel) { }
        } message: {
            Text(viewModel.compositionError ?? "")
        }
    }
}

// MARK: - Moodboard (Empty State)

extension ContentView {
    private var moodboardView: some View {
        VStack(spacing: 0) {
            Spacer()

            // Greeting Header
            VStack(spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.s) {
                    Text(timeAwareGreeting())
                        .font(.echoLargeTitle)
                        .foregroundColor(.textPrimary)
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.sageGreen)
                        .offset(y: 2)
                }

                Text(loc.localized("how_are_you"))
                    .font(.echoBody)
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            if viewModel.isShowingPastConversation {
                // Past conversation — read-only, no mic
                Text(loc.localized("past_entry"))
                    .font(.echoSubheadline)
                    .foregroundColor(.textTertiary)
                    .padding(.top, Theme.Spacing.l)

                Spacer()
            } else {
                CompanionOrbView(
                    style: style,
                    diameter: Theme.Orb.moodboardDiameter,
                    isEnabled: !viewModel.isThinking,
                    showsMicGlyph: true,
                    action: { viewModel.beginComposition() }
                )

                // Instruction Text
                Text(loc.localized("tap_to_talk"))
                    .font(.echoSubheadline)
                    .foregroundColor(.textSecondary)

                Spacer()
                Spacer()
            }
        }
    }
}

// MARK: - Chat View (After First Interaction)

extension ContentView {
    private var chatView: some View {
        ConversationTranscriptView(
            messages: viewModel.messages,
            isThinking: viewModel.isThinking,
            isRemembering: viewModel.isRemembering,
            scrollIntent: viewModel.scrollIntent,
            style: style
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.isShowingPastConversation {
                // Past conversation — no orb, just a subtle hint
                Text(loc.localized("past_entry_readonly"))
                    .font(.echoMicroLabel)
                    .foregroundColor(.textTertiary)
                    .padding(.vertical, Theme.Spacing.m)
            } else {
                orbBar
            }
        }
    }

    /// The chat's single control: the resting companion orb, dead-center on
    /// the screen's axis. Only a short band is reserved at the bottom — the
    /// orb overflows above it, floating over the tail of the conversation, so
    /// the chat keeps the vertical space. The band's surface is solid ivory
    /// dissolving upward, so scrolled bubbles fade out softly underneath the
    /// orb instead of colliding with it. Until the orb is learned
    /// (`OrbCoachmark`), a small "Tap to talk" label sits beneath it.
    ///
    /// Contract: this band is applied as a `safeAreaInset` on the transcript
    /// (see `chatView`) — never a VStack row. Scroll insets and the
    /// scroll-behind-orb fade depend on that.
    private var orbBar: some View {
        Color.clear
            .frame(height: Theme.Orb.bandHeight)
            .overlay(alignment: .bottom) {
                VStack(spacing: Theme.Spacing.xs) {
                    CompanionOrbView(
                        style: style,
                        diameter: Theme.Orb.chatDiameter,
                        isEnabled: !viewModel.isThinking,
                        showsMicGlyph: true,
                        action: { viewModel.beginComposition() }
                    )

                    if !OrbCoachmark.isLearned {
                        Text(loc.localized("tap_to_talk"))
                            .font(.echoMicroLabel)
                            .foregroundColor(.textTertiary)
                    }
                }
                .padding(.bottom, Theme.Spacing.xs)
            }
            .background {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [Color.warmIvory.opacity(0), .warmIvory],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: Theme.Orb.bandFade)

                    Color.warmIvory
                }
                // Let the fade reach above the band, over the conversation.
                .padding(.top, -Theme.Orb.bandFade)
                .allowsHitTesting(false)
            }
    }
}

// MARK: - Onboarding View

/// Shown on first launch to capture the user's name for personalisation
/// and the preferred language.
struct OnboardingView: View {
    @ObservedObject private var loc = LocalizationService.shared
    @State private var name = ""
    @State private var selectedLanguage = AppLanguage.current
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "leaf.fill")
                .font(.system(size: 48))
                .foregroundColor(.sageGreen)

            Text(loc.localized("welcome_title"))
                .font(.title2.weight(.semibold))
                .foregroundColor(.taupeText)

            // Language picker
            VStack(spacing: 8) {
                Text(loc.localized("select_language"))
                    .font(.body)
                    .foregroundColor(.taupeText.opacity(0.65))

                Picker("", selection: $selectedLanguage) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .tint(.sageGreen)
                .onChange(of: selectedLanguage) { _, newLang in
                    LocalizationService.shared.setLanguage(newLang)
                }
            }

            Text(loc.localized("name_prompt"))
                .font(.body)
                .foregroundColor(.taupeText.opacity(0.65))

            TextField(loc.localized("name_placeholder"), text: $name)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .autocorrectionDisabled()
                .frame(maxWidth: 240)
                .onSubmit(submit)

            Button(loc.localized("get_started")) {
                submit()
            }
            .buttonStyle(.borderedProminent)
            .tint(.sageGreen)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.warmIvory)
        .preferredColorScheme(.light)
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Save the chosen language before the name
        LocalizationService.shared.setLanguage(selectedLanguage)
        UserName.save(trimmed)
        onComplete()
    }
}

#Preview {
    let container = try! ModelContainer(for: Conversation.self, Message.self, Goal.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let ctx = container.mainContext
    let convService = ConversationService(modelContext: ctx)
    let summService = SummaryService(conversationService: convService, kind: .journal)
    let goalService = GoalService(modelContext: ctx)
    let treeService = TreeScoreService(conversationService: convService)
    return ContentView(
        conversationService: convService,
        summaryService: summService,
        goalService: goalService,
        treeScoreService: treeService,
        router: ModelRouter(),

    )
    .modelContainer(container)
}
