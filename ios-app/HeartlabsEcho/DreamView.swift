import SwiftUI

// MARK: - Root Dream View

struct DreamView: View {
    @StateObject private var viewModel = DreamViewModel()

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

            // 3-Layer Indigo Microphone Button
            dreamLargeMicButton

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

// MARK: - Large 3-Layer Indigo Mic Button

extension DreamView {
    private var dreamLargeMicButton: some View {
        Button(action: {
            viewModel.toggleRecording()
        }) {
            ZStack {
                // Layer 1: Outermost faint indigo ring
                Circle()
                    .stroke(Color.indigoFaint, lineWidth: 2)
                    .frame(width: 130, height: 130)

                // Layer 2: Middle semi-transparent indigo ring (pulses when recording)
                Circle()
                    .stroke(Color.indigoSemibright, lineWidth: 2)
                    .frame(width: 108, height: 108)
                    .scaleEffect(viewModel.recognizer.isRecording ? 1.08 : 1.0)
                    .opacity(viewModel.recognizer.isRecording ? 0.8 : 1.0)
                    .animation(
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                        value: viewModel.recognizer.isRecording
                    )

                // Layer 3: Inner solid indigo circle
                Circle()
                    .fill(Color.deepIndigo)
                    .frame(width: 72, height: 72)

                // White mic icon
                Image(systemName: "mic.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isThinking)
    }
}

// MARK: - Dream Chat View (After First Interaction)

extension DreamView {
    private var dreamChatView: some View {
        VStack(spacing: 0) {
            // Chat Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            DreamMessageBubble(message: message)
                                .id(message.id)
                        }

                        // Live transcript while recording
                        if viewModel.recognizer.isRecording {
                            DreamLiveRecordingBubble(transcript: viewModel.recognizer.transcript)
                                .id("live")
                        }

                        // Typing indicator
                        if viewModel.isThinking {
                            DreamTypingIndicator()
                                .id("typing")
                        }

                        // Invisible bottom spacer for reliable scroll anchoring
                        Color.clear
                            .frame(height: 1)
                            .id("scroll_bottom")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: viewModel.messages.count) { _, _ in
                    if viewModel.shouldAutoScroll {
                        scrollToBottom(proxy)
                    }
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
                .onChange(of: viewModel.shouldAutoScroll) { _, newValue in
                    if newValue {
                        scrollToBottom(proxy)
                    }
                }
                .onChange(of: viewModel.scrollToBottomCount) { _, _ in
                    scrollToBottom(proxy)
                }
            }

            // Compact Mic Button (Chat Mode)
            VStack(spacing: 6) {
                dreamCompactMicButton

                Text(viewModel.recognizer.isRecording ? "Recording..." : "Tap to speak")
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundColor(.taupeText.opacity(0.5))
            }
            .padding(.vertical, 8)
        }
    }

    private var dreamCompactMicButton: some View {
        Button(action: {
            viewModel.toggleRecording()
        }) {
            ZStack {
                Circle()
                    .fill(viewModel.recognizer.isRecording ? Color.deepIndigo.opacity(0.85) : Color.deepIndigo)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Circle()
                            .stroke(Color.indigoSemibright, lineWidth: 2)
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
            if viewModel.recognizer.isRecording {
                proxy.scrollTo("live", anchor: .bottom)
            } else if viewModel.isThinking {
                proxy.scrollTo("typing", anchor: .bottom)
            } else {
                proxy.scrollTo("scroll_bottom", anchor: .bottom)
            }
        }
    }
}

// MARK: - Dream Message Bubble

struct DreamMessageBubble: View {
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
            return Color.deepIndigo
        case .assistant:
            return Color.softPeriwinkle
        case .system, .tool:
            return Color.softPeriwinkle.opacity(0.5)
        }
    }
}

// MARK: - Dream Live Recording Bubble

struct DreamLiveRecordingBubble: View {
    let transcript: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.deepIndigo)
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
            .background(Color.deepIndigo.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

// MARK: - Dream Typing Indicator

struct DreamTypingIndicator: View {
    @State private var animationOffset: CGFloat = 0

    var body: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0 ..< 3) { i in
                    Circle()
                        .fill(Color.softPeriwinkle)
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
            .background(Color.softPeriwinkle.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Spacer(minLength: 40)
        }
        .onAppear {
            animationOffset = -4
        }
    }
}

// MARK: - Preview

#Preview {
    DreamView()
}
