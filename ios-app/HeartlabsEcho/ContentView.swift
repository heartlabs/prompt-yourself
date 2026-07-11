import PhotosUI
import SwiftData
import SwiftUI

// MARK: - Root View

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = ConversationEngine(configuration: .journal)
    @State private var selectedTab = 0
    /// Prevents `resetToToday` from overriding a conversation that was just
    /// loaded from the calendar preview.
    @State private var isNavigatingFromCalendar = false
    /// Whether to show the onboarding sheet (first launch).
    @State private var showOnboarding = !UserName.isSet

    /// Shared visual style for the daily conversation screen.
    private let style = ConversationStyle.journal

    /// Custom binding that detects when the "Today" tab is tapped
    /// even if it's already selected (TabView doesn't fire onChange for that).
    private var tabBinding: Binding<Int> {
        Binding {
            selectedTab
        } set: { newValue in
            if newValue == selectedTab && newValue == 0 {
                // User tapped "Today" while already on it → reset to today
                isNavigatingFromCalendar = false
                viewModel.resetToToday()
            } else if newValue == 0 && !isNavigatingFromCalendar {
                // Switching to Today from another tab (not from calendar)
                viewModel.resetToToday()
            }
            isNavigatingFromCalendar = false
            selectedTab = newValue
        }
    }

    var body: some View {
        TabView(selection: tabBinding) {
            // Tab 0: Today's conversation
            conversationTab
                .tabItem {
                    Label("Today", systemImage: "leaf.fill")
                }
                .tag(0)

            // Tab 1: Goals overview
            GoalsView()
                .tabItem {
                    Label("Goals", systemImage: "target")
                }
                .tag(1)

            // Tab 2: Calendar / Journal history
            CalendarView(
                onSelectConversation: { dateKey, _ in
                    isNavigatingFromCalendar = true
                    viewModel.loadConversation(for: dateKey)
                    selectedTab = 0
                }
            )
            .tabItem {
                Label("Profile", systemImage: "person")
            }
                .tag(2)

            // Tab 3: "Your Life" tree
            TreeView()
                .tabItem {
                    Label("Tree", image: "TreeGlyph")
                }
                .tag(3)
        }
        .tint(.sageGreen)
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(onComplete: {
                showOnboarding = false
            })
        }
        .onChange(of: selectedTab) { _, newTab in
            // Stop recording when navigating away from the conversation tab.
            if newTab != 0 && viewModel.recognizer.isRecording {
                viewModel.toggleRecording()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // App came to foreground — scroll to bottom if on an active conversation.
                if selectedTab == 0 {
                    viewModel.requestScrollToBottomIfActive()
                }
            case .background:
                // Stop recording and send partial transcript when app goes to background
                // (lock button, app switcher, phone call, etc.).
                viewModel.stopRecordingOnBackground()
            default:
                break
            }
        }
    }

    // MARK: - Conversation Tab

    private var conversationTab: some View {
        ZStack {
            Color.warmIvory.ignoresSafeArea()

            if viewModel.messages.isEmpty && !viewModel.recognizer.isRecording {
                moodboardView
            } else {
                chatView
            }
        }
        .preferredColorScheme(.light)
        .task {
            viewModel.setupPersistence(with: modelContext)
            // Remove stale dream data from a removed feature.
            let service = ConversationService(modelContext: modelContext)
            service.deleteAllDreamConversations()
        }
        .alert("Speech Recognition", isPresented: Binding(
            get: { viewModel.recognizer.recognitionError != nil },
            set: { presented in if !presented { viewModel.recognizer.recognitionError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.recognizer.recognitionError ?? "")
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

                Text("How are you feeling today?")
                    .font(.echoBody)
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            if viewModel.isShowingPastConversation {
                // Past conversation — read-only, no mic
                Text("Past entry")
                    .font(.echoSubheadline)
                    .foregroundColor(.textTertiary)
                    .padding(.top, Theme.Spacing.l)

                Spacer()
            } else {
                MicButton(
                    style: style,
                    size: .large,
                    isRecording: viewModel.recognizer.isRecording,
                    isEnabled: !viewModel.isThinking,
                    action: { viewModel.toggleRecording() }
                )

                // Instruction Text
                Text("Tap to speak")
                    .font(.echoSubheadline)
                    .foregroundColor(.textSecondary)
                    .padding(.top, Theme.Spacing.l)

                Spacer()
                Spacer()
            }
        }
    }
}

// MARK: - Chat View (After First Interaction)

extension ContentView {
    private var chatView: some View {
        VStack(spacing: 0) {
            ConversationTranscriptView(
                messages: viewModel.messages,
                isRecording: viewModel.recognizer.isRecording,
                transcript: viewModel.recognizer.transcript,
                isThinking: viewModel.isThinking,
                isRemembering: viewModel.isRemembering,
                shouldAutoScroll: viewModel.shouldAutoScroll,
                scrollToBottomCount: viewModel.scrollToBottomCount,
                style: style
            )

            if viewModel.isShowingPastConversation {
                // Past conversation — no mic, just a subtle hint
                Text("Past entry — read only")
                    .font(.echoMicroLabel)
                    .foregroundColor(.textTertiary)
                    .padding(.vertical, Theme.Spacing.m)
            } else {
                inputBar
            }
        }
    }

    /// A defined input bar: the mic is the centered primary action, with the
    /// photo picker as a smaller secondary control on the left. A hairline
    /// separator distinguishes it from the transcript above.
    private var inputBar: some View {
        // Photo (secondary) clustered directly beside the mic (primary), the
        // pair centered together so neither control floats alone.
        HStack(spacing: Theme.Spacing.l) {
            if !viewModel.messages.isEmpty {
                PhotoButton(
                    isEnabled: !viewModel.isThinking
                ) { image in
                    if let path = ImageUtils.saveImage(image) {
                        viewModel.sendImage(relativePath: path)
                    }
                }
            }

            MicButton(
                style: style,
                size: .compact,
                isRecording: viewModel.recognizer.isRecording,
                isEnabled: !viewModel.isThinking,
                action: { viewModel.toggleRecording() }
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.s)
        .background(
            Color.warmIvory
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.cardBorder).frame(height: 1)
                }
        )
    }
}

// MARK: - Onboarding View

/// Shown on first launch to capture the user's name for personalisation.
struct OnboardingView: View {
    @State private var name = ""
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "leaf.fill")
                .font(.system(size: 48))
                .foregroundColor(.sageGreen)

            Text("Welcome to Heartlabs Echo")
                .font(.title2.weight(.semibold))
                .foregroundColor(.taupeText)

            Text("What should I call you?")
                .font(.body)
                .foregroundColor(.taupeText.opacity(0.65))

            TextField("Your name", text: $name)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
                .onSubmit(submit)

            Button("Get Started") {
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
        UserName.save(trimmed)
        onComplete()
    }
}

#Preview {
    ContentView()
}
