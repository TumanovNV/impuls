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

    func testPowerModuleMigrationAppendsWithoutChangingExistingOrderOrEnablement() async {
        await MainActor.run {
            let legacyTabs = NotchViewModel.Tab.allCases.filter { $0 != .power }
            let supplied = legacyTabs.enumerated().map { index, tab in
                ModulePreference(tab: tab, isEnabled: index.isMultiple(of: 2))
            }

            let normalized = SettingsStore.normalizedModules(supplied)

            XCTAssertEqual(Array(normalized.dropLast().map(\.tab)), legacyTabs)
            XCTAssertEqual(
                Array(normalized.dropLast().map(\.isEnabled)),
                supplied.map(\.isEnabled)
            )
            XCTAssertEqual(normalized.last, ModulePreference(tab: .power, isEnabled: true))
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

    /// Everything written before 1.4.6 — stored settings and exported
    /// backups alike — has no Apple-devices key. Updating must not be read as
    /// permission to go looking at the user's other hardware.
    func testSettingsFromBeforeAppleDevicesLeaveTheFeatureOff() async throws {
        try await MainActor.run {
            let json = """
            {
              "hotKey": "optionSpace",
              "activationMode": "hoverAndShortcut",
              "openDelay": "short",
              "panelSize": "standard",
              "modules": [{"tab": "power", "isEnabled": true}],
              "saveClipboardImages": true,
              "persistClipboardHistory": true,
              "clipboardRetention": "thirtyDays"
            }
            """

            let decoded = try JSONDecoder().decode(ImpulsSettingsSnapshot.self, from: Data(json.utf8))

            XCTAssertFalse(decoded.showsExternalAppleDevices)
            // The rest of a 1.4.5 blob still arrives intact.
            XCTAssertTrue(decoded.persistClipboardHistory)
            XCTAssertEqual(decoded.clipboardRetention, .thirtyDays)
        }
    }

    func testAppleDevicePreferencePersistsAndCarriesNoDeviceData() async {
        await MainActor.run {
            let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            let first = SettingsStore(defaults: defaults)
            XCTAssertFalse(first.showsExternalAppleDevices, "off until the user says otherwise")
            first.showsExternalAppleDevices = true

            let second = SettingsStore(defaults: defaults)
            XCTAssertTrue(second.showsExternalAppleDevices)

            // The snapshot that travels in a backup is a preference and
            // nothing else: no identifiers, no last-known charge, no device
            // list. Encoding it must stay that small.
            let encoded = try? JSONEncoder().encode(second.snapshot)
            let text = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            XCTAssertTrue(text.contains("showsExternalAppleDevices"))
            XCTAssertFalse(text.lowercased().contains("udid"))
            XCTAssertFalse(text.lowercased().contains("serial"))
            XCTAssertFalse(text.lowercased().contains("battery"))
        }
    }

    func testLowBatteryAlertsPersistOnlyLocallyAndPromptOnlyFromTheUserAction() async {
        await MainActor.run {
            let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            let first = SettingsStore(defaults: defaults)
            var requests: [(Bool, Bool)] = []
            first.configureLowBatteryAlerts { requests.append(($0, $1)) }

            first.setLowBatteryAlertsEnabledByUser(true)

            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.0, true)
            XCTAssertEqual(requests.first?.1, true)
            XCTAssertTrue(SettingsStore(defaults: defaults).lowBatteryAlertsEnabled)

            let backup = try? JSONEncoder().encode(first.snapshot)
            let backupText = backup.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            XCTAssertFalse(backupText.contains("lowBatteryAlerts"), "notification consent belongs to this Mac")

            // A persistence reload is not another explicit authorization act.
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testPerDeviceVisibilityAndOrderStayLocalAndSurviveARelaunch() async {
        await MainActor.run {
            let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            let mouse = Fixtures.device(
                kind: .magicMouse,
                name: "Magic Mouse",
                components: [DeviceBatteryComponent(kind: .primary, percentage: 71)]
            )
            let airPods = Fixtures.airPods(left: nil, right: 87, chargingCase: nil)

            let first = SettingsStore(defaults: defaults)
            first.updateAppleDeviceState(devices: [mouse, airPods], diagnostics: [])
            first.setAppleDevice(airPods, visible: false)
            first.moveAppleDevice(airPods, offset: -1)

            XCTAssertEqual(first.knownExternalAppleDevices.map(\.displayName), ["AirPods Pro", "Magic Mouse"])
            XCTAssertFalse(first.isAppleDeviceVisible(airPods))

            let backup = try? JSONEncoder().encode(first.snapshot)
            let backupText = backup.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            XCTAssertFalse(backupText.contains(airPods.identity.localPreferenceKey))
            XCTAssertFalse(backupText.contains(mouse.identity.localPreferenceKey))

            let second = SettingsStore(defaults: defaults)
            second.updateAppleDeviceState(devices: [mouse, airPods], diagnostics: [])

            XCTAssertEqual(second.knownExternalAppleDevices.map(\.displayName), ["AirPods Pro", "Magic Mouse"])
            XCTAssertFalse(second.isAppleDeviceVisible(airPods))
            XCTAssertEqual(second.visibleExternalAppleDevices(from: [mouse, airPods]), [mouse])
        }
    }

    func testAHiddenOrStaleDeviceCanBeForgottenWithoutPersistingItsSnapshot() async {
        await MainActor.run {
            let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            let keyboard = Fixtures.device(
                kind: .magicKeyboard,
                name: "Keyboard Николая",
                components: [DeviceBatteryComponent(kind: .primary, percentage: 44)]
            )
            let settings = SettingsStore(defaults: defaults)
            settings.updateAppleDeviceState(devices: [keyboard], diagnostics: [])

            XCTAssertFalse(settings.canForgetAppleDevice(keyboard), "a current visible device is not forgotten accidentally")
            settings.setAppleDevice(keyboard, visible: false)
            XCTAssertTrue(settings.canForgetAppleDevice(keyboard))

            settings.forgetAppleDevice(keyboard)

            XCTAssertTrue(settings.knownExternalAppleDevices.isEmpty)
            XCTAssertFalse(settings.appleDevicePreferenceOrder.contains(keyboard.identity.localPreferenceKey))
            let stored = defaults.data(forKey: SettingsStore.appleDevicePreferencesKey)
            let storedText = stored.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            XCTAssertFalse(storedText.contains("Keyboard Николая"), "names and readings are runtime-only")
            let object = stored.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            XCTAssertEqual(Set(object?.keys.map { $0 } ?? []), ["order", "hidden"])
        }
    }

    func testAppleDevicePreferenceKeysAreStrictlyBoundedAndValidated() async {
        await MainActor.run {
            let valid = String(repeating: "a", count: 32)
            let other = String(repeating: "0", count: 32)
            let supplied = [
                valid,
                valid,
                other,
                String(repeating: "f", count: 31),
                String(repeating: "f", count: 33),
                String(repeating: "G", count: 32),
                "../device",
                String(repeating: " ", count: 100_000),
            ]

            XCTAssertEqual(SettingsStore.normalizedAppleDevicePreferenceKeys(supplied), [valid, other])
            XCTAssertEqual(
                SettingsStore.normalizedAppleDevicePreferenceKeys(
                    (0..<150).map { String(format: "%032x", $0) }
                ).count,
                SettingsStore.maximumRememberedAppleDevices
            )
        }
    }

    func testFindDevicesRequiresAnExplicitOptInBeforeRefresh() async {
        await MainActor.run {
            let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsStore(defaults: defaults)
            var refreshes = 0
            settings.configureExternalAppleDeviceRefresh { refreshes += 1 }

            settings.findExternalAppleDevices()
            XCTAssertTrue(settings.showsExternalAppleDevices)
            XCTAssertEqual(refreshes, 0, "turning the switch on lets the coordinator own the first read")

            settings.findExternalAppleDevices()
            XCTAssertEqual(refreshes, 1)
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
