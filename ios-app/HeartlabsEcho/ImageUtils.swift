import UIKit

// MARK: - Image Utilities

/// Maximum dimension (width or height) for stored images.
private let maxDimension: CGFloat = 2048

/// JPEG compression quality for stored images.
private let compressionQuality: CGFloat = 0.8

/// Relative path prefix inside the Documents directory.
private let attachmentsDir = "attachments"

/// The full URL to the attachments directory inside the app sandbox.
private var attachmentsURL: URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let dir = docs.appendingPathComponent(attachmentsDir, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

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
            print("[ImageUtils] Failed to write image: \(error)")
            return nil
        }
    }

    /// Loads an image from the app sandbox by its relative path.
    ///
    /// - Parameter relativePath: e.g. `"attachments/uuid.jpg"`.
    /// - Returns: The image, or `nil` if not found.
    static func loadImage(relativePath: String) -> UIImage? {
        guard let data = loadImageData(relativePath: relativePath) else { return nil }
        return UIImage(data: data)
    }

    /// Loads raw image data from the app sandbox by its relative path.
    ///
    /// - Parameter relativePath: e.g. `"attachments/uuid.jpg"`.
    /// - Returns: The raw JPEG data, or `nil` if not found.
    static func loadImageData(relativePath: String) -> Data? {
        let fileURL = attachmentsURL.appendingPathComponent(
            URL(fileURLWithPath: relativePath).lastPathComponent
        )
        return try? Data(contentsOf: fileURL)
    }

    /// Deletes an image file from the app sandbox.
    ///
    /// - Parameter relativePath: e.g. `"attachments/uuid.jpg"`.
    static func deleteImage(relativePath: String) {
        let fileURL = attachmentsURL.appendingPathComponent(
            URL(fileURLWithPath: relativePath).lastPathComponent
        )
        try? FileManager.default.removeItem(at: fileURL)
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
