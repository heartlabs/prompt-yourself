import SwiftUI

// MARK: - Root View

struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()

    var body: some View {
        ZStack {
            Color.warmIvory.ignoresSafeArea()

            if viewModel.messages.isEmpty && !viewModel.recognizer.isRecording {
                moodboardView
            } else {
                chatView
            }
        }
        .preferredColorScheme(.light)
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

            // 3-Layer Microphone Button
            largeMicButton

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

// MARK: - Large 3-Layer Mic Button

extension ContentView {
    private var largeMicButton: some View {
        Button(action: {
            viewModel.toggleRecording()
        }) {
            ZStack {
                // Layer 1: Outermost faint green ring
                Circle()
                    .stroke(Color.sageGreenFaint, lineWidth: 2)
                    .frame(width: 130, height: 130)

                // Layer 2: Middle semi-transparent green ring (pulses when recording)
                Circle()
                    .stroke(Color.sageGreenSemibright, lineWidth: 2)
                    .frame(width: 108, height: 108)
                    .scaleEffect(viewModel.recognizer.isRecording ? 1.08 : 1.0)
                    .opacity(viewModel.recognizer.isRecording ? 0.8 : 1.0)
                    .animation(
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                        value: viewModel.recognizer.isRecording
                    )

                // Layer 3: Inner solid sage green circle
                Circle()
                    .fill(Color.sageGreen)
                    .frame(width: 72, height: 72)

                // White vector mic icon
                Image(systemName: "mic.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isThinking)
    }
}

// MARK: - Chat View (After First Interaction)

extension ContentView {
    private var chatView: some View {
        VStack(spacing: 0) {
            // Chat Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        // Live transcript while recording
                        if viewModel.recognizer.isRecording {
                            LiveRecordingBubble(transcript: viewModel.recognizer.transcript)
                                .id("live")
                        }

                        // Typing indicator
                        if viewModel.isThinking {
                            TypingIndicator()
                                .id("typing")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: viewModel.messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: viewModel.recognizer.isRecording) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: viewModel.recognizer.transcript) { _, _ in
                    if viewModel.recognizer.isRecording {
                        scrollToBottom(proxy)
                    }
                }
                .onChange(of: viewModel.isThinking) { _, _ in
                    if viewModel.isThinking {
                        scrollToBottom(proxy)
                    }
                }
            }

            // Compact Mic Button (Chat Mode)
            VStack(spacing: 6) {
                compactMicButton

                Text(viewModel.recognizer.isRecording ? "Recording..." : "Tap to speak")
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundColor(.taupeText.opacity(0.5))
            }
            .padding(.vertical, 8)
        }
    }

    private var compactMicButton: some View {
        Button(action: {
            viewModel.toggleRecording()
        }) {
            ZStack {
                Circle()
                    .fill(viewModel.recognizer.isRecording ? Color.sageGreen.opacity(0.85) : Color.sageGreen)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Circle()
                            .stroke(Color.sageGreenSemibright, lineWidth: 2)
                            .frame(width: 68, height: 68)
                            .scaleEffect(viewModel.recognizer.isRecording ? 1.15 : 1.0)
                            .opacity(viewModel.recognizer.isRecording ? 0.6 : 0.8)
                            .animation(
                                .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                                value: viewModel.recognizer.isRecording
                            )
                    )

                Image(systemName: viewModel.recognizer.isRecording
                    ? "mic.slash.fill"
                    : "mic.fill"
                )
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isThinking)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if let last = viewModel.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            } else if viewModel.isThinking {
                proxy.scrollTo("typing", anchor: .bottom)
            }
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            Text(message.content)
                .font(.system(size: 16, weight: .regular, design: .default))
                .foregroundColor(message.role == .user ? .white : .taupeText)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(bubbleColor)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .textSelection(.enabled)

            if message.role == .assistant {
                Spacer(minLength: 40)
            }
        }
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user:
            return Color.sageGreen
        case .assistant:
            return Color.softTaupe.opacity(0.6)
        case .system:
            return Color.softTaupe.opacity(0.3)
        }
    }
}

// MARK: - Live Recording Bubble

struct LiveRecordingBubble: View {
    let transcript: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.sageGreen)
                        .frame(width: 6, height: 6)
                    Text("Recording...")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
                }

                if transcript.isEmpty {
                    Text("Listening...")
                        .font(.system(size: 16, weight: .regular, design: .default))
                        .foregroundColor(.white.opacity(0.5))
                        .italic()
                } else {
                    Text(transcript)
                        .font(.system(size: 16, weight: .regular, design: .default))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.sageGreen.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var animationOffset: CGFloat = 0

    var body: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0 ..< 3) { i in
                    Circle()
                        .fill(Color.softTaupe)
                        .frame(width: 8, height: 8)
                        .offset(y: animationOffset)
                        .animation(
                            .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.15),
                            value: animationOffset
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.softTaupe.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Spacer(minLength: 40)
        }
        .onAppear {
            animationOffset = -4
        }
    }
}

#Preview {
    ContentView()
}
