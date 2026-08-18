import Foundation
import XCTest
@testable import ImpulsCore

final class SettingsMigration1410Tests: XCTestCase {
    func testA149InstallKeepsEveryExistingSettingAndStatisticsStayUnknown() async throws {
        try await MainActor.run {
            let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let stored149 = """
            {
              "hotKey": "controlSpace",
              "activationMode": "shortcutOnly",
              "openDelay": "deliberate",
              "panelSize": "large",
              "selectedDisplayID": 42,
              "modules": [
                {"tab": "notes", "isEnabled": true},
                {"tab": "actions", "isEnabled": false},
                {"tab": "power", "isEnabled": true}
              ],
              "saveClipboardImages": false,
              "persistClipboardHistory": true,
              "clipboardRetention": "thirtyDays",
              "excludedClipboardBundleIdentifiers": ["com.example.passwords"],
              "showsExternalAppleDevices": true
            }
            """
            defaults.set(Data(stored149.utf8), forKey: SettingsStore.storageKey)
            let decoded149 = try JSONDecoder().decode(
                ImpulsSettingsSnapshot.self,
                from: Data(stored149.utf8)
            )

            let settings = SettingsStore(defaults: defaults)
            let telemetry = VersionTelemetryService(
                defaults: defaults,
                endpoint: nil,
                appVersion: "1.4.10",
                installationID: { UUID() },
                sender: { _ in throw URLError(.notConnectedToInternet) }
            )

            XCTAssertEqual(settings.hotKey, .controlSpace)
            XCTAssertEqual(settings.activationMode, .shortcutOnly)
            XCTAssertEqual(settings.openDelay, .deliberate)
            XCTAssertEqual(settings.panelSize, .large)
            XCTAssertEqual(decoded149.selectedDisplayID, 42)
            XCTAssertFalse(settings.saveClipboardImages)
            XCTAssertTrue(settings.persistClipboardHistory)
            XCTAssertEqual(settings.clipboardRetention, .thirtyDays)
            XCTAssertEqual(settings.excludedClipboardBundleIdentifiers, ["com.example.passwords"])
            XCTAssertTrue(settings.showsExternalAppleDevices)
            XCTAssertEqual(telemetry.consent, .unknown)
        }
    }

    func testSettingsSidebarSelectionPersistsAndInvalidValuesFallBackToGeneral() async {
        await MainActor.run {
            let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            let first = SettingsNavigationState(defaults: defaults)
            XCTAssertEqual(first.selection, .general)
            first.selection = .dataAndPrivacy
            XCTAssertEqual(SettingsNavigationState(defaults: defaults).selection, .dataAndPrivacy)

            defaults.set("future-section", forKey: SettingsNavigationState.selectionKey)
            XCTAssertEqual(SettingsNavigationState(defaults: defaults).selection, .general)
        }
    }
}
