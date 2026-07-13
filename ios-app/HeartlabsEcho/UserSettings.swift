import SwiftUI
import os

// MARK: - Shared Logger

/// Centralised os.Logger categories so every `print(...)` becomes a typed,
/// structured log that ships only in DEBUG builds and can be filtered in Console.
extension Logger {
    /// General app-level events.
    static let app = Logger(subsystem: "com.heartlabsecho", category: "general")
    /// LLM/API communication (LLMService, ModelRouter).
    static let llm = Logger(subsystem: "com.heartlabsecho", category: "llm")
    /// Persistence layer (ConversationService, SwiftData errors).
    static let storage = Logger(subsystem: "com.heartlabsecho", category: "storage")
    /// Speech recognition (SFSpeechEngine).
    static let speech = Logger(subsystem: "com.heartlabsecho", category: "speech")
    /// Goal service operations.
    static let goals = Logger(subsystem: "com.heartlabsecho", category: "goals")
    /// Chat message and conversation pipeline events.
    static let chat = Logger(subsystem: "com.heartlabsecho", category: "chat")
    /// Summary generation.
    static let summary = Logger(subsystem: "com.heartlabsecho", category: "summary")
    /// Image I/O utilities.
    static let images = Logger(subsystem: "com.heartlabsecho", category: "images")
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

// MARK: - Profile Picture

/// Persists the relative path of the user's profile picture in UserDefaults.
/// The actual image file is stored in the app's attachments directory via `ImageUtils`.
enum ProfilePicture {
    /// The UserDefaults key — internal so `ProfileCircleView` can reference the
    /// same source of truth instead of re-typing the string literal.
    static let key = "user_profile_picture_path"

    /// The stored relative path (e.g. "attachments/uuid.jpg"), or `nil` if not set.
    static var current: String? {
        UserDefaults.standard.string(forKey: key)
    }

    /// Returns `true` if a profile picture has been saved.
    static var isSet: Bool {
        guard let path = current else { return false }
        return !path.isEmpty
    }

    /// Saves the relative path.
    static func save(_ path: String) {
        UserDefaults.standard.set(path, forKey: key)
    }

    /// Removes the stored path (does NOT delete the image file).
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - App Language

/// Supported app languages for UI and speech recognition.
enum AppLanguage: String, CaseIterable, Codable {
    case english = "en"
    case german = "de"
    case russian = "ru"

    /// Native display name for the language picker.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .german:  return "Deutsch"
        case .russian: return "Русский"
        }
    }

    /// Locale identifier for `SFSpeechRecognizer` (e.g. "en-US", "de-DE").
    var sttLocaleIdentifier: String {
        switch self {
        case .english: return "en-US"
        case .german:  return "de-DE"
        case .russian: return "ru-RU"
        }
    }

    /// BCP-47 tag for instructing the LLM which language to respond in.
    var languageTag: String {
        rawValue
    }

    /// The `Locale` corresponding to this language (used for date formatting, etc.).
    var locale: Locale {
        Locale(identifier: languageTag)
    }

    /// A snippet prepended to the system prompt so the LLM responds in this language.
    /// Returns empty string for English (the prompt is already English).
    var languageInstruction: String {
        switch self {
        case .english: return ""
        case .german:  return "Always respond in German.\n"
        case .russian: return "Always respond in Russian.\n"
        }
    }
}

// MARK: - App Language Persistence

extension AppLanguage {
    private static let key = "app_language"

    /// The stored language, or the detected system language if not yet set.
    static var current: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let lang = AppLanguage(rawValue: raw)
        else {
            return detectFromSystem()
        }
        return lang
    }

    /// Detects the language from the system locale, falling back to English.
    static func detectFromSystem() -> AppLanguage {
        guard let code = Locale.current.language.languageCode?.identifier else { return .english }
        // Map known codes; "de" → .german, "ru" → .russian, everything else → .english
        switch code {
        case "de": return .german
        case "ru": return .russian
        default:   return .english
        }
    }

    /// Persists the chosen language.
    static func save(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: key)
    }

    /// Removes the stored language (resets to system detection).
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Orb Coachmark

/// Tracks how many voice compositions the user has sent, so the "Tap to talk"
/// coach label under the chat orb can retire once the orb is learned.
enum OrbCoachmark {
    private static let key = "orb_compositions_sent"
    /// After this many successful sends the label disappears for good.
    private static let learnedThreshold = 3

    /// Whether the user has sent enough compositions to drop the label.
    static var isLearned: Bool {
        UserDefaults.standard.integer(forKey: key) >= learnedThreshold
    }

    /// Records one successful composition send. Call ONLY when a composition
    /// actually went out (a `.sent` outcome) — never for taps, cancels, or
    /// failed attempts, or the label retires before the orb is learned.
    static func recordCompositionSent() {
        guard !isLearned else { return }
        let count = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(count + 1, forKey: key)
    }
}

// MARK: - Greeting Helper

/// Returns a warm time-appropriate greeting string, optionally personalised.
@MainActor
func timeAwareGreeting() -> String {
    let hour = Calendar.current.component(.hour, from: Date())
    let base: String
    switch hour {
    case 5..<12:
        base = LocalizationService.shared.localized("greeting_morning")
    case 12..<17:
        base = LocalizationService.shared.localized("greeting_afternoon")
    default:
        base = LocalizationService.shared.localized("greeting_evening")
    }
    if let name = UserName.current, !name.isEmpty {
        return "\(base), \(name)"
    }
    return base
}

// MARK: - Profile Circle

/// A circular profile picture view. Shows the user's photo if set, otherwise
/// displays a sage green circle with a pencil icon inside.
///
/// Uses `@AppStorage` so SwiftUI re-renders when the profile picture is
/// saved or removed (e.g. after dismissing the edit profile sheet).
struct ProfileCircleView: View {
    let diameter: CGFloat

    @AppStorage(ProfilePicture.key) private var photoPath: String?

    var body: some View {
        ZStack {
            if let path = photoPath {
                CachedAsyncImage(path: path, placeholderSize: CGSize(width: diameter, height: diameter)) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: diameter, height: diameter)
                        .clipShape(Circle())
                }
            } else {
                Circle()
                    .fill(Color.sageGreen)
                    .frame(width: diameter, height: diameter)

                Image(systemName: "pencil")
                    .font(.system(size: diameter * 0.4, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .contentShape(Circle())
    }
}
