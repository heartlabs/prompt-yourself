import Foundation
import AVFoundation
import Speech
import UIKit

/// An observable service that manages speech-to-text transcription using
/// the device's microphone and `SFSpeechRecognizer`.
///
/// ## Timeout handling
///
/// `SFSpeechRecognitionTask` has a built-in ~1-minute timeout enforced by the
/// system. When this fires (`isFinal = true` without user action), this class
/// **transparently restarts** the task and accumulates the transcript across
/// restarts so the user never loses text.
///
/// ## Error handling
///
/// If the recognition task errors (crash, network failure, etc.), the partial
/// transcript is preserved and published via `pendingTranscript` so the
/// ViewModel can send it to the LLM rather than losing the user's words.
@MainActor
final class SpeechRecognizer: ObservableObject {
    // MARK: - Published State

    /// The current (possibly partial) transcription text.
    /// Includes accumulated text from previous task restarts.
    @Published private(set) var transcript: String = ""

    /// Whether audio is being captured and recognition is running.
    @Published private(set) var isRecording: Bool = false

    /// A user-facing status message (idle, listening, error, …).
    @Published private(set) var statusMessage: String = "Tap the microphone to start"

    /// Set to the accumulated transcript when recording ends spontaneously
    /// (error or system finalisation without user action).
    /// The ViewModel observes this and sends it to the LLM.
    @Published var pendingTranscript: String?

    // MARK: - Errors

    enum RecognitionError: LocalizedError {
        case notAuthorized
        case unavailable
        case engineError(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Speech recognition is not authorized. Please grant access in Settings."
            case .unavailable:
                return "Speech recognition is not available on this device."
            case .engineError(let detail):
                return "Recognition error: \(detail)"
            }
        }
    }

    // MARK: - Private State

    private let speechRecognizer: SFSpeechRecognizer? = {
        let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        r?.queue = .main
        return r
    }()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// Continuation used by `stopTranscribingAsync()` to wait for the final result.
    private var finalizationContinuation: CheckedContinuation<Void, Never>?

    /// Accumulated transcript from previous task instances after system-initiated
    /// timeouts / task finalisation. Prepended to every new task's result so the
    /// user sees a seamless, growing transcript.
    private var accumulatedBase: String = ""

    // MARK: - Public API

    /// Toggle recording on/off.
    /// Starts recording if idle, stops and finalises if already recording.
    func toggleRecording() {
        if isRecording {
            stopTranscribing()
        } else {
            startTranscribing()
        }
    }

    /// Begin listening and transcribing.
    func startTranscribing() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            statusMessage = RecognitionError.unavailable.localizedDescription
            return
        }

        // Check / request authorisation.
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self?.statusMessage = RecognitionError.notAuthorized.localizedDescription
                    return
                }
                self?.beginAudioCapture()
            }
        }
    }

    /// Stop recording and finalize the transcription immediately (cancels the task).
    /// Clears the accumulated transcript since the user intentionally stopped.
    func stopTranscribing() {
        accumulatedBase = ""
        pendingTranscript = nil

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        isRecording = false
        statusMessage = transcript.isEmpty ? "Tap to start" : "Done"
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Stop recording and **await the final transcript** instead of cancelling.
    /// Use this for reliable transcription of long utterances.
    func stopTranscribingAsync() async {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        // Do NOT cancel the task — let it finalize and produce the final result.

        await withCheckedContinuation { continuation in
            finalizationContinuation = continuation
        }

        // Final result received — transcript is now the complete text
        // (accumulatedBase was already folded in by the handler).
        accumulatedBase = ""
        pendingTranscript = nil
        finalizationContinuation = nil
        recognitionTask = nil
        recognitionRequest = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Private Helpers

    /// Releases the current task, request and audio tap without stopping the engine.
    /// Called before transparently restarting the recognition task.
    private func discardTask() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        // AVAudioEngine only allows one tap per bus — remove the old one
        // before beginAudioCapture() installs a new one on restart.
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    /// Stops the audio engine and cleans up the tap.
    private func stopAudioEngine() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func beginAudioCapture() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation  // Slightly longer silence tolerance
        recognitionRequest = request

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            statusMessage = "Failed to configure audio session: \(error.localizedDescription)"
            return
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            statusMessage = "Failed to start audio engine: \(error.localizedDescription)"
            return
        }

        isRecording = true
        statusMessage = "Listening..."

        guard let speechRecognizer else { return }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            // --- Partial or final result ---
            if let result {
                let currentText = result.bestTranscription.formattedString

                // Build the full display text: accumulated base + this task's text
                if accumulatedBase.isEmpty {
                    self.transcript = currentText
                } else {
                    self.transcript = "\(accumulatedBase) \(currentText)"
                }

                // --- System finalised the task (timeout or silence) ---
                if result.isFinal {
                    // Are we here because the user called stopTranscribingAsync()?
                    if let continuation = self.finalizationContinuation {
                        // YES — user-initiated stop.  transcript already has the
                        // full accumulated text.  Resume the caller.
                        self.isRecording = false
                        self.statusMessage = self.transcript.isEmpty ? "Tap to start" : "Done"
                        UIApplication.shared.isIdleTimerDisabled = false
                        continuation.resume()
                        self.finalizationContinuation = nil
                        return
                    }

                    // NO — system timeout / silence finalisation.
                    // Accumulate what we have and transparently restart.
                    self.accumulatedBase = self.transcript

                    // Discard the old task and start a fresh one.
                    self.discardTask()
                    self.beginAudioCapture()
                    // isRecording stays true, UI is uninterrupted.
                    return
                }
            }

            // --- Error ---
            if let error {
                // transcript already includes accumulatedBase (set in the result
                // handler above), so we just preserve it as-is.
                self.accumulatedBase = ""
                self.stopAudioEngine()

                // Snapshot whether we were still recording before we mutate state.
                let wasRecording = self.isRecording

                // If user was waiting for finalization, resume them with what we have
                if let continuation = self.finalizationContinuation {
                    self.isRecording = false
                    continuation.resume()
                    self.finalizationContinuation = nil
                    self.recognitionTask = nil
                    self.recognitionRequest = nil
                    UIApplication.shared.isIdleTimerDisabled = false
                    return
                }

                // Task was already cancelled externally (stopTranscribing()).
                // The caller handled the stop — nothing more to do.
                guard wasRecording else { return }

                // Spontaneous error — preserve the partial transcript and let the
                // ViewModel send it to the LLM.
                if !self.transcript.isEmpty {
                    self.pendingTranscript = self.transcript
                }
                self.isRecording = false
                self.statusMessage = RecognitionError.engineError(error.localizedDescription).localizedDescription
                self.recognitionTask = nil
                self.recognitionRequest = nil
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
}
