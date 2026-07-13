import PhotosUI
import SwiftUI

// ─────────────────────────────────────────────────────────────────────
//  ConversationModeView — the voice composer overlay
//
//  A stateless renderer over VoiceComposerSession: it draws phase /
//  transcript / photo and forwards gestures as intents. It owns NO
//  lifecycle state (the PhotosPicker item below is UIKit plumbing, not
//  composer state) and it has no way to dismiss itself — the overlay
//  unmounts when the session terminates and ConversationEngine clears
//  `activeComposition`.
//
//  Adding behaviour? Add or change an INTENT on VoiceComposerSession.
//  Never mutate state, touch the engine, or add view-local flags here.
// ─────────────────────────────────────────────────────────────────────

struct ConversationModeView: View {
    @ObservedObject var session: VoiceComposerSession
    @ObservedObject private var loc = LocalizationService.shared
    let style: ConversationStyle

    /// PhotosUI plumbing only. A selection reaches the session in two steps:
    /// `photoSelectionArrived()` the moment the item publishes (cancels the
    /// dismissal grace), `photoPicked(path:)` once the data is loaded+saved.
    @State private var pickerItem: PhotosPickerItem?

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
        #if DEBUG
        .overlay(alignment: .topTrailing) {
            // Tap to force a segment boundary (verifies the 60 s stitching
            // path — on-device recognition never hits the real cap).
            Text(session.engineName == "…" ? "" : "STT: \(session.engineName)")
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundColor(.textTertiary.opacity(0.5))
                .padding(.trailing, Theme.Spacing.m)
                .contentShape(Rectangle())
                .onTapGesture { session.debugForceSegmentBoundary() }
        }
        #endif
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                if value.translation.height > 80 { session.cancelRequested() }
            }
        )
        .photosPicker(isPresented: pickerBinding, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, newItem in
            guard let item = newItem else { return }
            session.photoSelectionArrived()
            Task {
                var path: String?
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    path = ImageUtils.saveImage(image)
                }
                pickerItem = nil
                session.photoPicked(path: path)
            }
        }
        .alert(loc.localized("speech_recognition_alert"), isPresented: errorBinding) {
            Button(loc.localized("ok_button"), role: .cancel) { }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    // MARK: - Bindings

    private var pickerBinding: Binding<Bool> {
        Binding(
            get: { session.isPickerPresented },
            set: { presented in if !presented { session.pickerDismissed() } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { session.errorMessage != nil },
            set: { presented in if !presented { session.errorMessage = nil } }
        )
    }

    // MARK: - Subviews

    private var transcriptArea: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: Theme.Spacing.m) {
                // Photo preview — shown whenever a photo is held, regardless
                // of whether speech has been added yet.
                if let photoPath = session.photoPath {
                    CachedAsyncImage(path: photoPath, placeholderSize: CGSize(width: 240, height: 180)) { image in
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .padding(.horizontal)
                }

                Text(displayTranscript)
                    .font(.echoLiveTranscript)
                    .foregroundColor(session.transcript.isEmpty ? .textTertiary : .textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Theme.Spacing.xxl)
                    .padding(.vertical, Theme.Spacing.xl)
                    .animation(.easeOut(duration: 0.2), value: displayTranscript)
            }
        }
        .defaultScrollAnchor(.bottom)
        // The transcript is a live stream, not a reading surface (reviewing
        // happens in the chat after sending). Manual scrolling stays disabled
        // so swipe-down-to-cancel wins everywhere on this screen — the anchor
        // keeps the newest words in view as the text grows.
        .scrollDisabled(true)
    }

    private var displayTranscript: String {
        session.transcript.isEmpty ? loc.localized("listening_placeholder") : session.transcript
    }

    private var orbArea: some View {
        ZStack {
            CompanionOrbView(
                style: style,
                diameter: Theme.Orb.composerDiameter,
                isListening: session.isListening,
                isEnabled: session.isOrbEnabled,
                glyph: session.orbGlyph
            ) {
                session.orbTapped()
            }

            // Hidden once a photo is held — one photo per message; swipe
            // down to start over.
            if session.photoPath == nil {
                photoChip
                    .offset(x: Theme.Orb.chipOffset.width, y: Theme.Orb.chipOffset.height)
            }
        }
    }

    private var photoChip: some View {
        Button(action: { session.photoButtonTapped() }) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(style.accent.opacity(0.8))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!session.isPhotoButtonEnabled)
    }
}
