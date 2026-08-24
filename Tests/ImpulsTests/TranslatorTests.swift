import Foundation
import Translation
import XCTest
@testable import ImpulsCore

final class TranslatorTests: XCTestCase {
    @MainActor
    private func makeTranslator() throws -> (Translator, UserDefaults, String) {
        let suite = "TranslatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (Translator(defaults: defaults), defaults, suite)
    }

    @MainActor
    func testInputIsBoundedBeforeLanguageAnalysis() throws {
        let (translator, defaults, suite) = try makeTranslator()
        defer { defaults.removePersistentDomain(forName: suite) }

        translator.input = String(
            repeating: "я",
            count: Translator.maximumInputCharacters + 1_000
        )

        XCTAssertEqual(translator.input.count, Translator.maximumInputCharacters)
        XCTAssertEqual(translator.route.source, Translator.russian)
    }

    /// The default pair and its behaviour are what every existing user has, and
    /// adding a picker must not change either.
    @MainActor
    func testDefaultPairStillRunsBothWaysByAlphabet() throws {
        let (translator, defaults, suite) = try makeTranslator()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(translator.route(for: "привет").target, Translator.english)
        XCTAssertEqual(translator.route(for: "hello").target, Translator.russian)
    }

    /// A quoted product name does not make a Russian sentence English.
    func testDirectionFollowsTheMajorityAlphabet() {
        XCTAssertEqual(TranslationScript.of("Открыть Finder и найти файл"), .cyrillic)
        XCTAssertEqual(TranslationScript.of("Open Finder"), .latin)
        XCTAssertEqual(TranslationScript.of("2026 — 10:45"), nil)
        // Japanese mixes kana with han; the kana is what identifies it.
        XCTAssertEqual(TranslationScript.of("東京の天気はどうですか"), .kana)
    }

    func testLanguageAlphabetIsInferredWithoutAnExplicitScript() {
        XCTAssertEqual(TranslationScript.of(Locale.Language(identifier: "ru")), .cyrillic)
        XCTAssertEqual(TranslationScript.of(Locale.Language(identifier: "en")), .latin)
        XCTAssertEqual(TranslationScript.of(Locale.Language(identifier: "el")), .greek)
        XCTAssertEqual(TranslationScript.of(Locale.Language(identifier: "zh")), .han)
        XCTAssertEqual(TranslationScript.of(Locale.Language(identifier: "ja")), .kana)
    }

    /// Two languages written the same way leave nothing to read the direction
    /// from, so the pair keeps its stated order rather than guessing.
    @MainActor
    func testPairInOneAlphabetKeepsItsStatedDirection() throws {
        let (translator, defaults, suite) = try makeTranslator()
        defer { defaults.removePersistentDomain(forName: suite) }

        translator.select(Locale.Language(identifier: "de"), replacing: Translator.russian)
        XCTAssertFalse(translator.pair.isDirectionDetectable)
        XCTAssertEqual(Translator.code(translator.route(for: "guten Tag").source), "de")
        XCTAssertEqual(Translator.code(translator.route(for: "hello").source), "de")

        translator.swap()
        XCTAssertEqual(Translator.code(translator.route(for: "hello").source), "en")
    }

    /// Choosing the language that is already on the other side means "swap",
    /// not "translate German into German".
    @MainActor
    func testChoosingTheOppositeLanguageSwapsInsteadOfCollapsing() throws {
        let (translator, defaults, suite) = try makeTranslator()
        defer { defaults.removePersistentDomain(forName: suite) }

        translator.select(Translator.english, replacing: Translator.russian)

        XCTAssertEqual(Translator.code(translator.pair.first), "en")
        XCTAssertEqual(Translator.code(translator.pair.second), "ru")
    }

    @MainActor
    func testSelectedPairSurvivesRelaunch() throws {
        let (translator, defaults, suite) = try makeTranslator()
        defer { defaults.removePersistentDomain(forName: suite) }

        translator.select(Locale.Language(identifier: "el"), replacing: Translator.english)
        let restored = Translator(defaults: defaults)

        XCTAssertEqual(Translator.code(restored.pair.first), "ru")
        XCTAssertEqual(Translator.code(restored.pair.second), "el")
        XCTAssertTrue(restored.pair.isDirectionDetectable)
        XCTAssertEqual(Translator.code(restored.route(for: "καλημέρα").target), "ru")
    }

    /// A stored pair naming one language twice is not a pair. Falling back is
    /// better than a translator that can only translate a language into itself.
    @MainActor
    func testDegenerateStoredPairFallsBackToTheDefault() throws {
        let suite = "TranslatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("en|en", forKey: Translator.pairKey)
        let translator = Translator(defaults: defaults)

        XCTAssertEqual(Translator.code(translator.pair.first), "ru")
        XCTAssertEqual(Translator.code(translator.pair.second), "en")
    }

    /// The framework's own language list contains regional variants — "en-GB"
    /// and "en-US" are separate entries — and it answers "unsupported" when
    /// asked whether it can translate Russian into British English, a pair it
    /// translates perfectly well as plain English. Picking a language from the
    /// menu must therefore never put a region into the pair.
    @MainActor
    func testRegionalVariantIsReducedToTheBareLanguage() throws {
        let (translator, defaults, suite) = try makeTranslator()
        defer { defaults.removePersistentDomain(forName: suite) }

        translator.select(
            Locale.Language(identifier: "en-GB"),
            replacing: Translator.english
        )
        // Same language, so the pair is unchanged and still bare.
        XCTAssertEqual(translator.pair.second.maximalIdentifier, Translator.english.maximalIdentifier)

        translator.select(Locale.Language(identifier: "pt-BR"), replacing: Translator.english)
        XCTAssertEqual(Translator.code(translator.pair.second), "pt")
        XCTAssertNil(translator.pair.second.region)
        XCTAssertEqual(translator.route(for: "добрый день").target.minimalIdentifier, "pt")
    }

    /// macOS translates a pair, not a language. Russian and German are each
    /// supported and cannot be translated into one another, so "not downloaded"
    /// and "impossible" have to be different answers — the first is worth
    /// offering, the second is a dead end.
    func testReadinessSeparatesMissingPacksFromImpossiblePairs() {
        XCTAssertEqual(Translator.Readiness(.installed, .unsupported), .installed)
        XCTAssertEqual(Translator.Readiness(.unsupported, .installed), .installed)
        XCTAssertEqual(Translator.Readiness(.supported, .unsupported), .downloadable)
        XCTAssertEqual(Translator.Readiness(.unsupported, .unsupported), .unsupported)
    }

    /// The language already in the pair is always offerable, and so is the one
    /// on the other side — choosing it is a swap, not a new pair.
    @MainActor
    func testCurrentPairIsNeverPresentedAsUnusable() throws {
        let (translator, defaults, suite) = try makeTranslator()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(
            translator.readiness(choosing: Translator.russian, replacing: Translator.russian),
            .installed
        )
        XCTAssertEqual(
            translator.readiness(choosing: Translator.english, replacing: Translator.russian),
            .installed
        )
    }

    /// Before the scan lands, a pair must read as genuinely unknown — not
    /// silently promoted to `.downloadable`, which used to put a false
    /// download mark next to a language that might already be fully
    /// installed (or, just as wrongly, next to one that turns out
    /// unsupported once the real answer arrives).
    @MainActor
    func testUnscannedPairReadsAsUnknownNotAsAnyRealStatus() throws {
        let (translator, defaults, suite) = try makeTranslator()
        defer { defaults.removePersistentDomain(forName: suite) }

        let readiness = translator.readiness(
            choosing: Locale.Language(identifier: "de"),
            replacing: Translator.russian
        )
        XCTAssertEqual(readiness, .unknown)
        XCTAssertNotEqual(readiness, .downloadable)
        XCTAssertNotEqual(readiness, .installed)
        XCTAssertNotEqual(readiness, .unsupported)
    }

    /// The pane keys its debounced task on this, so a language change has to
    /// look like a new request or the panel would keep the previous result.
    @MainActor
    func testRequestIdentityChangesWithTheLanguagePair() throws {
        let (translator, defaults, suite) = try makeTranslator()
        defer { defaults.removePersistentDomain(forName: suite) }

        translator.input = "hello"
        let before = translator.request
        translator.select(Locale.Language(identifier: "de"), replacing: Translator.russian)

        XCTAssertNotEqual(before, translator.request)
    }

    /// `run(_:)` now guards every resumption point against this identity, not
    /// only the pair — a stale answer for the *previous* text at the *same*
    /// pair has to be recognisable as stale too, the same race `Request`
    /// already existed to solve for a pair change.
    @MainActor
    func testRequestIdentityChangesWithTheTextAtTheSamePair() throws {
        let (translator, defaults, suite) = try makeTranslator()
        defer { defaults.removePersistentDomain(forName: suite) }

        translator.input = "hello"
        let before = translator.request
        translator.input = "hello world"

        XCTAssertNotEqual(before, translator.request)
        XCTAssertEqual(before.pair, translator.request.pair)
    }

    /// An explicit retry of unchanged text at an unchanged pair still has to
    /// outrank whatever the previous attempt was already computing — that is
    /// the entire reason `Request` carries an attempt counter.
    @MainActor
    func testRequestIdentityChangesOnRetryEvenWithUnchangedTextAndPair() throws {
        let (translator, defaults, suite) = try makeTranslator()
        defer { defaults.removePersistentDomain(forName: suite) }

        translator.input = "hello"
        let before = translator.request
        translator.retry()

        XCTAssertNotEqual(before, translator.request)
        XCTAssertEqual(before.text, translator.request.text)
        XCTAssertEqual(before.pair, translator.request.pair)
    }

    /// `onAppear` calls `loadSupportedLanguages()` on every tab switch back
    /// to Translate, not only the first mount — a rapid switch-away-and-back
    /// before the first scan's result lands must not start a second one.
    @MainActor
    func testLoadSupportedLanguagesDoesNotStartASecondScanWhileOneIsInFlight() throws {
        let (translator, defaults, suite) = try makeTranslator()
        defer { defaults.removePersistentDomain(forName: suite) }

        translator.loadSupportedLanguages()
        translator.loadSupportedLanguages()
        translator.loadSupportedLanguages()

        XCTAssertEqual(translator.languageListScansStarted, 1)
    }

    /// The translated text, the input and any failure text are all runtime
    /// state. Only the language pair may ever reach disk.
    @MainActor
    func testOnlyThePairIsPersistedNeverInputOrOutput() throws {
        let (translator, defaults, suite) = try makeTranslator()
        defer { defaults.removePersistentDomain(forName: suite) }

        translator.input = "a sentence that must never be written to disk"
        translator.select(Locale.Language(identifier: "de"), replacing: Translator.russian)
        translator.retry()
        translator.swap()

        // `dictionaryRepresentation()` merges in the whole domain search
        // list — on a real Mac that includes NSGlobalDomain's trackpad,
        // language and dozens of other unrelated system keys, so it can
        // never equal a single-key set. `persistentDomain(forName:)` is
        // exactly this suite's own on-disk contents, nothing inherited.
        let persisted = try XCTUnwrap(defaults.persistentDomain(forName: suite))
        XCTAssertEqual(Set(persisted.keys), [Translator.pairKey])
    }
}
