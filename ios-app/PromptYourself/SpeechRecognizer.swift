import Foundation
import AVFoundation
import Speech

/// An observable service that manages speech-to-text transcription using
/// the device's microphone and `SFSpeechRecognizer`.
@MainActor
final class SpeechRecognizer: ObservableObject {
    // MARK: - Published State

    /// The current (possibly partial) transcription text.
    @Published private(set) var transcript: String = ""

    /// Whether audio is being captured and recognition is running.
    @Published private(set) var isRecording: Bool = false

    /// A user-facing status message (idle, listening, error, …).
    @Published private(set) var statusMessage: String = "Tap the microphone to start"

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

    /// Stop recording and finalize the transcription.
    func stopTranscribing() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        isRecording = false
        statusMessage = transcript.isEmpty ? "Tap to start" : "Done"
    }

    // MARK: - Private Helpers

    private func beginAudioCapture() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
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

            if let result {
                self.transcript = result.bestTranscription.formattedString
            }

            if let error {
                // If audio engine is already stopped this is expected – ignore.
                if self.audioEngine.isRunning {
                    self.stopTranscribing()
                    self.statusMessage = RecognitionError.engineError(error.localizedDescription).localizedDescription
                }
            }
        }
    }
}
