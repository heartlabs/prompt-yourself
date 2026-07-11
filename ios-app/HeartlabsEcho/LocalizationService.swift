import Foundation
import SwiftUI

// MARK: - LocalizationService

/// Observable service that provides localized strings for the currently
/// selected `AppLanguage`. Views observe this via `@ObservedObject` and
/// re-render when the language changes at runtime.
@MainActor
final class LocalizationService: ObservableObject {
    static let shared = LocalizationService()

    /// The active language. Changing it persists the choice, reloads the
    /// string table, and notifies all observers.
    @Published var currentLanguage: AppLanguage {
        didSet {
            AppLanguage.save(currentLanguage)
            reloadStrings()
        }
    }

    /// Loaded key→value pairs from the current language's `.strings` file.
    private var strings: [String: String] = [:]

    private init() {
        self.currentLanguage = AppLanguage.current
        reloadStrings()
    }

    /// Returns the localized string for `key`, or the key itself as fallback.
    func localized(_ key: String) -> String {
        strings[key] ?? key
    }

    /// Sets the language, persists it, reloads strings, and notifies observers.
    func setLanguage(_ language: AppLanguage) {
        currentLanguage = language
    }

    // MARK: - Private

    private func reloadStrings() {
        guard let path = Bundle.main.path(forResource: currentLanguage.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path),
              let stringsPath = bundle.path(forResource: "Localizable", ofType: "strings"),
              let dict = NSDictionary(contentsOfFile: stringsPath) as? [String: String]
        else {
            strings = [:]
            return
        }
        strings = dict
    }
}
