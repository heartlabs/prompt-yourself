import PhotosUI
import SwiftUI

// MARK: - Profile Draft

/// Owns the in-flight edit state so no global side effects happen before an
/// explicit save. Discard cleans up orphaned files; commit atomically applies
/// all three values (name, language, photo).
struct ProfileDraft {
    var name: String
    var language: AppLanguage

    private let initialPhotoPath: String?
    private var newPhotoPath: String?
    private var didCommit = false

    init(currentName: String, currentLanguage: AppLanguage, currentPhotoPath: String?) {
        self.name = currentName
        self.language = currentLanguage
        self.initialPhotoPath = currentPhotoPath
        self.newPhotoPath = nil
    }

    /// The photo path to display — the newly picked one, or the original.
    var displayPhotoPath: String? { newPhotoPath ?? initialPhotoPath }

    /// Call when the PhotosPicker yields a saved image path.
    mutating func photoPicked(_ path: String) {
        newPhotoPath = path
    }

    /// Persist all edits atomically. Old photo file is deleted only on commit
    /// (never before), so swiping away the sheet leaves everything untouched.
    mutating func commit() {
        didCommit = true
        UserName.save(name.trimmingCharacters(in: .whitespaces))

        if let new = newPhotoPath {
            ProfilePicture.save(new)
            if let old = initialPhotoPath {
                ImageUtils.deleteImage(relativePath: old)
            }
        }
    }

    /// Called when the sheet is dismissed without saving. Deletes the newly
    /// picked photo file (if any) so it doesn't linger on disk as an orphan.
    func discard() {
        guard !didCommit else { return }
        if let new = newPhotoPath {
            ImageUtils.deleteImage(relativePath: new)
        }
    }
}

// MARK: - Edit Profile View

/// A sheet for editing the user's profile picture, display name, and language
/// preference. Uses `ProfileDraft` so no global state changes before Save.
struct EditProfileView: View {
    @ObservedObject private var loc = LocalizationService.shared
    @State private var draft: ProfileDraft
    @State private var pickerItem: PhotosPickerItem?
    @State private var isPickerPresented = false

    @Environment(\.dismiss) private var dismiss

    init() {
        _draft = State(initialValue: ProfileDraft(
            currentName: UserName.current ?? "",
            currentLanguage: LocalizationService.shared.currentLanguage,
            currentPhotoPath: ProfilePicture.current
        ))
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Profile photo
            VStack(spacing: 8) {
                Button {
                    isPickerPresented = true
                } label: {
                    profilePhotoView
                }
                .buttonStyle(.plain)

                Text(loc.localized("change_profile_picture"))
                    .font(.echoSubheadline)
                    .foregroundColor(.sageGreen)
            }

            Text(loc.localized("edit_profile_title"))
                .font(.title2.weight(.semibold))
                .foregroundColor(.taupeText)

            // Language picker
            VStack(spacing: 8) {
                Text(loc.localized("select_language"))
                    .font(.body)
                    .foregroundColor(.taupeText.opacity(0.65))

                Picker("", selection: $draft.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .tint(.sageGreen)
            }

            Text(loc.localized("name_prompt"))
                .font(.body)
                .foregroundColor(.taupeText.opacity(0.65))

            TextField(loc.localized("name_placeholder"), text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .autocorrectionDisabled()
                .frame(maxWidth: 240)
                .onSubmit(save)

            Button(loc.localized("save")) {
                save()
            }
            .buttonStyle(.borderedProminent)
            .tint(.sageGreen)
            .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.warmIvory)
        .preferredColorScheme(.light)
        .photosPicker(isPresented: $isPickerPresented, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, newItem in
            guard let item = newItem else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    if let path = ImageUtils.saveImage(image) {
                        draft.photoPicked(path)
                    }
                }
            }
        }
        .onDisappear { draft.discard() }
    }

    private var profilePhotoView: some View {
        ZStack {
            if let path = draft.displayPhotoPath,
               let uiImage = ImageUtils.loadImage(relativePath: path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color.sageGreen)

                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(Circle())
    }

    private func save() {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        LocalizationService.shared.setLanguage(draft.language)
        draft.commit()
        dismiss()
    }
}

#Preview {
    EditProfileView()
}
