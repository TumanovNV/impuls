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
            first.moveModule(.notes, offset: -1)

            let second = SettingsStore(defaults: defaults)
            XCTAssertEqual(second.hotKey, .controlSpace)
            XCTAssertEqual(second.activationMode, .shortcutOnly)
            XCTAssertEqual(second.panelSize, .large)
            XCTAssertFalse(second.saveClipboardImages)
            XCTAssertEqual(second.modules, first.modules)
        }
    }
}
