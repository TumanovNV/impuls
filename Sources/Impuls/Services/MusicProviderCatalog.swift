import Foundation

/// Picks a short, region-relevant subset of the always-present provider list
/// for the Music pane's "Recommended" group, ahead of "All Services".
///
/// `allServices` is the complete supported catalog and never changes here.
/// `recommended(...)` is deliberately **not** a reordering of it: it is a
/// small subset reflecting which services actually make sense to lead with
/// in a region, so it does not just repeat "All Services" under a different
/// heading. Every source it omits stays one tap away under "All Services" —
/// nothing becomes unreachable, only unpromoted.
///
/// Region comes only from the local system locale (`Locale.current.region`);
/// the app's own UI language (`appLanguage`, from `Strings.swift`) is a
/// deterministic secondary fallback for when the system region did not
/// resolve, never a stand-in for it and never a geolocation proxy. Neither
/// signal performs a lookup: both are already-local values, and this type
/// makes no network request, reads no persisted state and writes none.
enum MusicProviderCatalog {
    /// The complete list, in a fixed order that does not depend on region.
    static var allServices: [MusicSource] { MusicSource.allCases }

    /// A small region-relevant subset of `allServices`. Always a subset,
    /// never a superset or a reordering of the full catalog.
    static func recommended(
        regionCode: String? = Locale.current.region?.identifier,
        appLanguageCode: String = appLanguage
    ) -> [MusicSource] {
        subset(regionCode: regionCode?.uppercased(), appLanguageCode: appLanguageCode)
    }

    /// Russia and the other CIS markets Yandex Music / VK Music already
    /// serve. Yandex leads, VK second — both are the locally dominant
    /// services there — and Apple Music is retained, not promoted ahead of
    /// them.
    private static let russianSpeakingRegions: Set<String> = [
        "RU", "BY", "KZ", "KG", "AM", "UZ", "TJ",
    ]

    private static let russianSpeakingRecommended: [MusicSource] = [
        .yandexMusic, .vkMusic, .appleMusic,
    ]

    /// Mainland China only (`CN`) — not Hong Kong/Macau/Taiwan, whose market
    /// reality differs. YouTube Music is not reachable there, so only Apple
    /// Music is recommended; everything else stays reachable under All
    /// Services rather than being promoted on a guess.
    private static let chinaRecommended: [MusicSource] = [.appleMusic]

    /// Everywhere else, and whenever the region is unknown: the two sources
    /// usable worldwide without a region-specific catalog.
    private static let globalRecommended: [MusicSource] = [.appleMusic, .youtubeMusic]

    private static func subset(regionCode: String?, appLanguageCode: String) -> [MusicSource] {
        if let regionCode {
            if regionCode == "CN" { return chinaRecommended }
            if russianSpeakingRegions.contains(regionCode) { return russianSpeakingRecommended }
            return globalRecommended
        }
        if appLanguageCode.lowercased().hasPrefix("ru") { return russianSpeakingRecommended }
        return globalRecommended
    }
}
