import SwiftUI

struct ContentView: View {
    @StateObject private var recognizer = SpeechRecognizer()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Status label
            Text(recognizer.statusMessage)
                .font(.headline)
                .foregroundColor(.secondary)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: recognizer.statusMessage)

            // Microphone button
            Button(action: {
                recognizer.toggleRecording()
            }) {
                ZStack {
                    Circle()
                        .fill(recognizer.isRecording ? Color.red : accentColor)
                        .frame(width: 80, height: 80)
                        .overlay(
                            Circle()
                                .stroke(recognizer.isRecording ? Color.red.opacity(0.3) : accentColor.opacity(0.3),
                                        lineWidth: 4)
                                .scaleEffect(recognizer.isRecording ? 1.3 : 1.0)
                                .opacity(recognizer.isRecording ? 0.6 : 0)
                                .animation(
                                    .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                    value: recognizer.isRecording
                                )
                        )

                    Image(systemName: recognizer.isRecording ? "mic.slash.fill" : "mic.fill")
                        .font(.title)
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)

            // Transcription output
            ScrollView {
                Text(recognizer.transcript)
                    .font(.body)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
            )
            .padding(.horizontal)

            Spacer()
        }
        .padding()
    }

    /// Returns the app's accent color, respecting the system accent if set.
    private var accentColor: Color {
        Color.accentColor
    }
}

#Preview {
    ContentView()
}
