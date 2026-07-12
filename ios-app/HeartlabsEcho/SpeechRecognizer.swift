import Combine
import Foundation
import Speech
import UIKit

// ─────────────────────────────────────────────────────────────────────
//  SpeechRecognizer — ObservableObject facade
//
//  This is a thin wrapper around a TranscriberProvider implementation
//  chosen at runtime by TranscriberFactory.
//
//  The public API (@Published properties + toggleRecording / start /
//  stop / stopAsync) is identical to the original, single‑implementation
//  version.  Callers see zero changes.
//
//  Implementation strategy
//  ───────────────────────
//  The transcriber is created lazily on the first startTranscribing()
//  so init() can stay synchronous (required by `let recognizer = …()`
//  in ConversationEngine).
//
//  accumulatedSegment / pendingTranscript
//  ─────────────────────────────────────
//  These @Published properties exist so existing callers
//  (ConversationEngine's Combine subscriptions) compile unchanged.
//  Only SFSpeechRecognizerImpl emits .accumulatedSegment (its
//  1‑minute timeout workaround) and .pendingTranscript (error salvage).
//  SpeechAnalyzerImpl never emits them — the Combine subscribers
//  simply never fire on the modern path.
//  ─────────────────────────────────────────────────────────────────────

@MainActor
final class SpeechRecognizer: ObservableObject {
    // MARK: - Published State (unchanged)

    /// The current (possibly partial) transcription text.
    @Published private(set) var transcript: String = ""

    /// Whether audio is being captured and recognition is running.
    @Published private(set) var isRecording: Bool = false

    /// Set when recording ends spontaneously (error / system finalisation).
    /// The ViewModel observes this and sends the text to the LLM.
    @Published var pendingTranscript: String?

    /// Set when the system finalises a task at the ~1‑minute timeout
    /// boundary (SFSpeechRecognizerImpl only).  The ViewModel turns
    /// each segment into a separate user bubble.
    @Published var accumulatedSegment: String?

    /// A user‑facing error to present (e.g. as an alert).
    @Published var recognitionError: String?

    // MARK: - Errors (public, unchanged)

    enum RecognitionError: LocalizedError {
        case notAuthorized
        case unavailable
        case engineError(String)

        @MainActor
        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return LocalizationService.shared.localized("speech_not_authorized")
            case .unavailable:
                return LocalizationService.shared.localized("speech_unavailable")
            case .engineError(let detail):
                return String(format: LocalizationService.shared.localized("speech_recognition_error"), detail)
            }
        }
    }

    // MARK: - Debug (only in debug builds)

    #if DEBUG
    /// Human‑readable name of the active STT engine, set after init.
    @Published private(set) var activeEngineName: String = "…"
    #endif

    // MARK: - Private State

    private var impl: TranscriberProvider?
    private var initTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates an un‑initialised recognizer.
    ///
    /// The actual `TranscriberProvider` implementation is created lazily
    /// on the first call to `startTranscribing()`.  This lets callers
    /// keep `let recognizer = SpeechRecognizer()` without changes.
    nonisolated init() {}

    // MARK: - Public API

    /// Toggle recording on/off.
    func toggleRecording() {
        if isRecording {
            stopTranscribing()
        } else {
            startTranscribing()
        }
    }

    /// Begin listening and transcribing.
    func startTranscribing() {
        transcript = ""
        recognitionError = nil

        if let impl {
            impl.startTranscribing()
            return
        }

        // First call — create the transcriber lazily.
        // startTranscribing() is non‑async, so we kick off async init
        // and return.  The init calls impl.startTranscribing() when ready.
        // A second tap before init completes is a no‑op (initTask is set).
        guard initTask == nil else { return }
        initTask = Task { [weak self] in
            guard let self else { return }
            let locale = Locale(identifier: AppLanguage.current.sttLocaleIdentifier)
            let impl = await TranscriberFactory.make(locale: locale)
            self.impl = impl
            #if DEBUG
            self.activeEngineName = "\(type(of: impl))"
            #endif
            self.setupBridge(for: impl)
            impl.startTranscribing()
            self.initTask = nil
        }
    }

    /// Stop recording and finalize the transcription immediately.
    func stopTranscribing() {
        accumulatedSegment = nil
        pendingTranscript = nil
        impl?.stopTranscribing()
    }

    /// Stop recording and await the final transcript.
    func stopTranscribingAsync() async {
        await impl?.stopTranscribingAsync()
    }

    // MARK: - Bridge

    /// Wires the implementation's `onEvent` to our `@Published` properties.
    private func setupBridge(for impl: TranscriberProvider) {
        impl.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                switch event {
                case .transcriptChanged(let text):
                    self.transcript = text
                case .pendingTranscript(let text):
                    self.pendingTranscript = text
                case .accumulatedSegment(let text):
                    self.accumulatedSegment = text
                case .error(let message):
                    self.recognitionError = message
                    self.isRecording = false
                case .recordingStateChanged(let recording):
                    self.isRecording = recording
                }
            }
        }
    }
}
