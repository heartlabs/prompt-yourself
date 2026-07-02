import SwiftData
import SwiftUI

// MARK: - Root Dream View

struct DreamView: View {
    /// Injected by the owner (ContentView) so lifecycle management
    /// (background/tab-switch stop-recording) acts on the SAME instance
    /// the screen renders.
    @ObservedObject var viewModel: ConversationEngine

    /// SwiftData context used to enable per-day dream persistence, mirroring
    /// ContentView's journal setup.
    @Environment(\.modelContext) private var modelContext

    /// Shared visual style for the dream conversation screen.
    private let style = ConversationStyle.dream

    var body: some View {
        ZStack {
            Color.warmIvory.ignoresSafeArea()

            if viewModel.messages.isEmpty && !viewModel.recognizer.isRecording {
                dreamMoodboardView
            } else {
                dreamChatView
            }
        }
        .preferredColorScheme(.light)
        .task {
            // Enable per-day dream persistence (kind `.dream`). Idempotent —
            // safe to run on every appearance.
            viewModel.setupPersistence(with: modelContext)
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

// MARK: - Dream Moodboard (Empty State)

extension DreamView {
    private var dreamMoodboardView: some View {
        VStack(spacing: 0) {
            Spacer()

            // Dream Greeting
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.deepIndigo)
                        .offset(y: 2)

                    Text("Good morning")
                        .font(.system(size: 34, weight: .medium, design: .serif))
                        .foregroundColor(.taupeText)

                    Image(systemName: "sparkles")
                        .font(.system(size: 18))
                        .foregroundColor(.deepIndigo.opacity(0.5))
                        .offset(y: -2)
                }

                Text("What did you dream about?")
                    .font(.system(size: 16, weight: .regular, design: .default))
                    .foregroundColor(.taupeText.opacity(0.65))
            }

            Spacer()

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

// MARK: - Dream Chat View (After First Interaction)

extension DreamView {
    private var dreamChatView: some View {
        VStack(spacing: 0) {
            ConversationTranscriptView(
                messages: viewModel.messages,
                isRecording: viewModel.recognizer.isRecording,
                transcript: viewModel.recognizer.transcript,
                isThinking: viewModel.isThinking,
                isRemembering: false,
                shouldAutoScroll: viewModel.shouldAutoScroll,
                scrollToBottomCount: viewModel.scrollToBottomCount,
                style: style
            )

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

// MARK: - Preview

#Preview {
    DreamView(viewModel: ConversationEngine(configuration: .dream))
}
