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
/// system. When this fires (`isFinal = true` without user action), the
/// accumulated transcript is published via `accumulatedSegment`. The ViewModel
/// turns each segment into a separate user bubble so the user can see where
/// the timeout boundary fell.
///
/// ## Error handling
///
/// If the recognition task errors (crash, network failure, etc.), the partial
/// transcript is preserved and published via `pendingTranscript` so the
/// ViewModel can send it to the LLM rather than losing the user's words. When
/// there is no partial transcript to salvage, a user-facing message is published
/// via `recognitionError` so the failure is visible instead of silent.
///
/// ## Availability
///
/// `SFSpeechRecognizer.isAvailable` can read `false` for a moment right after
/// creation and flip `true` once it connects. `startTranscribing()` therefore
/// retries briefly before giving up, so the very first tap after launch isn't
/// silently dropped.
///
/// ## Simulator note
///
/// On the iOS Simulator the on-device speech model is frequently missing or
/// broken (recognition fails with `kLSRErrorDomain` "Failed to create
/// recognizer"). This is an environment limitation, not an app bug — speech
/// works on a physical device. We detect this and show a helpful message.
@MainActor
final class SpeechRecognizer: ObservableObject {
    // MARK: - Published State

    /// The current (possibly partial) transcription text for the current task.
    @Published private(set) var transcript: String = ""

    /// Whether audio is being captured and recognition is running.
    @Published private(set) var isRecording: Bool = false

    /// Set to the accumulated transcript when recording ends spontaneously
    /// (error or system finalisation without user action).
    /// The ViewModel observes this and sends it to the LLM.
    @Published var pendingTranscript: String?

    /// Published when the system finalises a task at the ~1-minute timeout
    /// boundary. The ViewModel turns each segment into a separate user bubble
    /// so the timeout is visible in the chat.
    @Published var accumulatedSegment: String?

    /// A user-facing error to present (e.g. as an alert) when recording can't
    /// start or fails with nothing captured. `nil` when there is no error to
    /// show. The presenting view clears this back to `nil` on dismiss.
    @Published var recognitionError: String?

    // MARK: - Errors

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

    // MARK: - Private State

    private let speechRecognizer: SFSpeechRecognizer? = {
        let r = SFSpeechRecognizer(locale: Locale(identifier: AppLanguage.current.sttLocaleIdentifier))
        r?.queue = .main
        return r
    }()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// Continuation used by `stopTranscribingAsync()` to wait for the final result.
    private var finalizationContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Diagnostics
    //
    // Lightweight logging with the "[SpeechRecognizer]" prefix — filter the
    // Xcode console by that string to trace the pipeline. Kept intentionally
    // concise (start state, key aborts, full errors). Safe to remove.

    /// Number of audio buffers delivered by the input tap for the CURRENT task.
    /// If this stays 0 while "Listening…", the microphone is not feeding the
    /// engine (host/simulator audio problem) — distinct from a recognizer/asset
    /// failure, where buffers flow but no transcript is produced.
    private var tapBufferCount: Int = 0

    private func diag(_ message: String) {
        print("[SpeechRecognizer] \(message)")
    }

    /// Formats an NSError with the fields that matter for speech bugs: domain +
    /// code identify kLSRErrorDomain 300 ("Failed to create recognizer"),
    /// kAFAssistantErrorDomain 1101/1107, SiriSpeechErrorDomain 102, etc.
    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        var parts = ["domain=\(ns.domain)", "code=\(ns.code)", "desc=\(ns.localizedDescription)"]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=(domain=\(underlying.domain) code=\(underlying.code) desc=\(underlying.localizedDescription))")
        }
        return parts.joined(separator: " ")
    }

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
        recognitionError = nil
        diag("startTranscribing(): isAvailable=\(speechRecognizer?.isAvailable ?? false) "
             + "supportsOnDevice=\(speechRecognizer?.supportsOnDeviceRecognition ?? false) "
             + "authStatus=\(SFSpeechRecognizer.authorizationStatus().rawValue)")

        guard speechRecognizer != nil else {
            surfaceError(unavailableMessage())
            return
        }

        // Request authorisation first, then start (retrying briefly if the
        // recognizer hasn't finished becoming available yet).
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.diag("not authorized (status=\(status.rawValue))")
                    self.surfaceError(LocalizationService.shared.localized("speech_permission_off"))
                    return
                }
                self.attemptStart(retriesRemaining: 5)
            }
        }
    }

    /// Waits (briefly) for the recognizer to report available, then starts.
    /// Handles the first-tap-after-launch race where `isAvailable` is still
    /// `false` for a moment. Gives up after ~2s and surfaces an error.
    private func attemptStart(retriesRemaining: Int) {
        guard let recognizer = speechRecognizer else {
            surfaceError(unavailableMessage())
            return
        }

        if recognizer.isAvailable {
            beginAudioCapture()
        } else if retriesRemaining > 0 {
            diag("recognizer not yet available — retrying in 0.4s (\(retriesRemaining) attempts left)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.attemptStart(retriesRemaining: retriesRemaining - 1)
            }
        } else {
            diag("recognizer never became available after retries → surfacing error")
            surfaceError(unavailableMessage())
        }
    }

    /// Stop recording and finalize the transcription immediately (cancels the task).
    func stopTranscribing() {
        accumulatedSegment = nil
        pendingTranscript = nil

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        isRecording = false
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

        // Final result received — transcript has the current task's text.
        // accumulatedSegment was already consumed by the ViewModel subscriber.
        pendingTranscript = nil
        finalizationContinuation = nil
        recognitionTask = nil
        recognitionRequest = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Private Helpers

    /// Marks recording stopped and publishes a user-visible error message.
    private func surfaceError(_ message: String) {
        diag("surfaceError: \(message)")
        isRecording = false
        recognitionError = message
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// A user-facing explanation tuned to the environment. In the Simulator the
    /// on-device speech model is frequently missing/broken, so we steer the user
    /// to a real device instead of surfacing a cryptic asset error.
    private func unavailableMessage() -> String {
        #if targetEnvironment(simulator)
        return LocalizationService.shared.localized("speech_unavailable_simulator")
        #else
        return LocalizationService.shared.localized("speech_unavailable_network")
        #endif
    }

    /// Maps a raw recognition error to a friendly, actionable message.
    private func friendlyMessage(for error: Error) -> String {
        let ns = error as NSError
        // kLSRErrorDomain / asset-init failures mean the on-device speech MODEL
        // couldn't be built (missing/corrupt) — same guidance as "unavailable".
        if ns.domain == "kLSRErrorDomain"
            || ns.localizedDescription.localizedCaseInsensitiveContains("recognizer")
            || ns.localizedDescription.localizedCaseInsensitiveContains("asset") {
            return unavailableMessage()
        }
        #if targetEnvironment(simulator)
        return unavailableMessage()
        #else
        return String(format: LocalizationService.shared.localized("speech_recognition_failed"), ns.localizedDescription)
        #endif
    }

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
        // Reset transcript immediately so the UI doesn't show stale text from the
        // previous recording before the recogniser produces its first partial result.
        transcript = ""

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
            diag("audio session config failed: \(describe(error))")
            surfaceError(String(format: LocalizationService.shared.localized("speech_recording_failed"), error.localizedDescription))
            return
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Known iOS 17+ simulator bug: inputNode can report a 0ch/0kHz format.
        // installTap with an invalid format throws an NSException and crashes.
        // Guard so we surface a clear message instead of crashing.
        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            diag("inputNode has an INVALID format (sampleRate=\(recordingFormat.sampleRate) channels=\(recordingFormat.channelCount)) — mic not bridged into the simulator.")
            surfaceError(unavailableMessage())
            return
        }

        tapBufferCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)
            self.tapBufferCount += 1
            if self.tapBufferCount == 1 {
                self.diag("first audio buffer received — mic input is flowing.")
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            diag("audioEngine.start() failed: \(describe(error))")
            surfaceError(String(format: LocalizationService.shared.localized("speech_microphone_failed"), error.localizedDescription))
            return
        }

        isRecording = true

        guard let speechRecognizer else { return }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            // --- Partial or final result ---
            if let result {
                // Plain task-local transcript — no accumulation.
                // Old segments are published via accumulatedSegment and turned
                // into separate user bubbles by the ViewModel.
                self.transcript = result.bestTranscription.formattedString

                // --- System finalised the task (timeout or silence) ---
                if result.isFinal {
                    // Are we here because the user called stopTranscribingAsync()?
                    if let continuation = self.finalizationContinuation {
                        // YES — user-initiated stop.
                        self.isRecording = false
                        UIApplication.shared.isIdleTimerDisabled = false
                        continuation.resume()
                        self.finalizationContinuation = nil
                        return
                    }

                    // NO — system timeout / silence finalisation.
                    // Publish the accumulated text as a segment for the ViewModel
                    // to turn into a user bubble, then transparently restart.
                    self.accumulatedSegment = self.transcript

                    // Discard the old task and start a fresh one.
                    self.discardTask()
                    self.beginAudioCapture()
                    // isRecording stays true, UI is uninterrupted.
                    return
                }
            }

            // --- Error ---
            if let error {
                self.diag("recognition ERROR: \(self.describe(error)) | tapBuffers=\(self.tapBufferCount) transcriptChars=\(self.transcript.count)")
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

                if !self.transcript.isEmpty {
                    // Salvage the partial words — hand them to the ViewModel to send.
                    self.pendingTranscript = self.transcript
                    self.isRecording = false
                    self.diag("error after partial transcript (\(self.transcript.count) chars) → salvaged via pendingTranscript")
                } else {
                    // Nothing captured — make the failure VISIBLE instead of silent.
                    self.surfaceError(self.friendlyMessage(for: error))
                }
                self.recognitionTask = nil
                self.recognitionRequest = nil
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
}
