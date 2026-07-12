import Foundation

// ─────────────────────────────────────────────────────────────────────
//  TranscriptionEngine — one-shot speech-to-text capture
//
//  One engine instance drives exactly ONE recording:
//
//      let engine  = await TranscriptionEngineFactory.make()
//      let updates = try await engine.start()      // mic is live on return
//      for try await text in updates { … }         // cumulative snapshots
//      let final   = await engine.finish()         // bounded — never hangs
//
//  Contract (both implementations):
//   • start() may be called once. It is cooperatively cancellable: cancelling
//     the surrounding task (or calling cancel()) while start() is suspended
//     tears the engine down and throws CancellationError — the microphone
//     can never go live after an abort.
//   • The stream yields the WHOLE transcript so far (never deltas). It ends
//     when the engine is finished/cancelled, or throws TranscriptionError on
//     a mid-recording failure (the engine has torn itself down by then).
//   • finish() stops capture and returns the best final transcript within a
//     short bounded wait. Safe to call in any state; can never hang the UI.
//   • cancel() stops capture immediately and discards pending results.
//   • Engines hold no UI state and know nothing about the composer. The
//     single writer of user-visible state is VoiceComposerSession.
//
//  There are exactly two implementations — do not add a third:
//    • SpeechAnalyzerEngine — iOS 26+, on-device ML (used only when the
//      model assets are already installed)
//    • SFSpeechEngine       — iOS 17+, server-based fallback
// ─────────────────────────────────────────────────────────────────────

@MainActor
protocol TranscriptionEngine: AnyObject {
    /// Begin capture. Returns when the microphone is live.
    /// One-shot: calling this a second time is a programmer error.
    func start() async throws -> AsyncThrowingStream<String, Error>

    /// Stop capture and return the final transcript. Bounded (~1.5 s): races
    /// the recognizer's final result against a timeout, so it always returns.
    func finish() async -> String

    /// Stop capture immediately, discarding pending results.
    func cancel()
}

// MARK: - Errors

/// Every way a recording can fail, with the user-facing message mapping in
/// one place. `start()` throws these; mid-recording failures arrive through
/// the update stream.
enum TranscriptionError: Error {
    /// Speech recognition permission is denied/restricted.
    case notAuthorized
    /// No recognizer for this device/locale (also: simulator without a mic).
    case unavailable
    /// The audio session or microphone could not be started.
    /// `key` is the Localizable format-string key, `detail` fills its %@.
    case audioCapture(key: String, detail: String)
    /// The recognition engine reported an error after capture started.
    case engine(detail: String)

    @MainActor
    var userMessage: String {
        let loc = LocalizationService.shared
        switch self {
        case .notAuthorized:
            return loc.localized("speech_permission_off")
        case .unavailable:
            #if targetEnvironment(simulator)
            return loc.localized("speech_unavailable_simulator")
            #else
            return loc.localized("speech_unavailable_network")
            #endif
        case .audioCapture(let key, let detail):
            return String(format: loc.localized(key), detail)
        case .engine(let detail):
            return String(format: loc.localized("speech_recognition_failed"), detail)
        }
    }
}

// MARK: - Factory

/// Chooses the best engine for the CURRENT recording.
///
/// Runs once per recording attempt (not once per process), so:
///  • a language switch applies to the next recording — no app relaunch
///  • a device that installs the iOS 26 on-device model later upgrades to
///    `SpeechAnalyzerEngine` on the next recording
///  • without the model, iOS 26 devices keep falling back to
///    `SFSpeechEngine`. We deliberately never trigger the asset download.
enum TranscriptionEngineFactory {
    @MainActor
    static func make() async -> any TranscriptionEngine {
        let locale = Locale(identifier: AppLanguage.current.sttLocaleIdentifier)
        if #available(iOS 26, *) {
            if await SpeechAnalyzerEngine.assetsInstalled(for: locale) {
                return SpeechAnalyzerEngine(locale: locale)
            }
        }
        return SFSpeechEngine(locale: locale)
    }
}
