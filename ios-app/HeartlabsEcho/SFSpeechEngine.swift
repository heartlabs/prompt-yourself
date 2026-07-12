import AVFoundation
import Foundation
import Speech
import UIKit

// ─────────────────────────────────────────────────────────────────────
//  SFSpeechEngine — legacy engine (iOS 17+), server-based
//
//  iOS force-finalizes SFSpeechRecognizer tasks after ~1 minute. This engine
//  absorbs that boundary internally: it seals the finished segment (ensuring
//  terminal punctuation), restarts a fresh recognition task on the same
//  audio tap, and joins segments with a blank line. Consumers see ONE
//  continuously growing transcript; the paragraph break is the deliberate,
//  user-visible hint that a new segment started (words right at the boundary
//  can be lost — the user can spot it and repeat themselves).
//
//  See TranscriptionEngine.swift for the full one-shot contract.
// ─────────────────────────────────────────────────────────────────────

@MainActor
final class SFSpeechEngine: TranscriptionEngine {

    // MARK: - Lifecycle

    /// One-way: idle → starting → recording → finishing → finished.
    /// (`cancel()` may jump to .finished from anywhere.)
    private enum State { case idle, starting, recording, finishing, finished }
    private var state: State = .idle

    // MARK: - Recognition

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    // MARK: - Transcript (single home: sealed segments + live partial)

    private var sealedSegments: [String] = []
    private var partial = ""

    private var updates: AsyncThrowingStream<String, Error>.Continuation?
    /// Resumed exactly once when the final result (or an error) arrives while
    /// finishing. finish()'s timeout guarantees it can never wait forever.
    private var finishWaiter: CheckedContinuation<Void, Never>?

    // MARK: - Init

    init(locale: Locale) {
        let r = SFSpeechRecognizer(locale: locale)
        r?.queue = .main // recognition callbacks arrive on the main queue
        recognizer = r
    }

    // MARK: - TranscriptionEngine

    func start() async throws -> AsyncThrowingStream<String, Error> {
        precondition(state == .idle, "SFSpeechEngine is one-shot — create a new instance per recording.")
        state = .starting
        diag("start(): available=\(recognizer?.isAvailable ?? false) "
             + "supportsOnDevice=\(recognizer?.supportsOnDeviceRecognition ?? false) "
             + "auth=\(SFSpeechRecognizer.authorizationStatus().rawValue)")
        // NOTE: on-device recognition (supportsOnDevice=true) has NO ~60 s cap
        // — such sessions may never hit a segment boundary at all. The
        // stitching below is event-driven: it engages only when iOS actually
        // force-finalizes (network-based sessions, silence finalization).

        do {
            guard let recognizer else { throw TranscriptionError.unavailable }

            // 1. Authorization.
            let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
            try checkpoint()
            guard status == .authorized else { throw TranscriptionError.notAuthorized }

            // 2. Availability — the recognizer can lag behind authorization.
            var retries = 5
            while !recognizer.isAvailable, retries > 0 {
                diag("recognizer not yet available — retrying in 0.4s (\(retries) attempts left)")
                try await Task.sleep(nanoseconds: 400_000_000) // throws on cancellation
                try checkpoint()
                retries -= 1
            }
            guard recognizer.isAvailable else { throw TranscriptionError.unavailable }

            // 3. Audio session + microphone tap.
            try startAudioCapture()

            // 4. Stream first, then the recognition task, so no callback can
            //    arrive before there is a continuation to publish to.
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            updates = continuation
            beginRecognitionTask()

            state = .recording
            UIApplication.shared.isIdleTimerDisabled = true
            return stream
        } catch {
            teardown()
            state = .finished
            throw error
        }
    }

    func finish() async -> String {
        guard state == .recording else {
            // Never went live, already finished, or a concurrent finish is in
            // flight — return what we have, immediately (bounded by nature).
            if state == .starting { cancel() }
            return transcript
        }
        state = .finishing
        audioEngine.stop()
        request?.endAudio()

        // Wait for the recognizer's final result — but never longer than the
        // bound. (The pre-refactor implementation could await a continuation
        // nobody resumes; this one cannot.)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            finishWaiter = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.resumeFinishWaiter() // no-op when already resumed
            }
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
        resumeFinishWaiter() // unblock a concurrent finish(), if any
        updates?.finish()
        updates = nil
    }

    // MARK: - Capture

    private func startAudioCapture() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // setActive(true)/audioEngine.start() are synchronous audio-server
            // calls — if the app ever freezes here, the last diag line below
            // names the blocker.
            diag("activating audio session…")
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            diag("audio session active")
        } catch {
            throw TranscriptionError.audioCapture(key: "speech_recording_failed", detail: error.localizedDescription)
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // A zero format means the microphone isn't bridged (e.g. simulator).
        guard format.sampleRate > 0, format.channelCount > 0 else {
            diag("input node has an INVALID format (sampleRate=\(format.sampleRate) channels=\(format.channelCount))")
            throw TranscriptionError.unavailable
        }

        // Installed ONCE per engine. Segment restarts swap `request`, not the
        // tap — audio flows uninterrupted across the ~60 s boundary.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // Realtime audio thread; appending to the current request is the
            // same pattern the pre-refactor implementation used.
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        do {
            diag("starting audio engine…")
            try audioEngine.start()
            diag("audio engine running")
        } catch {
            throw TranscriptionError.audioCapture(key: "speech_microphone_failed", detail: error.localizedDescription)
        }
    }

    private func beginRecognitionTask() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Delivered on the main queue (recognizer.queue = .main).
            guard let self else { return }
            MainActor.assumeIsolated {
                // Identity guard: callbacks from a superseded task (segment
                // restart, forced boundary, teardown) are stale — a cancelled
                // task can still emit a trailing error. Ignore them entirely.
                guard self.request === request else { return }
                if let result { self.handleResult(result) }
                if let error { self.handleTaskError(error) }
            }
        }
    }

    #if DEBUG
    /// Simulates the system's force-finalization: seals the current partial
    /// and restarts the recognition task — the exact code path a real
    /// boundary takes. On-device recognition never hits the real ~60 s cap,
    /// so this is the deterministic way to verify stitching on any device.
    /// Trigger: tap the "STT:" debug label in the composer.
    func debugForceSegmentBoundary() {
        guard state == .recording else { return }
        diag("DEBUG: forced segment boundary")
        sealPartial()
        publishTranscript()
        task?.cancel() // its trailing callbacks are stale (identity guard)
        task = nil
        beginRecognitionTask()
    }
    #endif

    // MARK: - Recognition callbacks

    private func handleResult(_ result: SFSpeechRecognitionResult) {
        partial = result.bestTranscription.formattedString
        publishTranscript()

        guard result.isFinal else { return }

        switch state {
        case .finishing:
            // This is the final result finish() is waiting for.
            resumeFinishWaiter()
        case .recording:
            // ~1-minute boundary: iOS finalized the task on its own. Seal the
            // segment and keep listening on a fresh task; the tap keeps
            // feeding audio, only request/task are replaced.
            diag("system finalization at segment boundary — restarting task")
            sealPartial()
            publishTranscript()
            task = nil
            beginRecognitionTask()
        case .idle, .starting, .finished:
            break // stale callback after teardown
        }
    }

    private func handleTaskError(_ error: Error) {
        diag("recognition error: \(describe(error)) | transcriptChars=\(transcript.count)")

        switch state {
        case .finishing:
            resumeFinishWaiter() // finish() returns whatever we have
        case .recording:
            // Mid-recording failure: tear down, then surface through the
            // stream. The session decides what happens to salvaged content.
            teardown()
            state = .finished
            updates?.finish(throwing: mapped(error))
            updates = nil
        case .idle, .starting, .finished:
            break // start() throws its own errors; late callbacks are stale
        }
    }

    // MARK: - Transcript stitching

    /// The single reading of this engine's transcript:
    /// sealed segments joined as paragraphs, plus the live partial.
    private var transcript: String {
        var parts = sealedSegments
        let live = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty { parts.append(live) }
        return parts.joined(separator: "\n\n")
    }

    private func publishTranscript() {
        updates?.yield(transcript)
    }

    private func sealPartial() {
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        guard !text.isEmpty else { return }
        sealedSegments.append(Self.ensuringTerminalPunctuation(text))
        diag("sealed segment #\(sealedSegments.count) (\(text.count) chars)")
    }

    /// "…I needed to say" → "…I needed to say." — the fullstop that closes a
    /// sealed segment so the following paragraph reads as a fresh sentence.
    static func ensuringTerminalPunctuation(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?…。！？".contains(last) ? text : text + "."
    }

    // MARK: - Teardown

    private func resumeFinishWaiter() {
        finishWaiter?.resume()
        finishWaiter = nil
    }

    /// Idempotent hardware/task teardown — safe to call in any state, twice.
    ///
    /// The AVAudioSession is deliberately NOT deactivated here. Deactivating
    /// between recognitions makes the NEXT `setActive(true)` /
    /// `audioEngine.start()` block the main thread for many seconds while
    /// the audio server tears down the previous input unit — observed as a
    /// full UI freeze on the second recording (device). Leaving the session
    /// active matches the field-proven pre-refactor behavior. Do not "fix"
    /// this by adding `setActive(false)`.
    private func teardown() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Throws when the surrounding task was cancelled or cancel() ran while
    /// start() was suspended — the mic must never go live after either.
    private func checkpoint() throws {
        guard state == .starting else { throw CancellationError() }
        try Task.checkCancellation()
    }

    // MARK: - Error mapping & diagnostics

    private func mapped(_ error: Error) -> TranscriptionError {
        #if targetEnvironment(simulator)
        return .unavailable
        #else
        let ns = error as NSError
        if ns.domain == "kLSRErrorDomain"
            || ns.localizedDescription.localizedCaseInsensitiveContains("recognizer")
            || ns.localizedDescription.localizedCaseInsensitiveContains("asset") {
            return .unavailable
        }
        return .engine(detail: ns.localizedDescription)
        #endif
    }

    /// Filter the Xcode console by "[SFSpeechEngine]" to trace the pipeline.
    private func diag(_ message: String) {
        print("[SFSpeechEngine] \(message)")
    }

    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        var parts = ["domain=\(ns.domain)", "code=\(ns.code)", "desc=\(ns.localizedDescription)"]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=(domain=\(underlying.domain) code=\(underlying.code) desc=\(underlying.localizedDescription))")
        }
        return parts.joined(separator: " ")
    }
}
