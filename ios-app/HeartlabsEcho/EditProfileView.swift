import SwiftUI

// MARK: - Edit Profile View

/// A sheet for editing the user's display name and language preference.
/// Pre-populated with the current values, mirroring the onboarding form layout.
struct EditProfileView: View {
    @ObservedObject private var loc = LocalizationService.shared
    @State private var name: String
    @State private var selectedLanguage: AppLanguage

    @Environment(\.dismiss) private var dismiss

    init() {
        // Pre-populate with current values.
        _name = State(initialValue: UserName.current ?? "")
        _selectedLanguage = State(initialValue: LocalizationService.shared.currentLanguage)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "leaf.fill")
                .font(.system(size: 48))
                .foregroundColor(.sageGreen)

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
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        LocalizationService.shared.setLanguage(selectedLanguage)
        UserName.save(trimmed)
        dismiss()
    }
}

#Preview {
    EditProfileView()
}
