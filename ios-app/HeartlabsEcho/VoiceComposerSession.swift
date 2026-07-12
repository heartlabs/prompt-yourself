import Combine
import Foundation

// ─────────────────────────────────────────────────────────────────────
//  VoiceComposerSession — the composer's single source of truth
//
//  One session = one presentation of the voice composer. Created by
//  ConversationEngine.beginComposition(); the overlay is visible exactly
//  while `activeComposition` is non-nil, and the ONLY way it disappears is
//  this session reaching .finished — no dismiss call exists anywhere.
//
//  All composer state lives here (phase, transcript, photoPath, error) and
//  is mutated only by the intent methods. Every intent is a TOTAL switch
//  over Phase: adding a phase refuses to compile until every intent decides
//  what it means. Views render this state and forward gestures; they hold
//  no lifecycle state of their own.
//
//  Ownership rules enforced here:
//   • the engine — created fresh per recording attempt, never reused, always
//     torn down through finish()/cancel() before the session terminates
//   • the picked photo file — deleted on cancel/failure, transferred into
//     the Composition on send: exactly one place touches the filesystem
// ─────────────────────────────────────────────────────────────────────

// MARK: - Composition

/// The finished product of one composer session: what the user said and
/// attached. Constructible ONLY by a terminating session (fileprivate init),
/// so holding a Composition is proof that the microphone is off and the
/// transcript is final — "send while recording" has no code path.
struct Composition: Equatable {
    /// Final transcript, whitespace-trimmed. Empty for photo-only compositions.
    let transcript: String
    /// Relative path of the attached photo, if any. File ownership transfers
    /// to the message that persists it.
    let photoPath: String?

    fileprivate init(transcript: String, photoPath: String?) {
        self.transcript = transcript
        self.photoPath = photoPath
    }
}

// MARK: - VoiceComposerSession

@MainActor
final class VoiceComposerSession: ObservableObject {

    // MARK: Phase

    /// Where the session is in its life — stored truth, never derived from
    /// booleans. The intent methods below ARE the transition table: each one
    /// is an exhaustive switch over these cases, so every (intent × phase)
    /// combination is a deliberate decision, including the no-ops.
    enum Phase: Equatable {
        /// Engine spinning up (permission, audio session). Mic not yet live;
        /// the whole path is abortable and the mic can never go live after
        /// an abort.
        case startingRecording
        /// Mic is live; cumulative transcript snapshots are streaming in.
        case recording
        /// The photo flow owns the screen; the mic is OFF. The sheet itself
        /// appears only once the mic is confirmed off (`pickerVisible`), and
        /// the phase persists through the 300 ms dismissal grace period.
        case pickingPhoto(pickerVisible: Bool)
        /// Mic off, content held; awaiting send / discard / re-record.
        /// Also the recovery state after an engine failure with content.
        case reviewing
        /// Terminal transition in flight (bounded finalize, cleanup). Every
        /// intent is a no-op here — double-taps and tap-vs-swipe races are
        /// structurally harmless, no guard flags needed.
        case finishing
        /// Done. ConversationEngine consumes the outcome and clears
        /// `activeComposition`, which unmounts the overlay.
        case finished(Outcome)
    }

    enum Outcome: Equatable {
        case sent(Composition)
        case cancelled
        case failed(message: String)
    }

    // MARK: Published state — ALL the composer state there is

    @Published private(set) var phase: Phase = .startingRecording
    /// Cumulative transcript — the single home of the text. Long dictations
    /// arrive already stitched into paragraphs by SFSpeechEngine.
    @Published private(set) var transcript = ""
    /// Relative path of the picked photo. The file is owned by this session
    /// until it is sent (transferred) or discarded (deleted).
    @Published private(set) var photoPath: String?
    /// User-facing error shown while the composer is open (engine failures
    /// with salvageable content). Cleared by the alert binding.
    @Published var errorMessage: String?

    #if DEBUG
    /// Which TranscriptionEngine implementation this session is using.
    @Published private(set) var engineName = "…"

    /// Verifies the segment-stitching path on demand (see
    /// `SFSpeechEngine.debugForceSegmentBoundary`). No-op on the iOS 26
    /// engine, which has no boundary to stitch.
    func debugForceSegmentBoundary() {
        (engine as? SFSpeechEngine)?.debugForceSegmentBoundary()
    }
    #endif

    // MARK: Private

    private var engine: (any TranscriptionEngine)?
    /// Runs factory + engine.start() + stream consumption for one attempt.
    private var recordingTask: Task<Void, Never>?
    /// The 300 ms picker-dismissal grace timer (see `pickerDismissed()`).
    private var graceTask: Task<Void, Never>?
    /// Reports the outcome exactly once (see `terminate`).
    private let onFinish: (Outcome) -> Void

    /// Creating a session IS starting to listen: the composer can never be
    /// presented without a recording attempt underway.
    init(onFinish: @escaping (Outcome) -> Void) {
        self.onFinish = onFinish
        startRecordingAttempt()
    }

    // MARK: - Intents (user)
    //
    // Each intent is a TOTAL switch over Phase. When you add a phase, the
    // compiler stops you here until every intent decides how to handle it.

    /// The orb — the composer's single button. Meaning depends on phase.
    func orbTapped() {
        switch phase {
        case .startingRecording:
            // Changed their mind before the mic went live. Abort; keep a
            // held photo (back to reviewing), otherwise close.
            abortRecordingAttempt()
            if photoPath != nil { phase = .reviewing } else { finish(.cancel) }
        case .recording:
            finish(hasContent ? .send : .cancel)
        case .reviewing:
            // With text: send. Photo-only: the orb shows a mic — record.
            if hasTranscript { finish(.send) } else { startRecordingAttempt() }
        case .pickingPhoto, .finishing, .finished:
            break
        }
    }

    /// The photo chip. Rendered only while no photo is held.
    func photoButtonTapped() {
        switch phase {
        case .startingRecording:
            // Mic never went live — abort and open the picker directly.
            abortRecordingAttempt()
            phase = .pickingPhoto(pickerVisible: true)
        case .recording:
            // Finalize FIRST — the mic must be OFF while the picker is open.
            // The sheet is presented only once the engine is done.
            phase = .pickingPhoto(pickerVisible: false)
            recordingTask?.cancel()
            recordingTask = nil
            let engine = self.engine
            self.engine = nil
            Task { [weak self] in
                guard let self else { return }
                if let engine { self.transcript = await engine.finish() }
                // Present the sheet unless something (backgrounding) already
                // moved the session on.
                if case .pickingPhoto(pickerVisible: false) = self.phase {
                    self.phase = .pickingPhoto(pickerVisible: true)
                }
            }
        case .reviewing:
            if photoPath == nil { phase = .pickingPhoto(pickerVisible: true) }
        case .pickingPhoto, .finishing, .finished:
            break
        }
    }

    /// The picker reported a selection (before the image data is loaded).
    /// Cancels the dismissal grace so a slow-publishing pick is never
    /// misread as a cancel.
    func photoSelectionArrived() {
        guard case .pickingPhoto = phase else { return }
        graceTask?.cancel()
        graceTask = nil
    }

    /// The picked image finished loading and saving (`path` nil ⇒ it failed).
    func photoPicked(path: String?) {
        guard case .pickingPhoto = phase else {
            // The session already moved on (grace elapsed, backgrounded) —
            // never leak the saved file.
            if let path { ImageUtils.deleteImage(relativePath: path) }
            return
        }
        graceTask?.cancel()
        graceTask = nil
        if let path {
            photoPath = path
            phase = .reviewing
        } else if hasTranscript {
            phase = .reviewing
        } else {
            finish(.cancel)
        }
    }

    /// The picker sheet was dismissed. A real pick can publish AFTER the
    /// dismissal lands, so wait 300 ms before treating it as a cancel.
    /// This grace period is load-bearing: deciding immediately misreads
    /// real picks as cancels and drops the photo. Do not remove it.
    func pickerDismissed() {
        guard case .pickingPhoto(pickerVisible: true) = phase else { return }
        phase = .pickingPhoto(pickerVisible: false)
        graceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            guard case .pickingPhoto = self.phase else { return }
            if self.hasTranscript { self.phase = .reviewing } else { self.finish(.cancel) }
        }
    }

    /// Swipe-down anywhere: discard everything.
    func cancelRequested() {
        switch phase {
        case .startingRecording:
            abortRecordingAttempt()
            finish(.cancel)
        case .recording, .reviewing:
            finish(.cancel)
        case .pickingPhoto, .finishing, .finished:
            break // the sheet owns gestures; finishing/finished are terminal
        }
    }

    /// The app is going to background (lock, app switcher, incoming call).
    /// Policy: never lose speech — send what exists (photo included), else
    /// close clean. A composition that was worth 10 minutes of talking must
    /// not depend on the user coming back.
    func appDidEnterBackground() {
        switch phase {
        case .startingRecording:
            abortRecordingAttempt()
            finish(photoPath != nil ? .send : .cancel)
        case .recording:
            finish(hasContent ? .send : .cancel)
        case .pickingPhoto:
            // A not-yet-picked photo was never part of the composition.
            graceTask?.cancel()
            graceTask = nil
            finish(hasTranscript ? .send : .cancel)
        case .reviewing:
            finish(.send) // reviewing always holds content
        case .finishing, .finished:
            break
        }
    }

    // MARK: - Derived state (for rendering — no view may compute its own)

    var hasTranscript: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasContent: Bool { hasTranscript || photoPath != nil }

    /// Mirrors the pre-refactor glyph rules exactly:
    /// arrow.up = something to send · mic = photo waiting for its voice-over ·
    /// nil = breathing sphere.
    var orbGlyph: String? {
        if hasTranscript { return "arrow.up" }
        if photoPath != nil {
            if case .recording = phase { return nil }
            return "mic"
        }
        return nil
    }

    var isListening: Bool { phase == .recording }

    var isOrbEnabled: Bool {
        switch phase {
        case .startingRecording, .recording, .reviewing: return true
        case .pickingPhoto, .finishing, .finished: return false
        }
    }

    /// The chip is disabled while a terminal transition or the picker flow
    /// is underway (it is hidden entirely once a photo is held).
    var isPhotoButtonEnabled: Bool {
        switch phase {
        case .startingRecording, .recording, .reviewing: return true
        case .pickingPhoto, .finishing, .finished: return false
        }
    }

    /// Binding target for `.photosPicker(isPresented:)`.
    var isPickerPresented: Bool { phase == .pickingPhoto(pickerVisible: true) }

    // MARK: - Recording attempts

    /// Starts one recording attempt with a FRESH engine. Only reachable with
    /// an empty transcript (initial start, or photo-only reviewing) — a
    /// recording never overwrites existing speech.
    private func startRecordingAttempt() {
        assert(!hasTranscript, "a recording attempt must never overwrite existing speech")
        phase = .startingRecording
        transcript = ""
        recordingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let engine = await TranscriptionEngineFactory.make()
                try Task.checkCancellation()
                self.engine = engine
                #if DEBUG
                self.engineName = String(describing: type(of: engine))
                #endif
                let updates = try await engine.start()
                // Mic is live — but an abort may have raced the last await;
                // in that case the aborting intent owns the state (and has
                // already cancelled the engine).
                guard case .startingRecording = self.phase, !Task.isCancelled else { return }
                self.phase = .recording
                for try await text in updates {
                    self.transcript = text
                }
                // Stream ended cleanly: finish()/cancel() ran and owns state.
            } catch is CancellationError {
                // Deliberate abort — the aborting intent owns state + teardown.
            } catch {
                self.handleEngineFailure(error)
            }
        }
    }

    /// Cancels an in-flight start. The engine's cancellation checkpoints
    /// guarantee the microphone cannot go live afterwards.
    private func abortRecordingAttempt() {
        recordingTask?.cancel()
        recordingTask = nil
        engine?.cancel()
        engine = nil
    }

    /// A recording attempt failed (before or while capturing). With content —
    /// even just a held photo — the composer stays open so the user decides;
    /// with nothing, the session fails and the chat screen shows the alert.
    private func handleEngineFailure(_ error: Error) {
        engine = nil // the engine tore itself down before surfacing this
        let message = (error as? TranscriptionError)?.userMessage
            ?? String(format: LocalizationService.shared.localized("speech_recognition_failed"),
                      error.localizedDescription)
        switch phase {
        case .startingRecording, .recording:
            if hasContent {
                errorMessage = message
                phase = .reviewing
            } else {
                terminate(.failed(message: message))
            }
        case .pickingPhoto, .reviewing, .finishing, .finished:
            break // stale — another path already owns the state
        }
    }

    // MARK: - Finishing (the ONLY way out)

    private enum FinishAction { case send, cancel }

    /// Runs the terminal transition. Idempotent by phase: once `.finishing`,
    /// every further intent is a no-op, so races (double-tap, tap+swipe,
    /// backgrounding during a send) collapse into the first action.
    private func finish(_ action: FinishAction) {
        switch phase {
        case .finishing, .finished:
            return
        case .startingRecording, .recording, .pickingPhoto, .reviewing:
            break
        }
        phase = .finishing
        graceTask?.cancel()
        graceTask = nil
        recordingTask?.cancel()
        recordingTask = nil
        let engine = self.engine
        self.engine = nil

        Task {
            switch action {
            case .send:
                if let engine {
                    // Bounded: the best final transcript within ~1.5 s.
                    transcript = await engine.finish()
                }
                let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty && photoPath == nil {
                    // Nothing salvageable after the final read — close clean.
                    terminate(.cancelled)
                } else {
                    let composition = Composition(transcript: text, photoPath: photoPath)
                    terminate(.sent(composition))
                    // Ownership transferred to the message; cleared only after
                    // the overlay is gone so the preview never flickers.
                    photoPath = nil
                }
            case .cancel:
                engine?.cancel()
                if let photoPath {
                    ImageUtils.deleteImage(relativePath: photoPath)
                    self.photoPath = nil
                }
                terminate(.cancelled)
            }
        }
    }

    /// The terminal transition — happens at most once, reports exactly once.
    private func terminate(_ outcome: Outcome) {
        if case .finished = phase { return }
        phase = .finished(outcome)
        onFinish(outcome)
    }
}
