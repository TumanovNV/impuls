import Foundation

/// The language Impuls was told to use, as opposed to the one macOS picked for it.
///
/// `system` is not a language: it is the absence of a choice, which is why it has
/// no localisation code. Every other case carries the `.lproj` name verbatim, so
/// the preference, the bundle folder and the value written into `AppleLanguages`
/// are all the same string and cannot drift apart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case russian = "ru"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"

    var id: String { rawValue }

    /// The localisation this choice asks the bundle for, or `nil` for "let macOS decide".
    var localizationCode: String? { self == .system ? nil : rawValue }

    /// The language's own name for itself.
    ///
    /// Deliberately not translated and deliberately not a localisation key: a
    /// language picker that renames the languages per interface language is
    /// unusable for the person looking for the one they can actually read. The
    /// call site must render these with `Text(verbatim:)`, or SwiftUI turns them
    /// into `LocalizedStringKey` lookups for keys no table contains.
    var endonym: String {
        switch self {
        case .system: return ""
        case .english: return "English"
        case .russian: return "Русский"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .spanish: return "Español"
        case .simplifiedChinese: return "简体中文"
        case .japanese: return "日本語"
        }
    }
}

/// Owns the app's language preference — and is the only part of Impuls allowed to.
///
/// Two keys are involved and they mean different things. `app.language.v1` is the
/// choice made *inside Impuls*. `AppleLanguages` is the macOS mechanism through
/// which that choice takes effect on the next launch, and it can exist for reasons
/// that have nothing to do with Impuls: the user may have set a per-app language in
/// macOS itself, or the process may have been launched with an override. So reading
/// this service's state never writes either key — in particular, a missing, `system`
/// or unparsable preference leaves an existing `AppleLanguages` completely alone.
/// Only an explicit choice in Settings touches it.
///
/// The switch is not applied to the running process. 439 keys go through the
/// `localized` helper, but another 108 call sites are SwiftUI literals resolved
/// through `Bundle.main` inside SwiftUI itself; redirecting the former without the latter
/// would leave the panel half in one language and half in another. Reaching those
/// would need `Bundle.main` class substitution or the loss of SwiftUI's literal
/// localisation, so the choice is persisted and takes effect at the next launch,
/// where it also reaches `InfoPlist.strings` and the date formatters.
@MainActor
final class AppLanguageService: ObservableObject {
    static let preferenceKey = "app.language.v1"
    /// Read and written by macOS itself. Impuls is a guest in this key.
    static let systemLanguagesKey = "AppleLanguages"

    @Published private(set) var selection: AppLanguage

    /// The preference this process started with.
    ///
    /// Held in memory rather than persisted: it describes the running process, not
    /// the user, and a second stored value would be a second source of truth.
    private let selectionAtLaunch: AppLanguage

    private let defaults: UserDefaults
    /// Injected rather than read from `Bundle.main` at the point of use: under
    /// `swift test` the main bundle is the xctest runner, not `Impuls.app`, so a
    /// hard dependency would validate the wrong bundle's localisations.
    private let availableLocalizations: [String]

    init(
        defaults: UserDefaults = .standard,
        availableLocalizations: [String] = Bundle.main.localizations
    ) {
        self.defaults = defaults
        self.availableLocalizations = availableLocalizations
        // Degrades in memory. Normalising the stored value here would be a write
        // during initialisation, and initialisation must not change what language
        // the user's Mac is in.
        let stored = Self.storedSelection(in: defaults, available: availableLocalizations)
        selection = stored
        selectionAtLaunch = stored
    }

    /// The languages the picker may offer: no choice, plus whatever this bundle carries.
    var selectableLanguages: [AppLanguage] {
        [.system] + AppLanguage.allCases.filter { language in
            guard let code = language.localizationCode else { return false }
            return availableLocalizations.contains(code)
        }
    }

    /// Whether the preference has moved since this process started.
    ///
    /// Not "the chosen language differs from the running one": under `system` the
    /// running language is always some concrete locale, so that comparison would be
    /// permanently true and every ordinary launch would claim a restart is pending.
    var requiresRelaunch: Bool { selection != selectionAtLaunch }

    /// The localisation a bundle should resolve against, given what macOS would pick.
    ///
    /// A choice this bundle cannot honour falls back to English rather than to the
    /// missing table, matching the key scheme: an untranslated string reads as
    /// English instead of as an identifier.
    func resolvedLocalization(systemPreferred: String) -> String {
        guard let code = selection.localizationCode else { return systemPreferred }
        return availableLocalizations.contains(code) ? code : "en"
    }

    /// Records an explicit choice made by the user in Settings.
    ///
    /// The only path that writes `AppleLanguages`. Returning to `system` withdraws
    /// the override *this app* created; if Impuls never created one, the key is left
    /// as it is, because it then belongs to macOS or to the user.
    func select(_ language: AppLanguage) {
        guard language == .system || availableLocalizations.contains(language.rawValue) else { return }
        let previous = selection
        guard language != previous else { return }

        selection = language
        defaults.set(language.rawValue, forKey: Self.preferenceKey)

        if let code = language.localizationCode {
            defaults.set([code], forKey: Self.systemLanguagesKey)
        } else if previous.localizationCode != nil {
            defaults.removeObject(forKey: Self.systemLanguagesKey)
        }
    }

    private static func storedSelection(in defaults: UserDefaults, available: [String]) -> AppLanguage {
        guard let raw = defaults.string(forKey: preferenceKey),
              let language = AppLanguage(rawValue: raw) else { return .system }
        guard let code = language.localizationCode else { return .system }
        // A build that dropped a localisation must not keep asking for it.
        return available.contains(code) ? language : .system
    }
}
