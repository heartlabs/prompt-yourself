import PhotosUI
import SwiftUI

// MARK: - ConversationModeView

/// The immersive voice composer ("conversation mode") — the only place where
/// recording happens.
///
/// Presented full-screen over the whole app while the user speaks: the live
/// transcript in serif display type, a listening orb, and a photo chip. The
/// mode is a pure *composer* — every exit path lands back in the chat view,
/// where the assistant's reply arrives as a normal bubble.
///
///  * tap the orb        → send the transcript
///  * tap the photo chip → recording stops (mic off while browsing),
///                         the system photo picker opens:
///       – pick          → send transcript (if any), then the image
///       – cancel        → send transcript (if any) — same as a normal finish
///  * swipe down         → discard everything, nothing is sent
///
/// The composition is either speech, speech followed by a photo, or a photo
/// alone (when nothing was said) — see `ConversationEngine.sendComposition`.
struct ConversationModeView: View {
    @ObservedObject var viewModel: ConversationEngine
    @ObservedObject private var loc = LocalizationService.shared
    let style: ConversationStyle
    /// Closes the overlay. Any sending has already been kicked off by then.
    let dismiss: () -> Void

    @State private var isPickerPresented = false
    @State private var pickerItem: PhotosPickerItem?
    /// Set the moment an exit path is chosen — makes every action idempotent
    /// (double-taps, gesture + tap races, recognizer callbacks).
    @State private var isFinishing = false
    /// Set while the photo flow owns the recording stop, so the
    /// recording-ended watcher doesn't mistake it for an error.
    @State private var isPickingPhoto = false

    var body: some View {
        ZStack {
            Color.warmIvory.ignoresSafeArea()

            VStack(spacing: 0) {
                transcriptArea
                    .frame(maxHeight: .infinity)

                orbArea
                    .padding(.bottom, Theme.Spacing.xl)

                Text(loc.localized("tap_to_send_cancel"))
                    .font(.echoCaption)
                    .foregroundColor(.textTertiary)
                    .padding(.bottom, Theme.Spacing.m)
            }
            .padding(.top, Theme.Spacing.xxl)
        }
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                if value.translation.height > 80 { finish(.cancel) }
            }
        )
        .photosPicker(isPresented: $isPickerPresented, selection: $pickerItem, matching: .images)
        .onAppear {
            // The composer owns its recording lifecycle: being presented means
            // listening starts, and every exit stops it (see `finish`). No
            // caller can present a composer that isn't actually listening.
            if !viewModel.recognizer.isRecording {
                viewModel.recognizer.startTranscribing()
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let item = newItem else { return }
            Task {
                var path: String?
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    path = ImageUtils.saveImage(image)
                }
                finish(.send(imagePath: path))
            }
        }
        .onChange(of: isPickerPresented) { _, presented in
            guard !presented, isPickingPhoto, !isFinishing else { return }
            handlePickerDismissed()
        }
        .onChange(of: viewModel.recognizer.isRecording) { _, recording in
            // Recording ended without user action: on an error the recognizer
            // already salvaged + sent any partial transcript (pendingTranscript)
            // or surfaced an alert — either way this composer is done.
            if !recording && !isFinishing && !isPickingPhoto {
                finish(.recognizerEnded)
            }
        }
        .onChange(of: viewModel.recognizer.recognitionError) { _, error in
            // Recording never started (e.g. permission denied) — close so the
            // user lands where the alert presents.
            if error != nil && !isFinishing {
                finish(.recognizerEnded)
            }
        }
    }

    // MARK: - Subviews

    private var transcriptArea: some View {
        ScrollView(showsIndicators: false) {
            Text(displayTranscript)
                .font(.echoLiveTranscript)
                .foregroundColor(hasTranscript ? .textPrimary : .textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.vertical, Theme.Spacing.xl)
                .animation(.easeOut(duration: 0.2), value: displayTranscript)
        }
        .defaultScrollAnchor(.bottom)
        // The transcript is a live stream, not a reading surface (reviewing
        // happens in the chat after sending). Manual scrolling is disabled so
        // the swipe-down-to-cancel gesture works anywhere on the screen —
        // the anchor keeps the newest words in view as the text grows.
        .scrollDisabled(true)
    }

    private var orbArea: some View {
        ZStack {
            CompanionOrbView(
                style: style,
                diameter: Theme.Orb.composerDiameter,
                isListening: viewModel.recognizer.isRecording,
                isEnabled: !isFinishing
            ) {
                finish(.send(imagePath: nil))
            }

            photoChip
                .offset(x: Theme.Orb.chipOffset.width, y: Theme.Orb.chipOffset.height)
        }
    }

    private var photoChip: some View {
        Button(action: openPhotoPicker) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(style.accent.opacity(0.8))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isFinishing || isPickingPhoto)
    }

    private var hasTranscript: Bool {
        !viewModel.recognizer.transcript.isEmpty
    }

    private var displayTranscript: String {
        hasTranscript ? viewModel.recognizer.transcript : loc.localized("listening_placeholder")
    }

    // MARK: - Exit Paths
    //
    // EVERY way out of conversation mode funnels through `finish(_:)` — the
    // only place allowed to stop the recognizer, send, and dismiss. Adding a
    // new exit? Add a case to `ExitReason` and let the switch force you to
    // decide what happens to the microphone and the composition. Never call
    // `dismiss()` or the recognizer directly from a new code path.

    private enum ExitReason {
        /// The user finished composing — send the transcript (if any) and the
        /// optional image as one composition.
        case send(imagePath: String?)
        /// The user backed out — stop the mic, send nothing.
        case cancel
        /// The recognizer stopped on its own (error, background). The engine
        /// has already salvaged or surfaced whatever there was; just close.
        case recognizerEnded
    }

    private func finish(_ reason: ExitReason) {
        guard !isFinishing else { return }
        isFinishing = true
        Task {
            switch reason {
            case .send(let imagePath):
                await finalizeRecording()
                if viewModel.sendComposition(imagePath: imagePath) {
                    // A real composition went out — the orb is being learned.
                    OrbCoachmark.recordCompositionSent()
                }
            case .cancel:
                viewModel.recognizer.stopTranscribing()
            case .recognizerEnded:
                break
            }
            dismiss()
        }
    }

    /// Stops the microphone and waits for the recognizer's final result, so
    /// `sendComposition` reads the complete transcript.
    private func finalizeRecording() async {
        if viewModel.recognizer.isRecording {
            await viewModel.recognizer.stopTranscribingAsync()
        } else {
            // Recording may still be spinning up (authorization) — make sure
            // it can't go live behind the picker or after dismissal.
            viewModel.recognizer.stopTranscribing()
        }
    }

    private func openPhotoPicker() {
        guard !isFinishing, !isPickingPhoto else { return }
        isPickingPhoto = true
        Task {
            await finalizeRecording()   // mic is off before the picker opens
            isPickerPresented = true
        }
    }

    /// The system picker was dismissed. If nothing was picked, this is a
    /// cancel — which behaves like a normal finish (any speech still sends).
    /// The 300ms grace period is load-bearing: dismissal can land BEFORE the
    /// selection publishes, so deciding immediately would mis-read a pick as
    /// a cancel and drop the photo.
    private func handlePickerDismissed() {
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if pickerItem == nil {
                finish(.send(imagePath: nil))
            }
        }
    }
}
