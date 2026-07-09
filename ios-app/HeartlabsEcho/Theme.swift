import SwiftUI

// MARK: - Color Palette

extension Color {
    /// Warm ivory background (#F5F2EB)
    static let warmIvory = Color(red: 0.961, green: 0.949, blue: 0.922)

    /// Muted sage green accent (#8A9A86)
    static let sageGreen = Color(red: 0.541, green: 0.604, blue: 0.525)

    /// Semi-transparent sage green for the middle mic ring
    static let sageGreenSemibright = Color.sageGreen.opacity(0.4)

    /// Very faint sage green for the outer mic ring
    static let sageGreenFaint = Color.sageGreen.opacity(0.15)

    /// Soft taupe for assistant chat bubbles
    static let softTaupe = Color(red: 0.871, green: 0.851, blue: 0.831)

    /// Slightly darker taupe for text on light backgrounds
    static let taupeText = Color(red: 0.471, green: 0.431, blue: 0.400)

}

// MARK: - User Name

/// Persists the user's display name in UserDefaults.
enum UserName {
    private static let key = "user_display_name"

    /// The stored name, or `nil` if not set.
    static var current: String? {
        UserDefaults.standard.string(forKey: key)
    }

    /// Returns `true` if a non-empty name has been saved.
    static var isSet: Bool {
        guard let name = current else { return false }
        return !name.isEmpty
    }

    /// Saves a trimmed name. Does nothing if the string is empty.
    static func save(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: key)
    }

    /// Removes the stored name (resets onboarding).
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Greeting Helper

/// Returns a warm time-appropriate greeting string, optionally personalised.
func timeAwareGreeting() -> String {
    let hour = Calendar.current.component(.hour, from: Date())
    let base: String
    switch hour {
    case 5..<12:
        base = "Good morning"
    case 12..<17:
        base = "Good afternoon"
    default:
        base = "Good evening"
    }
    if let name = UserName.current, !name.isEmpty {
        return "\(base), \(name)"
    }
    return base
}
