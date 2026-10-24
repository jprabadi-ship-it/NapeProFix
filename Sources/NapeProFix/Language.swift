import Foundation

/// The UI language, chosen from the menu or the settings window.
///
/// Kept out of `Settings` on purpose: it changes nothing about how events are
/// handled, so it has no business in the snapshot the taps read.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case japanese = "ja"
    case english = "en"

    var id: String { rawValue }

    private static let key = "language"

    /// Unset means `system`, so existing installs on a Japanese Mac see no
    /// change.
    static var preference: AppLanguage {
        get {
            UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:))
                ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// `system` follows the first language in macOS's preferred list:
    /// Japanese when it is Japanese, English for everything else.
    var usesJapanese: Bool {
        switch self {
        case .japanese: return true
        case .english:  return false
        case .system:   return Locale.preferredLanguages.first?.hasPrefix("ja") ?? false
        }
    }

    /// Each language is named in itself, so the choice is readable whichever
    /// language the UI is currently in.
    var label: String {
        switch self {
        case .system:   return tr("システムに合わせる", "Match System")
        case .japanese: return "日本語"
        case .english:  return "English"
        }
    }
}

/// Picks the string for the current UI language. Both are written side by side
/// at the call site, so a missing translation cannot slip through.
func tr(_ japanese: String, _ english: String) -> String {
    AppLanguage.preference.usesJapanese ? japanese : english
}
