import AVFoundation
import Foundation
import Speech
import UIKit

// ─────────────────────────────────────────────────────────────────────
//  SFSpeechRecognizerImpl — Legacy fallback (iOS 17+)
//
//  Extracted verbatim from the original SpeechRecognizer.  Behavioral
//  changes are minimal:
//
//    • Conforms to TranscriberProvider
//    • Communication with the outside world happens via onEvent
//      instead of @Published properties
//    • locale is injected at init instead of read from AppLanguage.current
//
//  Everything else — the 1‑minute timeout workaround, retry logic,
//  diagnostics, simulator detection, audio session setup — is preserved.
//  ─────────────────────────────────────────────────────────────────────

@MainActor
final class SFSpeechRecognizerImpl: TranscriberProvider {
    // MARK: - TranscriberProvider conformance

    private(set) var isRecording = false
    private(set) var transcript = ""
    var onEvent: ((TranscriberEvent) -> Void)?

    // MARK: - Private State

    private let speechRecognizer: SFSpeechRecognizer?

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// Continuation used by `stopTranscribingAsync()` to wait for the final result.
    private var finalizationContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Diagnostics
    //
    // Lightweight logging with the "[SFSpeechRecognizerImpl]" prefix — filter
    // the Xcode console by that string to trace the pipeline.

    /// Number of audio buffers delivered by the input tap for the CURRENT task.
    private var tapBufferCount: Int = 0

    private func diag(_ message: String) {
        print("[SFSpeechRecognizerImpl] \(message)")
    }

    /// Formats an NSError with the fields that matter for speech bugs.
    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        var parts = ["domain=\(ns.domain)", "code=\(ns.code)", "desc=\(ns.localizedDescription)"]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=(domain=\(underlying.domain) code=\(underlying.code) desc=\(underlying.localizedDescription))")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Init

    init(locale: Locale) {
        let r = SFSpeechRecognizer(locale: locale)
        r?.queue = .main
        speechRecognizer = r
    }

    // MARK: - Public API

    func startTranscribing() {
        diag("startTranscribing(): isAvailable=\(speechRecognizer?.isAvailable ?? false) "
             + "supportsOnDevice=\(speechRecognizer?.supportsOnDeviceRecognition ?? false) "
             + "authStatus=\(SFSpeechRecognizer.authorizationStatus().rawValue)")

        guard speechRecognizer != nil else {
            surfaceError(unavailableMessage())
            return
        }

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

    func stopTranscribing() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        isRecording = false
        onEvent?(.recordingStateChanged(false))
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func stopTranscribingAsync() async {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()

        await withCheckedContinuation { continuation in
            finalizationContinuation = continuation
        }

        isRecording = false
        onEvent?(.recordingStateChanged(false))
        finalizationContinuation = nil
        recognitionTask = nil
        recognitionRequest = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Private

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

    private func beginAudioCapture() {
        transcript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
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
        onEvent?(.recordingStateChanged(true))

        guard let speechRecognizer else { return }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                self.transcript = result.bestTranscription.formattedString
                self.onEvent?(.transcriptChanged(self.transcript))

                if result.isFinal {
                    if let continuation = self.finalizationContinuation {
                        self.isRecording = false
                        self.onEvent?(.recordingStateChanged(false))
                        UIApplication.shared.isIdleTimerDisabled = false
                        continuation.resume()
                        self.finalizationContinuation = nil
                        return
                    }

                    // System timeout / silence finalisation.
                    self.onEvent?(.accumulatedSegment(self.transcript))

                    self.discardTask()
                    self.beginAudioCapture()
                    return
                }
            }

            if let error {
                self.diag("recognition ERROR: \(self.describe(error)) | tapBuffers=\(self.tapBufferCount) transcriptChars=\(self.transcript.count)")
                self.stopAudioEngine()

                let wasRecording = self.isRecording

                if let continuation = self.finalizationContinuation {
                    self.isRecording = false
                    self.onEvent?(.recordingStateChanged(false))
                    continuation.resume()
                    self.finalizationContinuation = nil
                    self.recognitionTask = nil
                    self.recognitionRequest = nil
                    UIApplication.shared.isIdleTimerDisabled = false
                    return
                }

                guard wasRecording else { return }

                if !self.transcript.isEmpty {
                    self.onEvent?(.pendingTranscript(self.transcript))
                    self.isRecording = false
                    self.onEvent?(.recordingStateChanged(false))
                    self.diag("error after partial transcript (\(self.transcript.count) chars) → salvaged via pendingTranscript")
                } else {
                    self.surfaceError(self.friendlyMessage(for: error))
                }
                self.recognitionTask = nil
                self.recognitionRequest = nil
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    // MARK: - Error helpers

    private func surfaceError(_ message: String) {
        diag("surfaceError: \(message)")
        isRecording = false
        onEvent?(.recordingStateChanged(false))
        onEvent?(.error(message))
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func unavailableMessage() -> String {
        #if targetEnvironment(simulator)
        return LocalizationService.shared.localized("speech_unavailable_simulator")
        #else
        return LocalizationService.shared.localized("speech_unavailable_network")
        #endif
    }

    private func friendlyMessage(for error: Error) -> String {
        let ns = error as NSError
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

    private func discardTask() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func stopAudioEngine() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }
}
