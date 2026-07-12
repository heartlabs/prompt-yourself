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

// MARK: - Profile Picture

/// Persists the relative path of the user's profile picture in UserDefaults.
/// The actual image file is stored in the app's attachments directory via `ImageUtils`.
enum ProfilePicture {
    private static let key = "user_profile_picture_path"

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

// MARK: - Semantic Colors

extension Color {
    /// Solid card surface — a warm near-white that reads clearly above the ivory canvas.
    static let cardSurface = Color(red: 0.996, green: 0.992, blue: 0.984)

    /// Hairline card border for gentle edge definition on the warm background.
    static let cardBorder = Color.softTaupe.opacity(0.22)

    /// Primary text — the warm taupe used for titles and body copy.
    static let textPrimary = Color.taupeText

    /// Secondary text — supporting labels, descriptions, captions.
    static let textSecondary = Color.taupeText.opacity(0.6)

    /// Tertiary text — the faintest labels, placeholders, and group headers.
    static let textTertiary = Color.taupeText.opacity(0.4)
}

// MARK: - Typography
//
// One shared type scale for the whole app. Serif is reserved for display
// moments (hero names, screen titles, statistics); the system sans carries
// body copy, labels, and controls. Call sites use `.font(.echoTitle)` etc.
// so sizes/weights live in ONE place instead of being hardcoded per screen.

extension Font {
    /// Serif hero title, e.g. the profile name. 34 / medium.
    static let echoLargeTitle = Font.system(size: 34, weight: .medium, design: .serif)
    /// Serif screen / section title, e.g. "Goals" or the month header. 28 / medium.
    static let echoTitle = Font.system(size: 28, weight: .medium, design: .serif)
    /// Serif statistic number. 32 / medium.
    static let echoNumber = Font.system(size: 32, weight: .medium, design: .serif)
    /// Serif live transcription in conversation mode — spoken words rendered
    /// like a journal entry, not terminal output. 30 / medium.
    static let echoLiveTranscript = Font.system(size: 30, weight: .medium, design: .serif)

    /// Section title within a screen, e.g. "Today, July 11". 20 / semibold.
    static let echoSectionTitle = Font.system(size: 20, weight: .semibold)
    /// Card title. 17 / semibold.
    static let echoCardTitle = Font.system(size: 17, weight: .semibold)
    /// Body copy and chat text. 16 / regular.
    static let echoBody = Font.system(size: 16, weight: .regular)
    /// Secondary body / descriptions. 14 / regular.
    static let echoSubheadline = Font.system(size: 14, weight: .regular)
    /// Caption. 13 / regular.
    static let echoCaption = Font.system(size: 13, weight: .regular)
    /// Small emphasized group label, e.g. "Active" / "Completed". 13 / semibold.
    static let echoGroupLabel = Font.system(size: 13, weight: .semibold)
    /// Micro label under stats and calendar days. 12 / regular.
    static let echoMicroLabel = Font.system(size: 12, weight: .regular)
}

// MARK: - Layout Tokens

/// Shared spacing, corner-radius, and shadow values. Namespaced under `Theme`
/// to keep call sites explicit (`Theme.Spacing.l`, `Theme.Radius.card`).
enum Theme {
    /// A 4-based spacing scale.
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Corner radii.
    enum Radius {
        static let small: CGFloat = 10
        static let card: CGFloat = 16
    }

    /// The single soft shadow used by every card surface.
    enum CardShadow {
        static let color = Color.black.opacity(0.05)
        static let radius: CGFloat = 8
        static let x: CGFloat = 0
        static let y: CGFloat = 3
    }

    /// Every size the companion-orb system uses, in one place. These values
    /// are INTERDEPENDENT — the chat band must be shorter than the chat orb
    /// (that's the pop-out), the fade must cover the overlap, and the photo
    /// chip hangs off the composer orb's lower-right — so change them here,
    /// together. Never inline orb-related sizes at a call site.
    enum Orb {
        /// The resting orb at the bottom of the chat.
        static let chatDiameter: CGFloat = 64
        /// The larger orb on the empty-day moodboard.
        static let moodboardDiameter: CGFloat = 96
        /// The hero orb inside conversation mode.
        static let composerDiameter: CGFloat = 130

        /// Fraction of the chat orb's height reserved as the chat's bottom
        /// band; the remainder of the orb pops out above it.
        static let bandFraction: CGFloat = 0.75
        /// How far the band's ivory fade dissolves upward over the chat.
        static let bandFade: CGFloat = 32

        /// Reserved band height at the bottom of the chat.
        static var bandHeight: CGFloat { chatDiameter * bandFraction }

        /// The photo chip's offset from the composer orb's center — derived
        /// from the orb size so the chip stays attached to the orb's
        /// lower-right if the diameter ever changes.
        static var chipOffset: CGSize {
            CGSize(width: composerDiameter * 0.71, height: composerDiameter * 0.35)
        }
    }
}

// MARK: - Card Container

/// The one reusable card surface used across every screen: warm surface,
/// hairline border, soft shadow, and a consistent corner radius. Replaces the
/// two divergent card idioms (solid-white+shadow vs. 50%-white+stroke).
struct EchoCardModifier: ViewModifier {
    var padding: CGFloat = Theme.Spacing.l

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color.cardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(Color.cardBorder, lineWidth: 1)
            )
            .shadow(
                color: Theme.CardShadow.color,
                radius: Theme.CardShadow.radius,
                x: Theme.CardShadow.x,
                y: Theme.CardShadow.y
            )
    }
}

extension View {
    /// Wraps the view in the shared card surface. Pass `padding:` to override.
    func echoCard(padding: CGFloat = Theme.Spacing.l) -> some View {
        modifier(EchoCardModifier(padding: padding))
    }
}

// MARK: - Shared Text Styles

/// A serif screen title (e.g. "Goals"). Left-aligned by default; pass
/// `centered: true` for hero placement (e.g. the profile name).
struct ScreenTitle: View {
    let text: String
    var centered: Bool = false

    var body: some View {
        Text(text)
            .font(.echoLargeTitle)
            .foregroundColor(.textPrimary)
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }
}

/// A section title within a screen (e.g. "Today, July 11").
struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.echoSectionTitle)
            .foregroundColor(.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small, muted, letter-spaced label above a group of cards
/// (e.g. "Active", "Completed").
struct GroupLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.echoGroupLabel)
            .tracking(0.6)
            .foregroundColor(.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Profile Circle

/// A circular profile picture view. Shows the user's photo if set, otherwise
/// displays a sage green circle with a pencil icon inside.
///
/// Uses `@AppStorage` so SwiftUI re-renders when the profile picture is
/// saved or removed (e.g. after dismissing the edit profile sheet).
struct ProfileCircleView: View {
    let diameter: CGFloat

    @AppStorage("user_profile_picture_path") private var photoPath: String?

    var body: some View {
        ZStack {
            if let path = photoPath,
               let uiImage = ImageUtils.loadImage(relativePath: path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
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
