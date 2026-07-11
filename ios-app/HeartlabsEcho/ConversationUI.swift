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

// MARK: - Companion Orb

/// The single control of the voice-first conversation: a soft, breathing
/// sphere with no glyph — a presence, not a toolbar button.
///
/// The orb is the ONE tap target for talking. At rest (chat + moodboard) it
/// slowly breathes; inside conversation mode `isListening` adds expanding
/// ripple rings while audio is being captured.
struct CompanionOrbView: View {
    let style: ConversationStyle
    var diameter: CGFloat = 72
    var isListening: Bool = false
    var isEnabled: Bool = true
    /// Shows a subtle mic glyph — the "tap to talk" affordance for the orb at
    /// rest. Conversation mode leaves it off: while listening, the ripples and
    /// the live transcript are the state.
    var showsMicGlyph: Bool = false
    let action: () -> Void

    /// Drives the idle breathing loop (started once on appear).
    @State private var isBreathing = false
    /// Drives the listening ripple loop.
    @State private var isRippling = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isListening {
                    rippleRing(delay: 0)
                    rippleRing(delay: 0.9)
                }

                // Sphere and glyph breathe together as one body.
                ZStack {
                    sphere
                    if showsMicGlyph {
                        Image(systemName: "mic.fill")
                            .font(.system(size: diameter * 0.28, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                    }
                }
                .scaleEffect(isBreathing ? 1.05 : 1.0)
                .animation(
                    .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
                    value: isBreathing
                )
            }
            // The layout footprint is the sphere itself; ripples overflow
            // decoratively without pushing surrounding layout around.
            .frame(width: diameter, height: diameter)
        }
        .buttonStyle(OrbPressStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onAppear { isBreathing = true }
    }

    private var sphere: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [style.accent.opacity(0.72), style.accent],
                    center: UnitPoint(x: 0.38, y: 0.3),
                    startRadius: 0,
                    endRadius: diameter * 0.85
                )
            )
            .frame(width: diameter, height: diameter)
            .shadow(color: style.accent.opacity(0.35), radius: diameter * 0.2, y: diameter * 0.06)
    }

    private func rippleRing(delay: Double) -> some View {
        Circle()
            .stroke(style.ringSemibright, lineWidth: 1.5)
            .frame(width: diameter, height: diameter)
            .scaleEffect(isRippling ? 1.85 : 1.0)
            .opacity(isRippling ? 0 : 0.8)
            .animation(
                .easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(delay),
                value: isRippling
            )
            .onAppear { isRippling = true }
    }
}

// MARK: - Orb Press Style

/// Press feedback for the orb: a light haptic tick the moment the finger
/// lands, plus a gentle squeeze — the orb responds like something alive.
private struct OrbPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in
                pressed
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

            switch message.content {
            case .text(let text):
                Text(text)
                    .font(.system(size: 16, weight: .regular, design: .default))
                    .foregroundColor(message.role == .user ? style.userText : style.assistantText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(bubbleColor)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .textSelection(.enabled)

            case .image(let path):
                Group {
                    if let uiImage = ImageUtils.loadImage(relativePath: path) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else {
                        Text("📷")
                            .font(.system(size: 32))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(bubbleColor)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }

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
            // Pin content to the bottom so a short conversation sits just above
            // the input bar instead of leaving a gap beneath the greeting.
            .defaultScrollAnchor(.bottom)
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
