import PhotosUI
import SwiftUI

// MARK: - Edit Profile View

/// A sheet for editing the user's profile picture, display name, and language
/// preference. Pre-populated with the current values.
struct EditProfileView: View {
    @ObservedObject private var loc = LocalizationService.shared
    @State private var name: String
    @State private var selectedLanguage: AppLanguage
    @State private var profilePhotoPath: String?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isPickerPresented = false

    @Environment(\.dismiss) private var dismiss

    init() {
        // Pre-populate with current values.
        _name = State(initialValue: UserName.current ?? "")
        _selectedLanguage = State(initialValue: LocalizationService.shared.currentLanguage)
        _profilePhotoPath = State(initialValue: ProfilePicture.current)
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

                Picker("", selection: $selectedLanguage) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .tint(.sageGreen)
                .onChange(of: selectedLanguage) { _, newLang in
                    LocalizationService.shared.setLanguage(newLang)
                }
            }

            Text(loc.localized("name_prompt"))
                .font(.body)
                .foregroundColor(.taupeText.opacity(0.65))

            TextField(loc.localized("name_placeholder"), text: $name)
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
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)

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
                    // Remove the old file before saving the new one.
                    if let oldPath = profilePhotoPath {
                        ImageUtils.deleteImage(relativePath: oldPath)
                    }
                    let path = ImageUtils.saveImage(image)
                    profilePhotoPath = path
                }
            }
        }
    }

    /// The profile photo circle — shows the current (or newly picked) photo,
    /// or a sage green circle with a camera icon centered inside if none is set.
    private var profilePhotoView: some View {
        ZStack {
            if let path = profilePhotoPath,
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
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        LocalizationService.shared.setLanguage(selectedLanguage)
        UserName.save(trimmed)
        if let path = profilePhotoPath {
            ProfilePicture.save(path)
        } else {
            // User removed the photo — delete the file before clearing the reference.
            if let oldPath = ProfilePicture.current {
                ImageUtils.deleteImage(relativePath: oldPath)
            }
            ProfilePicture.clear()
        }
        dismiss()
    }
}

#Preview {
    EditProfileView()
}
