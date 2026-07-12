import Foundation
import Speech

// ─────────────────────────────────────────────────────────────────────
//  TranscriberProvider — Protocol + Event + Factory
//
//  This module defines the abstraction between the facade
//  (SpeechRecognizer) and the two implementations:
//
//    • SpeechAnalyzerImpl      — iOS 26+, on-device ML
//    • SFSpeechRecognizerImpl  — iOS 17+, server‑based
//
//  There are exactly two implementations.  Do not add a third.
//
//  NOTE: The protocol is deliberately named TranscriberProvider, not
//  SpeechTranscriber, to avoid a naming collision with Apple's
//  SpeechTranscriber class (iOS 26+, Speech framework).
//  ─────────────────────────────────────────────────────────────────────

// MARK: - Event

/// Events emitted by a TranscriberProvider implementation.
///
/// The facade (`SpeechRecognizer`) maps these onto its `@Published`
/// properties so callers never import either implementation directly.
enum TranscriberEvent {
    /// A new (partial or final) transcription text.
    case transcriptChanged(String)

    /// Recording ended without user action (error / system timeout).
    /// The caller should send whatever text was captured to the LLM.
    case pendingTranscript(String)

    /// The system finalised a task at the ~1‑minute timeout boundary
    /// (`SFSpeechRecognizerImpl` only).  The caller turns each segment
    /// into a separate user bubble.  `SpeechAnalyzerImpl` never emits this.
    case accumulatedSegment(String)

    /// A user‑facing error message.
    case error(String)

    /// Recording state changed (started / stopped).
    /// The facade keeps its @Published isRecording in sync.
    case recordingStateChanged(Bool)
}

// MARK: - Protocol

/// Drives one speech‑to‑text session.
///
/// Implementations never touch `@Published` or `ObservableObject`.
/// All state changes flow through `onEvent` so the facade can publish
/// them via its own `@Published` properties.
@MainActor
protocol TranscriberProvider: AnyObject {
    /// Whether audio is being captured right now.
    var isRecording: Bool { get }

    /// The current (possibly partial) transcription text.
    var transcript: String { get }

    /// Callback to publish state changes to the facade.
    /// Set once by the facade immediately after creation.
    var onEvent: ((TranscriberEvent) -> Void)? { get set }

    /// Start listening and transcribing.
    func startTranscribing()

    /// Stop immediately — cancel the current task.
    func stopTranscribing()

    /// Stop and await the final transcript before returning.
    func stopTranscribingAsync() async
}

// MARK: - Factory

/// Creates the best available `TranscriberProvider` for the current device.
///
///  • iOS 26+ with on‑device ML assets already installed → `SpeechAnalyzerImpl`
///  • Otherwise                                  → `SFSpeechRecognizerImpl`
///
/// The factory is a free function on an unconstructable enum so that it
/// cannot be extended, subclassed, or mocked — exactly two implementations.
enum TranscriberFactory {
    /// Asynchronous because the iOS 26+ path checks asset availability.
    @MainActor
    static func make(locale: Locale) async -> TranscriberProvider {
        if #available(iOS 26, *) {
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])
            if request == nil {
                // Assets already on device — use the modern engine.
                return SpeechAnalyzerImpl(locale: locale)
            }
            // Models need download — fall through to SFSpeechRecognizer.
        }
        return SFSpeechRecognizerImpl(locale: locale)
    }
}
