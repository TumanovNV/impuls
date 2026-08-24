import XCTest
@testable import ImpulsCore

final class MusicProviderCatalogTests: XCTestCase {
    /// Recommending is deliberately a subset, not a reordering — it must
    /// never invent a source `allServices` does not already have.
    func testRecommendedIsAlwaysASubsetOfAllServices() {
        for region in [nil, "RU", "US", "DE", "FR", "ES", "JP", "CN", "HK", "TW", "ZZ"] {
            let recommended = Set(MusicProviderCatalog.recommended(regionCode: region))
            XCTAssertTrue(
                recommended.isSubset(of: Set(MusicSource.allCases)),
                "region \(String(describing: region)) recommended a source outside the supported catalog"
            )
        }
    }

    /// Recommended must not simply repeat All Services under a different
    /// heading — that was the exact defect this test locks in.
    func testRecommendedIsAGenuineSubsetNotTheFullCatalog() {
        for region in [nil, "RU", "US", "DE", "FR", "ES", "JP", "CN"] {
            let recommended = MusicProviderCatalog.recommended(regionCode: region, appLanguageCode: "en")
            XCTAssertLessThan(
                recommended.count, MusicSource.allCases.count,
                "region \(String(describing: region)) recommended the entire catalog"
            )
        }
    }

    func testRussianRegionRecommendsYandexThenVKThenApple() {
        let order = MusicProviderCatalog.recommended(regionCode: "RU", appLanguageCode: "en")
        XCTAssertEqual(order, [.yandexMusic, .vkMusic, .appleMusic])
    }

    /// Other CIS markets Yandex/VK already serve get the same treatment.
    func testOtherCISRegionsAlsoRecommendYandexAndVKFirst() {
        for region in ["BY", "KZ", "KG", "AM", "UZ", "TJ"] {
            let order = MusicProviderCatalog.recommended(regionCode: region, appLanguageCode: "en")
            XCTAssertEqual(order, [.yandexMusic, .vkMusic, .appleMusic], "region \(region)")
        }
    }

    /// Mainland China only — YouTube Music is not reachable there, so it is
    /// not promoted, but it must still be reachable under All Services.
    func testMainlandChinaRecommendsOnlyAppleMusic() {
        let order = MusicProviderCatalog.recommended(regionCode: "CN", appLanguageCode: "en")
        XCTAssertEqual(order, [.appleMusic])
        XCTAssertTrue(MusicProviderCatalog.allServices.contains(.youtubeMusic))
    }

    /// Hong Kong / Taiwan are not mainland China and must not be folded into
    /// its recommendation — the market reality there is different.
    func testHongKongAndTaiwanAreNotTreatedAsMainlandChina() {
        for region in ["HK", "TW", "MO"] {
            let order = MusicProviderCatalog.recommended(regionCode: region, appLanguageCode: "en")
            XCTAssertEqual(order, [.appleMusic, .youtubeMusic], "region \(region)")
        }
    }

    /// Region takes priority over app language when both are available:
    /// the system region is the only signal that answers "where is this
    /// Mac", so it must win over the deterministic fallback.
    func testKnownNonRussianRegionIsNotOverriddenByRussianAppLanguage() {
        let order = MusicProviderCatalog.recommended(regionCode: "US", appLanguageCode: "ru")
        XCTAssertEqual(order, [.appleMusic, .youtubeMusic])
    }

    /// An unresolved region must fall back to the global order, never guess
    /// a country from the interface language.
    func testUnknownRegionWithNonRussianAppLanguageUsesGlobalOrder() {
        let order = MusicProviderCatalog.recommended(regionCode: nil, appLanguageCode: "en")
        XCTAssertEqual(order, [.appleMusic, .youtubeMusic])
    }

    /// The app's own UI language is a deliberate secondary fallback — used
    /// only once the system region itself failed to resolve — not a
    /// substitute for it and never a language==country assumption in general.
    func testUnknownRegionWithRussianAppLanguageFallsBackToRussianOrder() {
        let order = MusicProviderCatalog.recommended(regionCode: nil, appLanguageCode: "ru")
        XCTAssertEqual(order, [.yandexMusic, .vkMusic, .appleMusic])
    }

    /// A German UI language must not itself imply a German-flavoured order —
    /// there is no such thing here, since the catalog is region-driven, not
    /// language-driven, and no source is Germany-specific.
    func testNonRussianAppLanguageNeverProducesTheRussianOrderByItself() {
        for language in ["de", "fr", "es", "ja", "zh-Hans", "en"] {
            let order = MusicProviderCatalog.recommended(regionCode: nil, appLanguageCode: language)
            XCTAssertEqual(order, [.appleMusic, .youtubeMusic])
        }
    }

    func testGlobalRegionsShareTheSameRecommendation() {
        for region in ["US", "GB", "DE", "FR", "ES", "JP"] {
            let order = MusicProviderCatalog.recommended(regionCode: region, appLanguageCode: "en")
            XCTAssertEqual(order, [.appleMusic, .youtubeMusic], "region \(region)")
        }
    }

    func testAllServicesOrderIsStableAndRegionIndependent() {
        XCTAssertEqual(MusicProviderCatalog.allServices, MusicSource.allCases)
    }

    /// Every source recommending ever omits must still be reachable under
    /// All Services — nothing becomes unreachable, only unpromoted.
    func testEverySourceStaysReachableUnderAllServicesEvenWhenNotRecommended() {
        let chinaRecommended = Set(MusicProviderCatalog.recommended(regionCode: "CN", appLanguageCode: "en"))
        let omitted = Set(MusicSource.allCases).subtracting(chinaRecommended)
        XCTAssertFalse(omitted.isEmpty)
        XCTAssertTrue(omitted.isSubset(of: Set(MusicProviderCatalog.allServices)))
    }
}
