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
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 56, height: 56)
                .background(isEnabled ? Color.sageGreen : Color.gray)
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
