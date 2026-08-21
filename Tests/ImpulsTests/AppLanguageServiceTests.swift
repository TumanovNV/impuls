import Foundation
import XCTest
@testable import ImpulsCore

final class AppLanguageServiceTests: XCTestCase {
    /// What the shipped bundle carries. Passed explicitly rather than read from
    /// `Bundle.main`, which under `swift test` is the xctest runner and carries
    /// none of these.
    private static let shipped = ["en", "ru", "de", "fr", "es", "zh-Hans", "ja"]

    /// The value in *this suite's own* persistent domain.
    ///
    /// Not `defaults.object(forKey:)`: `AppleLanguages` also exists in the global
    /// domain, and a plain lookup resolves through the whole search list, so it
    /// answers "what language would macOS pick" and never nil. The question these
    /// tests ask is narrower and is the one that matters — did Impuls write the
    /// key into its own domain, which is what overriding actually means.
    private func ownDomain(_ defaults: UserDefaults, _ suite: String, _ key: String) -> Any? {
        defaults.persistentDomain(forName: suite)?[key]
    }

    private func systemLanguagesOverride(_ defaults: UserDefaults, _ suite: String) -> [String]? {
        ownDomain(defaults, suite, AppLanguageService.systemLanguagesKey) as? [String]
    }

    @MainActor
    private func makeService(
        available: [String] = shipped
    ) throws -> (AppLanguageService, UserDefaults, String) {
        let suite = "AppLanguageServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (AppLanguageService(defaults: defaults, availableLocalizations: available), defaults, suite)
    }

    @MainActor
    func testDefaultSelectionIsSystem() throws {
        let (service, defaults, suite) = try makeService()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(service.selection, .system)
    }

    /// Under `system` the app follows whatever macOS resolved, and claims nothing.
    @MainActor
    func testSystemFollowsTheSystemLocaleAndWritesNothing() throws {
        let (service, defaults, suite) = try makeService()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(service.resolvedLocalization(systemPreferred: "ru"), "ru")
        XCTAssertNil(systemLanguagesOverride(defaults, suite))
        XCTAssertNil(ownDomain(defaults, suite, AppLanguageService.preferenceKey))
    }

    @MainActor
    func testEveryShippedLanguageResolvesToItsOwnCode() throws {
        for language in [AppLanguage.german, .french, .spanish, .simplifiedChinese, .japanese, .russian, .english] {
            let (service, defaults, suite) = try makeService()
            defer { defaults.removePersistentDomain(forName: suite) }

            service.select(language)

            XCTAssertEqual(service.selection, language)
            XCTAssertEqual(service.resolvedLocalization(systemPreferred: "ru"), language.rawValue)
            XCTAssertEqual(systemLanguagesOverride(defaults, suite), [language.rawValue])
        }
    }

    @MainActor
    func testSelectionSurvivesRecreatingTheService() throws {
        let suite = "AppLanguageServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped)
        first.select(.german)

        let second = AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped)
        XCTAssertEqual(second.selection, .german)
    }

    /// Returning to `system` withdraws the override this app created.
    @MainActor
    func testReturningToSystemRemovesAnOverrideImpulsCreated() throws {
        let (service, defaults, suite) = try makeService()
        defer { defaults.removePersistentDomain(forName: suite) }

        service.select(.german)
        XCTAssertEqual(systemLanguagesOverride(defaults, suite), ["de"])

        service.select(.system)

        XCTAssertEqual(service.selection, .system)
        XCTAssertNil(systemLanguagesOverride(defaults, suite))
    }

    /// A stored value this build cannot parse must not be acted on.
    @MainActor
    func testCorruptPreferenceDegradesToSystemWithoutTouchingTheSystemKey() throws {
        let suite = "AppLanguageServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("klingon", forKey: AppLanguageService.preferenceKey)

        let service = AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped)

        XCTAssertEqual(service.selection, .system)
        XCTAssertNil(systemLanguagesOverride(defaults, suite))
    }

    /// A language the bundle no longer carries stops being asked for.
    @MainActor
    func testPreferenceForAMissingLocalizationDegradesToSystem() throws {
        let suite = "AppLanguageServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(AppLanguage.japanese.rawValue, forKey: AppLanguageService.preferenceKey)

        let service = AppLanguageService(defaults: defaults, availableLocalizations: ["en", "ru"])

        XCTAssertEqual(service.selection, .system)
        XCTAssertEqual(service.resolvedLocalization(systemPreferred: "ru"), "ru")
    }

    /// The case that made "no side effects on read" a rule: `AppleLanguages` can
    /// be a per-app language the user set in macOS itself. Starting Impuls must
    /// not silently throw that choice away.
    @MainActor
    func testInitializationLeavesASystemManagedPerAppLanguageAlone() throws {
        let suite = "AppLanguageServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(["de"], forKey: AppLanguageService.systemLanguagesKey)

        let service = AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped)

        XCTAssertEqual(service.selection, .system)
        XCTAssertEqual(systemLanguagesOverride(defaults, suite), ["de"])
    }

    /// Choosing `system` when Impuls never claimed the key leaves it to macOS.
    @MainActor
    func testChoosingSystemWithoutAnImpulsOverrideDoesNotClearTheSystemKey() throws {
        let suite = "AppLanguageServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(["fr"], forKey: AppLanguageService.systemLanguagesKey)
        let service = AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped)

        service.select(.system)

        XCTAssertEqual(systemLanguagesOverride(defaults, suite), ["fr"])
    }

    @MainActor
    func testAnUnsupportedLanguageIsRejectedAndNothingIsWritten() throws {
        let (service, defaults, suite) = try makeService(available: ["en", "ru"])
        defer { defaults.removePersistentDomain(forName: suite) }

        service.select(.japanese)

        XCTAssertEqual(service.selection, .system)
        XCTAssertNil(systemLanguagesOverride(defaults, suite))
        XCTAssertNil(ownDomain(defaults, suite, AppLanguageService.preferenceKey))
    }

    @MainActor
    func testSupportedLanguagesComeFromTheInjectedListNotTheTestRunnersBundle() throws {
        let (service, defaults, suite) = try makeService()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(service.selectableLanguages.first, .system)
        XCTAssertEqual(
            service.selectableLanguages.compactMap(\.localizationCode),
            Self.shipped
        )
    }

    // MARK: - requiresRelaunch

    /// An ordinary launch under `system`: macOS resolved some concrete locale, and
    /// that on its own is not a pending change.
    @MainActor
    func testOrdinaryLaunchUnderSystemDoesNotRequireRelaunch() throws {
        let (service, defaults, suite) = try makeService()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(service.resolvedLocalization(systemPreferred: "ru"), "ru")
        XCTAssertFalse(service.requiresRelaunch)
    }

    @MainActor
    func testSystemManagedPerAppLanguageDoesNotRequireRelaunch() throws {
        let suite = "AppLanguageServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(["de"], forKey: AppLanguageService.systemLanguagesKey)
        let service = AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped)

        XCTAssertFalse(service.requiresRelaunch)
    }

    @MainActor
    func testChangingTheLanguageInThisSessionRequiresRelaunch() throws {
        let (service, defaults, suite) = try makeService()
        defer { defaults.removePersistentDomain(forName: suite) }

        service.select(.german)

        XCTAssertTrue(service.requiresRelaunch)
    }

    @MainActor
    func testTheNextLaunchOnTheChosenLanguageDoesNotRequireRelaunch() throws {
        let suite = "AppLanguageServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped).select(.german)

        let relaunched = AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped)
        XCTAssertEqual(relaunched.selection, .german)
        XCTAssertFalse(relaunched.requiresRelaunch)
    }

    @MainActor
    func testReturningToSystemRequiresRelaunchAndTheLaunchAfterItDoesNot() throws {
        let suite = "AppLanguageServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped).select(.german)

        let running = AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped)
        running.select(.system)
        XCTAssertTrue(running.requiresRelaunch)

        let relaunched = AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped)
        XCTAssertEqual(relaunched.selection, .system)
        XCTAssertFalse(relaunched.requiresRelaunch)
    }

    @MainActor
    func testReselectingTheActiveLanguageDoesNotCreateAPendingRelaunch() throws {
        let suite = "AppLanguageServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped).select(.german)

        let relaunched = AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped)
        relaunched.select(.german)

        XCTAssertFalse(relaunched.requiresRelaunch)
    }

    /// The whole point of one owner: the preference and the system key never
    /// disagree, and there is no second place to look.
    @MainActor
    func testPreferenceAndSystemKeyStayConsistentAcrossTheFullCycle() throws {
        let suite = "AppLanguageServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped)
        first.select(.german)
        XCTAssertEqual(defaults.string(forKey: AppLanguageService.preferenceKey), "de")
        XCTAssertEqual(systemLanguagesOverride(defaults, suite), ["de"])

        let second = AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped)
        XCTAssertEqual(second.selection, .german)

        second.select(.system)
        XCTAssertEqual(defaults.string(forKey: AppLanguageService.preferenceKey), "system")
        XCTAssertNil(systemLanguagesOverride(defaults, suite))

        defaults.set("not-a-language", forKey: AppLanguageService.preferenceKey)
        let third = AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped)
        XCTAssertEqual(third.selection, .system)
        XCTAssertNil(systemLanguagesOverride(defaults, suite))
    }
}
