import Foundation

/// A source is selected explicitly inside the Music pane. Native playback is
/// kept separate from web playback so Impuls never guesses which of several
/// simultaneously running players the user intended to control.
///
/// Spotify web embedding remains unsupported because its web player needs
/// Widevine, which WebKit does not implement. The native Spotify macOS source
/// is supported separately through Spotify's shipped scripting interface.
enum MusicSource: String, CaseIterable, Identifiable {
    case appleMusic
    case spotify
    case yandexMusic
    case vkMusic
    case youtubeMusic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        case .yandexMusic: return "Яндекс Музыка"
        case .vkMusic: return "VK Музыка"
        case .youtubeMusic: return "YouTube Music"
        }
    }

    var symbol: String {
        switch self {
        case .appleMusic: return "music.note"
        case .spotify: return "music.note"
        case .yandexMusic: return "waveform"
        case .vkMusic: return "person.2.wave.2"
        case .youtubeMusic: return "play.rectangle.fill"
        }
    }

    var isWeb: Bool { webHomeURL != nil }

    /// Native providers are addressed only through their own declared public
    /// scripting interface. A web provider deliberately has no PlayerApp.
    var nativePlayerApp: PlayerApp? {
        switch self {
        case .appleMusic: return .music
        case .spotify: return .spotify
        case .yandexMusic, .vkMusic, .youtubeMusic: return nil
        }
    }

    var webHomeURL: URL? {
        switch self {
        case .appleMusic, .spotify: return nil
        case .yandexMusic: return URL(string: "https://music.yandex.ru/home")
        case .vkMusic: return URL(string: "https://vk.com/audio")
        case .youtubeMusic: return URL(string: "https://music.youtube.com/")
        }
    }

    // MARK: - Navigation boundary

    /// The main frame is what the metadata bridge reads, so it is held to the
    /// provider's own domains plus the sign-in hosts that provider redirects
    /// to. An unrelated link is handed to the default browser instead.
    func allowsMainFrameNavigation(to url: URL) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        guard isWeb, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        return allowedHostSuffixes.contains { suffix in
            host == suffix || host.hasSuffix(".\(suffix)")
        }
    }

    /// Subframes are a different question. A captcha widget, a consent frame or
    /// an analytics pixel lives on a third-party host by design, and blocking
    /// those is what left the sign-in pages blank. A subframe cannot reach the
    /// Impuls message handler — the bridge script is injected into the main
    /// frame only — so the boundary that matters is still enforced above.
    static func allowsSubframeNavigation(to url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https", "about", "blob", "data": return true
        default: return false
        }
    }

    /// Only a real provider page may deliver playback state.
    func allowsStateReport(from url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && allowsMainFrameNavigation(to: url)
    }

    private var allowedHostSuffixes: [String] {
        switch self {
        case .appleMusic, .spotify:
            return []
        case .yandexMusic:
            // music.yandex.* is the service; passport.yandex.* and ya.ru carry
            // the Yandex ID sign-in flow.
            return [
                "yandex.ru", "yandex.com", "yandex.by", "yandex.kz",
                "yandex.com.tr", "yandex.net", "ya.ru",
            ]
        case .vkMusic:
            // vk.com/audio redirects to vk.ru for sign-in, and VK ID lives on
            // id.vk.com / id.vk.ru, both covered by the suffixes below.
            return ["vk.com", "vk.ru", "vk.me", "vkvideo.ru"]
        case .youtubeMusic:
            // YouTube Music authenticates through the Google account hosts:
            // accounts.google.com, consent.google.com and myaccount.google.com.
            return [
                "youtube.com", "youtube-nocookie.com",
                "google.com", "googleusercontent.com",
            ]
        }
    }
}

/// Whole-sentence empty-state copy, per native provider.
///
/// These deliberately are not one `%@` template filled with the product name.
/// Russian inflects the predicate for the subject's gender — Apple Music is
/// feminine ("Apple Music открыта", "не установлена") while Spotify is
/// masculine ("Spotify открыт", "не установлен") — so a single shared string is
/// wrong for one of them whichever form it picks. Genericising these four
/// messages in IMP-11 is what produced "Apple Music открыто" and "Spotify не
/// установлено". Giving every provider its own key hands each translation the
/// whole sentence, which is the only form that can be correct in all seven
/// languages at once.
///
/// Each key stays a string literal at the `localized` call site, so
/// `check-localization.py` can still see it and prove it exists in every table.
extension PlayerApp {
    var notInstalledMessage: String {
        switch self {
        case .music: return localized("Apple Music is not installed.")
        case .spotify: return localized("Spotify is not installed.")
        }
    }

    var notRunningMessage: String {
        switch self {
        case .music: return localized("Open Apple Music and start a track.")
        case .spotify: return localized("Open Spotify and start a track.")
        }
    }

    var idleMessage: String {
        switch self {
        case .music: return localized("Apple Music is open, but no track is playing.")
        case .spotify: return localized("Spotify is open, but no track is playing.")
        }
    }

    var unreadableMessage: String {
        switch self {
        case .music: return localized("Apple Music is playing, but its track data could not be read.")
        case .spotify: return localized("Spotify is playing, but its track data could not be read.")
        }
    }

    var openActionTitle: String {
        switch self {
        case .music: return localized("Open Apple Music")
        case .spotify: return localized("Open Spotify")
        }
    }
}
