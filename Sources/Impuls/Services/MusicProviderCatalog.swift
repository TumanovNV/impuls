import Foundation

/// Orders the always-present provider list by region relevance so the Music
/// pane can show a short "Recommended" group before "All Services".
///
/// The supported catalog itself never changes here — `recommended(...)`
/// returns every source `allServices` does, just reordered. Region comes only
/// from the local system locale (`Locale.current.region`); the app's own UI
/// language (`appLanguage`, from `Strings.swift`) is a deterministic secondary
/// fallback for when the system region did not resolve, never a stand-in for
/// it and never a geolocation proxy. Neither signal performs a lookup: both
/// are already-local values, and this type makes no network request, reads no
/// persisted state and writes none.
enum MusicProviderCatalog {
    /// The complete list, in a fixed order that does not depend on region.
    static var allServices: [MusicSource] { MusicSource.allCases }

    /// `allServices`, reordered so the sources most likely to be usable in the
    /// caller's region lead. Every source from `allServices` is still present
    /// at some position — recommending never hides a supported source, it
    /// only changes which ones are worth listing first.
    static func recommended(
        regionCode: String? = Locale.current.region?.identifier,
        appLanguageCode: String = appLanguage
    ) -> [MusicSource] {
        let priority = priorityOrder(regionCode: regionCode?.uppercased(), appLanguageCode: appLanguageCode)
        return allServices.sorted { lhs, rhs in
            rank(of: lhs, in: priority) < rank(of: rhs, in: priority)
        }
    }

    private static func rank(of source: MusicSource, in priority: [MusicSource]) -> Int {
        priority.firstIndex(of: source) ?? priority.count
    }

    /// Russian-speaking-region order: Apple Music stays first as the reliable
    /// native path, then the two services with the largest local catalogs.
    private static let russianSpeakingOrder: [MusicSource] = [
        .appleMusic, .yandexMusic, .vkMusic, .youtubeMusic,
    ]

    /// Everywhere else, and whenever the region is unknown: Apple Music and
    /// YouTube Music lead, since both are usable worldwide without a
    /// region-specific catalog.
    private static let globalOrder: [MusicSource] = [
        .appleMusic, .youtubeMusic, .yandexMusic, .vkMusic,
    ]

    /// ISO region codes where Yandex Music / VK Music are the locally
    /// dominant services: Russia and the other CIS markets they already serve.
    private static let russianSpeakingRegions: Set<String> = [
        "RU", "BY", "KZ", "KG", "AM", "UZ", "TJ",
    ]

    private static func priorityOrder(regionCode: String?, appLanguageCode: String) -> [MusicSource] {
        if let regionCode, russianSpeakingRegions.contains(regionCode) {
            return russianSpeakingOrder
        }
        if regionCode == nil, appLanguageCode.lowercased().hasPrefix("ru") {
            return russianSpeakingOrder
        }
        return globalOrder
    }
}
