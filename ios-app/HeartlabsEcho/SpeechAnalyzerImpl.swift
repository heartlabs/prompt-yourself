import AVFoundation
import Foundation
import Speech

// ─────────────────────────────────────────────────────────────────────
//  SpeechAnalyzerImpl — Modern engine (iOS 26+)
//
//  Uses SpeechAnalyzer + SpeechTranscriber with on‑device ML.
//  No 1‑minute timeout workaround needed — transcription continues
//  until the user stops it.
//
//  Uses start(inputSequence:) (autonomous mode) instead of
//  analyzeSequence(_:) because the latter blocks until the sequence
//  terminates.  We want the analysis to run in the background while
//  we consume results from the transcriber's AsyncSequence.
//  ─────────────────────────────────────────────────────────────────────

@available(iOS 26, *)
@MainActor
final class SpeechAnalyzerImpl: TranscriberProvider {
    // MARK: - TranscriberProvider conformance

    private(set) var isRecording = false
    private(set) var transcript = ""
    var onEvent: ((TranscriberEvent) -> Void)?

    // MARK: - Dependencies

    private let locale: Locale

    // MARK: - SpeechAnalyzer state

    private var analyzer: SpeechAnalyzer?
    /// Apple's SpeechTranscriber module — not to be confused with our
    /// TranscriberProvider protocol.
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?

    // MARK: - Audio capture

    private let audioEngine = AVAudioEngine()

    // MARK: - Init

    init(locale: Locale) { self.locale = locale }

    // MARK: - Public API

    func startTranscribing() {
        transcript = ""

        // Dispatch all async setup into a Task so startTranscribing()
        // remains non‑async (required by TranscriberProvider protocol).
        setupTask = Task { [weak self] in
            guard let self else { return }
            await doStart()
            self.setupTask = nil
        }
    }

    func stopTranscribing() {
        setupTask?.cancel()
        setupTask = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        inputContinuation?.finish()
        inputContinuation = nil
        // cancelAndFinishNow() is actor-isolated — dispatch to a task.
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        resultTask?.cancel()
        resultTask = nil
        transcriber = nil
        isRecording = false
        onEvent?(.recordingStateChanged(false))
    }

    func stopTranscribingAsync() async {
        setupTask?.cancel()
        setupTask = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        inputContinuation?.finish()
        inputContinuation = nil

        // Finalize and wait for the result task to drain.
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultTask?.value
        resultTask = nil
        transcriber = nil
        analyzer = nil
        isRecording = false
        onEvent?(.recordingStateChanged(false))
    }

    // MARK: - Private

    private func doStart() async {
        // Resolve locale.
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            onEvent?(.error(LocalizationService.shared.localized("speech_unavailable")))
            return
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        // Configure audio session.
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            onEvent?(.error(String(
                format: LocalizationService.shared.localized("speech_recording_failed"),
                error.localizedDescription
            )))
            return
        }

        // Create input stream.
        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation

        // Create analyzer.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Set up audio engine tap.
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            onEvent?(.error(LocalizationService.shared.localized("speech_unavailable")))
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self, let cont = self.inputContinuation else { return }
            // Wrap the buffer directly.  On iOS the microphone's native format
            // matches the analyzer's preferred format in virtually all cases.
            // If it doesn't, the analyzer will report an error through its
            // result stream.
            cont.yield(AnalyzerInput(buffer: buffer))
        }

        do {
            try audioEngine.start()
        } catch {
            onEvent?(.error(String(
                format: LocalizationService.shared.localized("speech_microphone_failed"),
                error.localizedDescription
            )))
            return
        }

        isRecording = true
        onEvent?(.recordingStateChanged(true))

        // Start autonomous analysis (returns immediately).
        // SpeechAnalyzer is an actor — needs await.
        try? await analyzer.start(inputSequence: inputStream)

        // Consume results from the transcriber's async sequence.
        resultTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    self.transcript = text
                    self.onEvent?(.transcriptChanged(text))
                }
            } catch {
                self.onEvent?(.error(error.localizedDescription))
            }
        }
    }
}
