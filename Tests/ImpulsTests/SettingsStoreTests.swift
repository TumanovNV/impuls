import XCTest
@testable import ImpulsCore

final class SettingsStoreTests: XCTestCase {
    func testModuleNormalizationKeepsEveryKnownModuleExactlyOnce() async {
        await MainActor.run {
            let supplied = [
                ModulePreference(tab: .notes, isEnabled: false),
                ModulePreference(tab: .notes, isEnabled: true),
                ModulePreference(tab: .calendar, isEnabled: false),
            ]

            let normalized = SettingsStore.normalizedModules(supplied)

            XCTAssertEqual(Set(normalized.map(\.tab)), Set(NotchViewModel.Tab.allCases))
            XCTAssertEqual(normalized.filter { $0.tab == .notes }.count, 1)
            XCTAssertTrue(normalized.contains(where: \.isEnabled))
            XCTAssertEqual(normalized.first?.tab, .actions)
        }
    }

    func testAtLeastOneModuleAlwaysRemainsEnabled() async {
        await MainActor.run {
            let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsStore(defaults: defaults)

            for tab in NotchViewModel.Tab.allCases.dropLast() {
                settings.setModule(tab, enabled: false)
            }
            let last = NotchViewModel.Tab.allCases.last!
            settings.setModule(last, enabled: false)

            XCTAssertEqual(settings.enabledTabs, [last])
        }
    }

    func testSettingsPersistAndReload() async {
        await MainActor.run {
            let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            let first = SettingsStore(defaults: defaults)
            first.hotKey = .controlSpace
            first.activationMode = .shortcutOnly
            first.panelSize = .large
            first.saveClipboardImages = false
            first.persistClipboardHistory = true
            first.clipboardRetention = .thirtyDays
            first.excludeClipboardApp(bundleIdentifier: "com.example.passwords")
            first.moveModule(.notes, offset: -1)

            let second = SettingsStore(defaults: defaults)
            XCTAssertEqual(second.hotKey, .controlSpace)
            XCTAssertEqual(second.activationMode, .shortcutOnly)
            XCTAssertEqual(second.panelSize, .large)
            XCTAssertFalse(second.saveClipboardImages)
            XCTAssertTrue(second.persistClipboardHistory)
            XCTAssertEqual(second.clipboardRetention, .thirtyDays)
            XCTAssertEqual(second.excludedClipboardBundleIdentifiers, ["com.example.passwords"])
            XCTAssertEqual(second.modules, first.modules)
        }
    }

    func testLegacySettingsUsePrivateClipboardDefaults() async throws {
        try await MainActor.run {
            let json = """
            {
              "hotKey": "optionSpace",
              "activationMode": "hoverAndShortcut",
              "openDelay": "short",
              "panelSize": "standard",
              "modules": [{"tab": "clipboard", "isEnabled": true}],
              "saveClipboardImages": true
            }
            """

            let decoded = try JSONDecoder().decode(ImpulsSettingsSnapshot.self, from: Data(json.utf8))

            XCTAssertFalse(decoded.persistClipboardHistory)
            XCTAssertEqual(decoded.clipboardRetention, .sevenDays)
            XCTAssertTrue(decoded.excludedClipboardBundleIdentifiers.isEmpty)
        }
    }

    func testClipboardExclusionsRejectMalformedOrExcessiveIdentifiers() async {
        await MainActor.run {
            let supplied = [
                "com.example.safe",
                "../Applications/Secrets",
                "com.example.\nmalicious",
                String(repeating: "a", count: 256),
                String(repeating: " ", count: 100_000) + "com.example.hidden",
                ".com.example.leading",
            ]

            XCTAssertEqual(
                SettingsStore.normalizedBundleIdentifiers(supplied),
                ["com.example.safe"]
            )
            XCTAssertFalse(SettingsStore.isValidBundleIdentifier("ru.company-passwords.app_1"))
            XCTAssertTrue(SettingsStore.isValidBundleIdentifier("ru.company-passwords.app-1"))
        }
    }
}
