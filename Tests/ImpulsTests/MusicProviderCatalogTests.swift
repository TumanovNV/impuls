import XCTest
@testable import ImpulsCore

final class MusicProviderCatalogTests: XCTestCase {
    /// Recommending must never hide a supported source — only reorder it.
    func testRecommendedNeverDropsAnySupportedSource() {
        for region in [nil, "RU", "US", "DE", "JP", "CN", "FR", "ES", "ZZ"] {
            let recommended = Set(MusicProviderCatalog.recommended(regionCode: region))
            XCTAssertEqual(recommended, Set(MusicSource.allCases), "region \(String(describing: region)) dropped a source")
        }
    }

    func testRussianRegionLeadsWithYandexAndVK() {
        let order = MusicProviderCatalog.recommended(regionCode: "RU", appLanguageCode: "en")
        XCTAssertEqual(order, [.appleMusic, .yandexMusic, .vkMusic, .youtubeMusic])
    }

    /// Region takes priority over app language when both are available:
    /// the system region is the only signal that answers "where is this
    /// Mac", so it must win over the deterministic fallback.
    func testKnownNonRussianRegionIsNotOverriddenByRussianAppLanguage() {
        let order = MusicProviderCatalog.recommended(regionCode: "US", appLanguageCode: "ru")
        XCTAssertEqual(order.first, .appleMusic)
        XCTAssertFalse(order.prefix(2).contains(.vkMusic))
    }

    /// An unresolved region must fall back to the global order, never guess
    /// a country from the interface language.
    func testUnknownRegionWithNonRussianAppLanguageUsesGlobalOrder() {
        let order = MusicProviderCatalog.recommended(regionCode: nil, appLanguageCode: "en")
        XCTAssertEqual(order, [.appleMusic, .youtubeMusic, .yandexMusic, .vkMusic])
    }

    /// The app's own UI language is a deliberate secondary fallback — used
    /// only once the system region itself failed to resolve — not a
    /// substitute for it and never a language==country assumption in general.
    func testUnknownRegionWithRussianAppLanguageFallsBackToRussianOrder() {
        let order = MusicProviderCatalog.recommended(regionCode: nil, appLanguageCode: "ru")
        XCTAssertEqual(order, [.appleMusic, .yandexMusic, .vkMusic, .youtubeMusic])
    }

    /// A German UI language must not itself imply a German-flavoured order —
    /// there is no such thing here, since the catalog is region-driven, not
    /// language-driven, and no source is Germany-specific.
    func testNonRussianAppLanguageNeverProducesTheRussianOrderByItself() {
        for language in ["de", "fr", "es", "ja", "zh-Hans", "en"] {
            let order = MusicProviderCatalog.recommended(regionCode: nil, appLanguageCode: language)
            XCTAssertEqual(order, [.appleMusic, .youtubeMusic, .yandexMusic, .vkMusic])
        }
    }

    func testAllServicesOrderIsStableAndRegionIndependent() {
        XCTAssertEqual(MusicProviderCatalog.allServices, MusicSource.allCases)
    }
}
