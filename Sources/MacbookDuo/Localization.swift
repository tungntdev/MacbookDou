import Foundation

/// Which language the UI uses. `.system` follows the user's macOS language
/// list; the other two pin a specific language regardless of system
/// settings.
enum AppLanguage: String, CaseIterable {
    case system
    case english = "en"
    case vietnamese = "vi"

    var displayName: String {
        switch self {
        case .system: return L("language.system")
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        }
    }
}

private let languageStorageKey = "settingsLanguage"

enum AppLanguageStore {
    /// Before the user has ever touched the language picker, default to
    /// Vietnamese rather than `.system` — `.system` would pick whichever of
    /// the user's macOS languages matches first, which for a bilingual
    /// `en-VN`/`vi-VN` list picks English.
    static var current: AppLanguage {
        get {
            guard let stored = UserDefaults.standard.string(forKey: languageStorageKey) else { return .vietnamese }
            return AppLanguage(rawValue: stored) ?? .vietnamese
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: languageStorageKey) }
    }
}

/// Where `Localizable.strings` actually lives, resolved once.
///
/// This deliberately avoids SwiftPM's generated `Bundle.module` accessor:
/// that accessor looks for the resource bundle next to
/// `Bundle.main.bundleURL`, which for a packaged `.app` is the bundle's own
/// top level — a location codesign refuses to seal, so `build.sh` instead
/// flattens the `*.lproj` folders straight into `Contents/Resources`, the
/// standard place `Bundle.main` already knows to search. The `swift run` /
/// raw-executable case (no real `.app` around it) falls back to the
/// SwiftPM-generated bundle sitting next to the binary.
private let localizationBundle: Bundle = {
    if Bundle.main.path(forResource: "en", ofType: "lproj") != nil {
        return Bundle.main
    }
    let sideBySide = Bundle.main.bundleURL.appendingPathComponent("MacbookDuo_MacbookDuo.bundle")
    if let bundle = Bundle(url: sideBySide), bundle.path(forResource: "en", ofType: "lproj") != nil {
        return bundle
    }
    return Bundle.main
}()

/// Looks `key` up in the chosen language's `Localizable.strings`, falling
/// back to the base (English) table — or, failing that, the key itself —
/// if the language bundle can't be found. Never crashes: a missing
/// localization should show slightly wrong text, not take the app down.
func L(_ key: String) -> String {
    let language = AppLanguageStore.current
    if language != .system,
       let path = localizationBundle.path(forResource: language.rawValue, ofType: "lproj"),
       let bundle = Bundle(path: path) {
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
    return localizationBundle.localizedString(forKey: key, value: nil, table: nil)
}
