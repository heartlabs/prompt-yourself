import AVFoundation
import Foundation
import Speech
import UIKit

// ─────────────────────────────────────────────────────────────────────
//  SpeechAnalyzerEngine — modern engine (iOS 26+), on-device ML
//
//  Uses SpeechAnalyzer + SpeechTranscriber (Apple's class — unrelated to our
//  TranscriptionEngine protocol). No ~1-minute boundary exists here, so
//  there is no stitching: finalized results accumulate and the latest
//  volatile hypothesis is appended, producing the same cumulative snapshots
//  as SFSpeechEngine.
//
//  Chosen by the factory only when the on-device model assets are ALREADY
//  installed (`assetsInstalled`) — otherwise SFSpeechEngine is used. We
//  never trigger the asset download.
//
//  See TranscriptionEngine.swift for the full one-shot contract.
// ─────────────────────────────────────────────────────────────────────

@available(iOS 26, *)
@MainActor
final class SpeechAnalyzerEngine: TranscriptionEngine {

    /// True when the on-device model for `locale` is already installed.
    /// (A nil installation request means nothing needs downloading.)
    static func assetsInstalled(for locale: Locale) async -> Bool {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return false }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        return request == nil
    }

    // MARK: - Lifecycle

    /// One-way: idle → starting → recording → finishing → finished.
    /// (`cancel()` may jump to .finished from anywhere.)
    private enum State { case idle, starting, recording, finishing, finished }
    private var state: State = .idle

    // MARK: - Analysis

    private let locale: Locale
    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?

    // MARK: - Transcript (single home: finalized + latest volatile)

    private var finalized = ""
    private var volatilePart = ""

    private var updates: AsyncThrowingStream<String, Error>.Continuation?

    // MARK: - Init

    init(locale: Locale) { self.locale = locale }

    // MARK: - TranscriptionEngine

    func start() async throws -> AsyncThrowingStream<String, Error> {
        precondition(state == .idle, "SpeechAnalyzerEngine is one-shot — create a new instance per recording.")
        state = .starting

        do {
            guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw TranscriptionError.unavailable
            }
            try checkpoint()

            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                throw TranscriptionError.audioCapture(key: "speech_recording_failed", detail: error.localizedDescription)
            }

            let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
            self.transcriber = transcriber
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer

            let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
            input = inputContinuation

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw TranscriptionError.unavailable
            }
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                // Realtime audio thread. On iOS hardware the mic's native
                // format matches the analyzer's preferred format; a mismatch
                // is reported through the result stream.
                self?.input?.yield(AnalyzerInput(buffer: buffer))
            }
            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                throw TranscriptionError.audioCapture(key: "speech_microphone_failed", detail: error.localizedDescription)
            }

            // Autonomous analysis: returns immediately, runs in the background.
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch {
                throw TranscriptionError.engine(detail: error.localizedDescription)
            }
            try checkpoint()

            state = .recording
            UIApplication.shared.isIdleTimerDisabled = true

            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            updates = continuation
            consumeResults(from: transcriber)
            return stream
        } catch {
            teardown()
            state = .finished
            throw error
        }
    }

    func finish() async -> String {
        guard state == .recording else {
            if state == .starting { cancel() }
            return transcript
        }
        state = .finishing
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        input?.finish()
        input = nil

        // Finalize through end of input and drain the result task — bounded,
        // so finish() can never hang the UI.
        let analyzer = self.analyzer
        let resultTask = self.resultTask
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await analyzer?.finalizeAndFinishThroughEndOfInput()
                await resultTask?.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            await group.next()
            group.cancelAll()
        }

        teardown()
        state = .finished
        updates?.finish()
        updates = nil
        return transcript
    }

    func cancel() {
        guard state != .finished else { return }
        teardown()
        state = .finished
        updates?.finish()
        updates = nil
    }

    // MARK: - Results

    private func consumeResults(from transcriber: SpeechTranscriber) {
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        // Finalized ranges accumulate; Apple's attributed
                        // results carry their own spacing.
                        self.finalized += text
                        self.volatilePart = ""
                    } else {
                        self.volatilePart = text
                    }
                    self.publishTranscript()
                }
                // Stream ended normally (finish/cancel) — that path owns state.
            } catch {
                self?.handleResultError(error)
            }
        }
    }

    private func handleResultError(_ error: Error) {
        switch state {
        case .finishing:
            break // finish() drains with a bounded wait and returns what we have
        case .recording:
            teardown()
            state = .finished
            updates?.finish(throwing: TranscriptionError.engine(detail: error.localizedDescription))
            updates = nil
        case .idle, .starting, .finished:
            break // start() throws its own errors; late callbacks are stale
        }
    }

    // MARK: - Transcript

    private var transcript: String { finalized + volatilePart }

    private func publishTranscript() {
        updates?.yield(transcript)
    }

    // MARK: - Teardown

    /// Idempotent hardware/analyzer teardown — safe to call in any state, twice.
    ///
    /// The AVAudioSession is deliberately NOT deactivated here — deactivating
    /// between recognitions can block the next activation on the main thread
    /// (full UI freeze). See the matching note in SFSpeechEngine.teardown().
    private func teardown() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        input?.finish()
        input = nil
        resultTask?.cancel()
        resultTask = nil
        if let analyzer {
            // cancelAndFinishNow() is analyzer-isolated — fire and forget.
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        transcriber = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Throws when the surrounding task was cancelled or cancel() ran while
    /// start() was suspended — the mic must never go live after either.
    private func checkpoint() throws {
        guard state == .starting else { throw CancellationError() }
        try Task.checkCancellation()
    }
}
