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

            // Tab 1: Calendar / Journal history
            CalendarView(
                onSelectConversation: { dateKey, _ in
                    isNavigatingFromCalendar = true
                    viewModel.loadConversation(for: dateKey)
                    selectedTab = 0
                }
            )
            .tabItem {
                Label("Journal", systemImage: "calendar")
            }
            .tag(1)

            // Tab 2: "Your Life" tree
            TreeView()
                .tabItem {
                    Label("Tree", systemImage: "tree")
                }
                .tag(2)
        }
        .tint(.sageGreen)
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
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Text(timeAwareGreeting())
                        .font(.system(size: 34, weight: .medium, design: .serif))
                        .foregroundColor(.taupeText)
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.sageGreen)
                        .offset(y: 2)
                }

                Text("How are you feeling today?")
                    .font(.system(size: 16, weight: .regular, design: .default))
                    .foregroundColor(.taupeText.opacity(0.65))
            }

            Spacer()

            if viewModel.isShowingPastConversation {
                // Past conversation — read-only, no mic
                Text("Past entry")
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundColor(.taupeText.opacity(0.4))
                    .padding(.top, 20)

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
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundColor(.taupeText.opacity(0.55))
                    .padding(.top, 20)

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
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundColor(.taupeText.opacity(0.35))
                    .padding(.vertical, 12)
            } else {
                // Compact Mic Button (Chat Mode)
                VStack(spacing: 6) {
                    MicButton(
                        style: style,
                        size: .compact,
                        isRecording: viewModel.recognizer.isRecording,
                        isEnabled: !viewModel.isThinking,
                        action: { viewModel.toggleRecording() }
                    )

                    Text(viewModel.recognizer.isRecording ? "Recording..." : "Tap to speak")
                        .font(.system(size: 12, weight: .regular, design: .default))
                        .foregroundColor(.taupeText.opacity(0.5))
                }
                .padding(.vertical, 8)
            }
        }
    }
}

#Preview {
    ContentView()
}
