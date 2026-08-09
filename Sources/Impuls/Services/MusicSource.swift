import Foundation

/// A source is selected explicitly inside the Music pane. Native playback is
/// kept separate from web playback so Impuls never guesses which of several
/// simultaneously running players the user intended to control.
enum MusicSource: String, CaseIterable, Identifiable {
    case appleMusic
    case yandexMusic
    case vkMusic
    case youtubeMusic
    case spotifyWeb

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .yandexMusic: return "Яндекс Музыка"
        case .vkMusic: return "VK Музыка"
        case .youtubeMusic: return "YouTube Music"
        case .spotifyWeb: return "Spotify"
        }
    }

    var symbol: String {
        switch self {
        case .appleMusic: return "music.note"
        case .yandexMusic: return "waveform"
        case .vkMusic: return "person.2.wave.2"
        case .youtubeMusic: return "play.rectangle.fill"
        case .spotifyWeb: return "dot.radiowaves.left.and.right"
        }
    }

    var isWeb: Bool { webHomeURL != nil }

    var webHomeURL: URL? {
        switch self {
        case .appleMusic: return nil
        case .yandexMusic: return URL(string: "https://music.yandex.ru/home")
        case .vkMusic: return URL(string: "https://vk.com/music")
        case .youtubeMusic: return URL(string: "https://music.youtube.com")
        case .spotifyWeb: return URL(string: "https://open.spotify.com")
        }
    }

    /// Top-level navigation is intentionally narrower than subresource access.
    /// It keeps an authentication redirect inside the chosen provider while an
    /// unrelated link is handed to the user's default browser.
    func allowsTopLevelNavigation(to url: URL) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        guard isWeb, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        return allowedExactHosts.contains(host) || allowedHostSuffixes.contains { suffix in
            host == suffix || host.hasSuffix(".\(suffix)")
        }
    }

    private var allowedExactHosts: [String] {
        switch self {
        case .youtubeMusic:
            return ["accounts.google.com", "consent.google.com"]
        default:
            return []
        }
    }

    private var allowedHostSuffixes: [String] {
        switch self {
        case .appleMusic:
            return []
        case .yandexMusic:
            return ["yandex.ru", "ya.ru"]
        case .vkMusic:
            return ["vk.com", "vk.ru"]
        case .youtubeMusic:
            return ["youtube.com"]
        case .spotifyWeb:
            return ["spotify.com"]
        }
    }
}
