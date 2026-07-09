import SwiftUI

// MARK: - ConversationStyle
//
// A value type that captures everything visually distinct between conversation
// screens. Shared UI components below are parameterised by a `ConversationStyle`,
// so multiple screens can render from ONE set of views while keeping independent
// palettes and copy.

struct ConversationStyle {
    // Chat bubbles
    let userBubble: Color
    let userText: Color
    let assistantBubble: Color
    let assistantText: Color
    let systemBubble: Color

    // Mic + live-recording accents
    let accent: Color
    let ringSemibright: Color
    let ringFaint: Color
    let liveBubble: Color

    // Typing indicator
    let typingDot: Color
    let typingBubble: Color

    /// Whether the "remembering…" indicator may appear under the typing dots.
    /// Journal uses tool calls (memory lookups); Dreams (v1) does not.
    let showsRememberingIndicator: Bool

    /// Journal / daily conversation — sage green.
    static let journal = ConversationStyle(
        userBubble: .sageGreen,
        userText: .white,
        assistantBubble: Color.softTaupe.opacity(0.6),
        assistantText: .taupeText,
        systemBubble: Color.softTaupe.opacity(0.3),
        accent: .sageGreen,
        ringSemibright: .sageGreenSemibright,
        ringFaint: .sageGreenFaint,
        liveBubble: Color.sageGreen.opacity(0.8),
        typingDot: .softTaupe,
        typingBubble: Color.softTaupe.opacity(0.4),
        showsRememberingIndicator: true
    )

}

// MARK: - Mic Button

/// The record button, in a large (moodboard) and compact (chat) size.
struct MicButton: View {
    enum Size { case large, compact }

    let style: ConversationStyle
    let size: Size
    let isRecording: Bool
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            switch size {
            case .large: largeBody
            case .compact: compactBody
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var largeBody: some View {
        ZStack {
            // Outermost faint ring
            Circle()
                .stroke(style.ringFaint, lineWidth: 2)
                .frame(width: 130, height: 130)

            // Middle ring (pulses while recording)
            Circle()
                .stroke(style.ringSemibright, lineWidth: 2)
                .frame(width: 108, height: 108)
                .scaleEffect(isRecording ? 1.08 : 1.0)
                .opacity(isRecording ? 0.8 : 1.0)
                .animation(
                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                    value: isRecording
                )

            // Inner solid circle
            Circle()
                .fill(style.accent)
                .frame(width: 72, height: 72)

            Image(systemName: "mic.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private var compactBody: some View {
        ZStack {
            Circle()
                .fill(isRecording ? style.accent.opacity(0.85) : style.accent)
                .frame(width: 56, height: 56)
                .overlay(
                    Circle()
                        .stroke(style.ringSemibright, lineWidth: 2)
                        .frame(width: 68, height: 68)
                        .scaleEffect(isRecording ? 1.15 : 1.0)
                        .opacity(isRecording ? 0.6 : 0.8)
                        .animation(
                            .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                            value: isRecording
                        )
                )

            Image(systemName: isRecording ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Message Bubble

struct MessageBubbleView: View {
    let message: ChatMessage
    let style: ConversationStyle

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            Text(message.content)
                .font(.system(size: 16, weight: .regular, design: .default))
                .foregroundColor(message.role == .user ? style.userText : style.assistantText)
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
        case .user: return style.userBubble
        case .assistant: return style.assistantBubble
        case .system, .tool: return style.systemBubble
        }
    }
}

// MARK: - Live Recording Bubble

struct LiveRecordingBubbleView: View {
    let transcript: String
    let style: ConversationStyle

    var body: some View {
        HStack {
            Spacer(minLength: 40)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(style.accent)
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
            .background(style.liveBubble)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicatorView: View {
    let style: ConversationStyle
    var isRemembering: Bool = false

    @State private var animationOffset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                HStack(spacing: 5) {
                    ForEach(0 ..< 3) { i in
                        Circle()
                            .fill(style.typingDot)
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
                .background(style.typingBubble)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Spacer(minLength: 40)
            }

            // "remembering…" fades in/out during tool calls (journal only).
            if style.showsRememberingIndicator && isRemembering {
                Text("remembering…")
                    .font(.caption2)
                    .foregroundColor(.taupeText.opacity(0.55))
                    .transition(.opacity)
            }
        }
        .onAppear { animationOffset = -4 }
    }
}

// MARK: - Conversation Transcript

/// The scrollable message list shared by both conversation screens: renders the
/// message bubbles, the live-recording bubble, the typing indicator, and the
/// invisible bottom anchor, and reproduces the auto-scroll behaviour.
///
/// It takes plain values (not the view model) so it stays decoupled; the parent
/// screen re-renders when its observable state changes, feeding fresh values in
/// and triggering the `onChange` handlers here.
struct ConversationTranscriptView: View {
    let messages: [ChatMessage]
    let isRecording: Bool
    let transcript: String
    let isThinking: Bool
    let isRemembering: Bool
    let shouldAutoScroll: Bool
    let scrollToBottomCount: Int
    let style: ConversationStyle

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubbleView(message: message, style: style)
                            .id(message.id)
                    }

                    if isRecording {
                        LiveRecordingBubbleView(transcript: transcript, style: style)
                            .id("live")
                    }

                    if isThinking {
                        TypingIndicatorView(style: style, isRemembering: isRemembering)
                            .id("typing")
                    }

                    // Invisible 1pt anchor — reliably resolves to the true bottom
                    // even before the LazyVStack finishes measuring bubble heights.
                    Color.clear
                        .frame(height: 1)
                        .id("scroll_bottom")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .animation(.easeOut(duration: 0.5), value: isRemembering)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: messages.count) { _, _ in
                if shouldAutoScroll { scrollToBottom(proxy) }
            }
            .onChange(of: isRecording) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: transcript) { _, _ in
                if isRecording { scrollToBottom(proxy) }
            }
            .onChange(of: isThinking) { _, _ in
                if isThinking { scrollToBottom(proxy) }
            }
            .onChange(of: shouldAutoScroll) { _, newValue in
                if newValue { scrollToBottom(proxy) }
            }
            .onChange(of: scrollToBottomCount) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if isRecording {
                proxy.scrollTo("live", anchor: .bottom)
            } else if isThinking {
                proxy.scrollTo("typing", anchor: .bottom)
            } else {
                proxy.scrollTo("scroll_bottom", anchor: .bottom)
            }
        }
    }
}
