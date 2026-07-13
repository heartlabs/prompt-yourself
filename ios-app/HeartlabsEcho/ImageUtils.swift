import os
import SwiftUI
import UIKit

// MARK: - Image Cache

/// In-memory LRU cache for decoded `UIImage` and raw `Data` objects.
/// `NSCache` is thread-safe and auto-evicts under memory pressure.
private final class ImageCache {
    private let imageStore = NSCache<NSString, UIImage>()
    private let dataStore = NSCache<NSString, NSData>()

    init() {
        imageStore.countLimit = 50
        dataStore.countLimit = 20
    }

    func image(for key: String) -> UIImage? {
        imageStore.object(forKey: key as NSString)
    }

    func setImage(_ image: UIImage, for key: String) {
        imageStore.setObject(image, forKey: key as NSString)
    }

    func data(for key: String) -> Data? {
        dataStore.object(forKey: key as NSString) as Data?
    }

    func setData(_ data: Data, for key: String) {
        dataStore.setObject(data as NSData, forKey: key as NSString)
    }

    func removeAll(for key: String) {
        imageStore.removeObject(forKey: key as NSString)
        dataStore.removeObject(forKey: key as NSString)
    }
}

private let imageCache = ImageCache()

// MARK: - Image Utilities

/// Maximum dimension (width or height) for stored images.
private let maxDimension: CGFloat = 2048

/// JPEG compression quality for stored images.
private let compressionQuality: CGFloat = 0.8

/// Relative path prefix inside the Documents directory.
private let attachmentsDir = "attachments"

/// Created once — not on every access (was a performance issue: syscall per image op).
private let attachmentsURL: URL = {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let dir = docs.appendingPathComponent(attachmentsDir, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

enum ImageUtils {

    /// Compresses and saves a picked image to the app sandbox.
    ///
    /// - Parameter image: The image to store.
    /// - Returns: A relative path (e.g. `"attachments/uuid.jpg"`), or `nil` on failure.
    @discardableResult
    static func saveImage(_ image: UIImage) -> String? {
        guard let data = compress(image) else { return nil }
        let filename = "\(UUID().uuidString).jpg"
        let fileURL = attachmentsURL.appendingPathComponent(filename)
        do {
            try data.write(to: fileURL)
            return "\(attachmentsDir)/\(filename)"
        } catch {
            Logger.images.error("Failed to write image: \(error)")
            return nil
        }
    }

    /// Loads an image from the app sandbox by its relative path.
    ///
    /// Checks the in-memory cache first; falls back to async disk I/O off the
    /// main thread. The decoded `UIImage` is cached for subsequent accesses.
    ///
    /// - Parameter relativePath: e.g. `"attachments/uuid.jpg"`.
    /// - Returns: The image, or `nil` if not found.
    static func loadImage(relativePath: String) async -> UIImage? {
        // Cache hit — no suspension needed.
        if let cached = imageCache.image(for: relativePath) {
            return cached
        }
        // Disk I/O off the main thread.
        let url = attachmentsURL.appendingPathComponent(
            URL(fileURLWithPath: relativePath).lastPathComponent
        )
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        imageCache.setImage(image, for: relativePath)
        return image
    }

    /// Loads raw image data from the app sandbox by its relative path.
    ///
    /// Checks the in-memory cache first; falls back to async disk I/O off the
    /// main thread. The raw data is cached for subsequent accesses.
    ///
    /// - Parameter relativePath: e.g. `"attachments/uuid.jpg"`.
    /// - Returns: The raw JPEG data, or `nil` if not found.
    static func loadImageData(relativePath: String) async -> Data? {
        if let cached = imageCache.data(for: relativePath) {
            return cached
        }
        let url = attachmentsURL.appendingPathComponent(
            URL(fileURLWithPath: relativePath).lastPathComponent
        )
        guard let data = try? Data(contentsOf: url) else { return nil }
        imageCache.setData(data, for: relativePath)
        return data
    }

    /// Deletes an image file from the app sandbox. Also evicts it from the
    /// in-memory cache so stale images never reappear.
    ///
    /// - Parameter relativePath: e.g. `"attachments/uuid.jpg"`.
    static func deleteImage(relativePath: String) {
        let fileURL = attachmentsURL.appendingPathComponent(
            URL(fileURLWithPath: relativePath).lastPathComponent
        )
        try? FileManager.default.removeItem(at: fileURL)
        // Evict from in-memory cache so stale images don't reappear.
        imageCache.removeAll(for: relativePath)
    }

    // MARK: - Compression

    /// Compresses and optionally resizes an image to JPEG data.
    private static func compress(_ image: UIImage) -> Data? {
        let size = image.size
        let maxSide = max(size.width, size.height)

        guard maxSide > maxDimension else {
            return image.jpegData(compressionQuality: compressionQuality)
        }

        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return resized?.jpegData(compressionQuality: compressionQuality)
    }
}

// MARK: - Cached Async Image (SwiftUI)

/// A SwiftUI view that asynchronously loads an image from disk (with in-memory
/// caching) and renders it off the main thread. Replaces the old pattern of
/// `if let img = ImageUtils.loadImage(path) { Image(uiImage: img) }` which
/// blocked the main thread on every render.
///
/// Usage:
/// ```swift
/// CachedAsyncImage(path: "attachments/abc.jpg") { image in
///     image.resizable().scaledToFill().frame(width: 100, height: 100)
/// }
/// ```
struct CachedAsyncImage<Content: View>: View {
    let path: String
    var placeholderSize: CGSize? = nil
    @ViewBuilder let content: (Image) -> Content

    @State private var uiImage: UIImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let img = uiImage {
                content(Image(uiImage: img))
            } else if loadFailed {
                brokenImagePlaceholder
            } else {
                loadingPlaceholder
            }
        }
        .task(id: path) {
            loadFailed = false
            if let loaded = await ImageUtils.loadImage(relativePath: path) {
                uiImage = loaded
            } else {
                loadFailed = true
            }
        }
    }

    @ViewBuilder
    private var loadingPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.softTaupe.opacity(0.25))
            ProgressView()
                .tint(.sageGreen)
        }
        .frame(idealWidth: placeholderSize?.width, idealHeight: placeholderSize?.height)
        .frame(minHeight: 60)
    }

    @ViewBuilder
    private var brokenImagePlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.softTaupe.opacity(0.18))
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(.textTertiary)
        }
        .frame(idealWidth: placeholderSize?.width, idealHeight: placeholderSize?.height)
        .frame(minHeight: 60)
    }
}
