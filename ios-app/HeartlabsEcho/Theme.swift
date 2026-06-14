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

// MARK: - Greeting Helper

/// Returns a warm time-appropriate greeting string.
func timeAwareGreeting() -> String {
    let hour = Calendar.current.component(.hour, from: Date())
    switch hour {
    case 5..<12:
        return "Good morning"
    case 12..<17:
        return "Good afternoon"
    default:
        return "Good evening"
    }
}
