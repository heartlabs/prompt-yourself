import SwiftUI

// MARK: - Recent Memories Gallery

/// A full-screen gallery showing all photo memories in a vertical grid.
///
/// Receives photos from the caller — does NOT load its own data. The caller
/// (`CalendarView`) gets photos from `CalendarViewModel.loadAllPhotos()` at
/// intent time (when "See All" is tapped).
struct RecentMemoriesGalleryView: View {
    @ObservedObject private var loc = LocalizationService.shared
    let photos: [MemoryPhoto]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhotoPath: String?

    /// Three columns for the grid.
    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(photos) { photo in
                        Button {
                            selectedPhotoPath = photo.path
                        } label: {
                            CachedAsyncImage(path: photo.path, placeholderSize: CGSize(width: 100, height: 130)) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(height: 130)
                                    .clipped()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .background(Color.warmIvory)
            .navigationTitle(loc.localized("all_memories"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.taupeText)
                    }
                }
            }
        }
        .preferredColorScheme(.light)
        .fullScreenCover(isPresented: Binding(
            get: { selectedPhotoPath != nil },
            set: { if !$0 { selectedPhotoPath = nil } }
        )) {
            if let path = selectedPhotoPath {
                FullScreenPhotoView(path: path)
            }
        }
    }
}
