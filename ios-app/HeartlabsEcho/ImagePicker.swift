import PhotosUI
import SwiftUI

// MARK: - PhotoButton

/// A button that opens the system photo picker and returns the selected image.
///
/// Usage: embed in any view, bind the selection to a callback.
struct PhotoButton: View {
    let isEnabled: Bool
    let onImagePicked: (UIImage) -> Void

    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var isLoading = false

    var body: some View {
        PhotosPicker(
            selection: $pickerItem,
            matching: .images,
            photoLibrary: .shared()
        ) {
            // Secondary control: smaller and softly tinted so the mic reads as
            // the primary action.
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(isEnabled ? .sageGreen : Color.gray)
                .frame(width: 46, height: 46)
                .background(Color.sageGreen.opacity(isEnabled ? 0.14 : 0.06))
                .clipShape(Circle())
        }
        .disabled(!isEnabled || isLoading)
        .onChange(of: pickerItem) { _, newItem in
            guard let item = newItem else { return }
            isLoading = true
            Task {
                defer { isLoading = false }
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await MainActor.run {
                        onImagePicked(image)
                    }
                }
            }
            pickerItem = nil
        }
    }
}
